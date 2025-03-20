/*
 * Copyright © Advanced Micro Devices, Inc. All rights reserved.
 * Copyright (c) 2024, The vLLM team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <torch/all.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>

#include "hip_compat.h"
#include "dispatch_utils.h"

#ifdef USE_ROCM
#include "quant_utils.cuh"
#else
#include "quantization/fp8/nvidia/quant_utils.cuh"
#endif

#include <algorithm>
#include <cassert>
#include <map>
#include <vector>

#ifdef USE_ROCM
#include <hip/hip_bf16.h>
typedef __hip_bfloat16 __nv_bfloat16;
#endif

void swap_blocks(torch::Tensor &src, torch::Tensor &dst,
                 const torch::Tensor &block_mapping)
{
  torch::Device src_device = src.device();
  torch::Device dst_device = dst.device();
  cudaMemcpyKind memcpy_type;
  if (src_device.is_cuda() && dst_device.is_cuda())
  {
    TORCH_CHECK(src_device.index() == dst_device.index(),
                "src and dst must be on the same GPU");
    memcpy_type = cudaMemcpyDeviceToDevice;
  }
  else if (src_device.is_cuda() && dst_device.is_cpu())
  {
    memcpy_type = cudaMemcpyDeviceToHost;
  }
  else if (src_device.is_cpu() && dst_device.is_cuda())
  {
    memcpy_type = cudaMemcpyHostToDevice;
  }
  else
  {
    TORCH_CHECK(false, "Invalid device combination");
  }

  // NOTE(youkaichao): keep in mind that `block_mapping` should be
  // a cpu tensor, otherwise every `item` call will require a gpu-cpu
  // synchronization.
  TORCH_CHECK(block_mapping.device().is_cpu(), "block_mapping must be on CPU");

  char *src_ptr = static_cast<char *>(src.data_ptr());
  char *dst_ptr = static_cast<char *>(dst.data_ptr());

  const int64_t block_size_in_bytes = src.element_size() * src[0].numel();
  const at::cuda::OptionalCUDAGuard device_guard(
      src_device.is_cuda() ? src_device : dst_device);
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  // NOTE(woosuk): This can be slow if the number of blocks is large.
  const int64_t num_blocks = block_mapping.size(0);
  for (size_t i = 0; i < num_blocks; i++)
  {
    int64_t src_block_number = block_mapping[i][0].item<int64_t>();
    int64_t dst_block_number = block_mapping[i][1].item<int64_t>();
    int64_t src_offset = src_block_number * block_size_in_bytes;
    int64_t dst_offset = dst_block_number * block_size_in_bytes;
    cudaMemcpyAsync(dst_ptr + dst_offset, src_ptr + src_offset,
                    block_size_in_bytes, memcpy_type, stream);
  }
}

namespace vllm
{

  // Grid: (num_layers, num_pairs)
  template <typename scalar_t>
  __global__ void copy_blocks_kernel(int64_t *key_cache_ptrs,
                                     int64_t *value_cache_ptrs,
                                     const int64_t *__restrict__ block_mapping,
                                     const int numel_per_block)
  {
    const int layer_idx = blockIdx.x;
    const int pair_idx = blockIdx.y;

    scalar_t *key_cache = reinterpret_cast<scalar_t *>(key_cache_ptrs[layer_idx]);
    scalar_t *value_cache =
        reinterpret_cast<scalar_t *>(value_cache_ptrs[layer_idx]);
    int64_t src_block_number = block_mapping[2 * pair_idx];
    int64_t dst_block_number = block_mapping[2 * pair_idx + 1];

    const int64_t src_block_offset = src_block_number * numel_per_block;
    const int64_t dst_block_offset = dst_block_number * numel_per_block;
    for (int i = threadIdx.x; i < numel_per_block; i += blockDim.x)
    {
      int64_t src_offset = src_block_offset + i;
      int64_t dst_offset = dst_block_offset + i;
      key_cache[dst_offset] = key_cache[src_offset];
    }
    for (int i = threadIdx.x; i < numel_per_block; i += blockDim.x)
    {
      int64_t src_offset = src_block_offset + i;
      int64_t dst_offset = dst_block_offset + i;
      value_cache[dst_offset] = value_cache[src_offset];
    }
  }

} // namespace vllm

// Note: the key_caches and value_caches vectors are constant but
// not the Tensors they contain. The vectors need to be const refs
// in order to satisfy pytorch's C++ operator registration code.
void copy_blocks(std::vector<torch::Tensor> const &key_caches,
                 std::vector<torch::Tensor> const &value_caches,
                 const torch::Tensor &block_mapping)
{
  int num_layers = key_caches.size();
  TORCH_CHECK(num_layers == value_caches.size());
  if (num_layers == 0)
  {
    return;
  }
  torch::Device cache_device = key_caches[0].device();
  TORCH_CHECK(cache_device.is_cuda());

  // Create data structures for the kernel.
  // Create an array of pointers to the key and value caches.
  int64_t key_cache_ptrs[num_layers];
  int64_t value_cache_ptrs[num_layers];
  for (int layer_idx = 0; layer_idx < num_layers; ++layer_idx)
  {
    key_cache_ptrs[layer_idx] =
        reinterpret_cast<int64_t>(key_caches[layer_idx].data_ptr());
    value_cache_ptrs[layer_idx] =
        reinterpret_cast<int64_t>(value_caches[layer_idx].data_ptr());
  }

  // block_mapping is a 2D tensor with shape (num_pairs, 2).
  int num_pairs = block_mapping.size(0);

  // Move the data structures to the GPU.
  // NOTE: This synchronizes the CPU and GPU.
  torch::Tensor key_cache_ptrs_tensor =
      torch::from_blob(key_cache_ptrs, {num_layers}, torch::kInt64)
          .to(cache_device);
  torch::Tensor value_cache_ptrs_tensor =
      torch::from_blob(value_cache_ptrs, {num_layers}, torch::kInt64)
          .to(cache_device);

  // Launch the kernel.
  const int numel_per_block = key_caches[0][0].numel();
  dim3 grid(num_layers, num_pairs);
  dim3 block(std::min(1024, numel_per_block));
  const at::cuda::OptionalCUDAGuard device_guard(cache_device);
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  VLLM_DISPATCH_FLOATING_AND_BYTE_TYPES(
      key_caches[0].scalar_type(), "copy_blocks_kernel", ([&]
                                                          { vllm::copy_blocks_kernel<scalar_t><<<grid, block, 0, stream>>>(
                                                                key_cache_ptrs_tensor.data_ptr<int64_t>(),
                                                                value_cache_ptrs_tensor.data_ptr<int64_t>(),
                                                                block_mapping.data_ptr<int64_t>(), numel_per_block); }));
}

namespace vllm
{

  template <typename scalar_t, typename cache_t, Fp8KVCacheDataType kv_dt, bool asmLayout = false, typename slot_mapping_t = int64_t>
  __global__ void reshape_and_cache_kernel(
      const scalar_t *__restrict__ key,                // [num_tokens, num_heads, head_size]
      const scalar_t *__restrict__ value,              // [num_tokens, num_heads, head_size]
      cache_t *__restrict__ key_cache,                 // [num_blocks, num_heads, head_size/x,
                                                       // block_size, x]
      cache_t *__restrict__ value_cache,               // [num_blocks, num_heads, head_size,
                                                       // block_size]
      const slot_mapping_t *__restrict__ slot_mapping, // [num_tokens]
      const int key_stride, const int value_stride, const int num_heads,
      const int head_size, const int block_size, const int x, const float k_scale,
      const float v_scale)
  {
    const int64_t token_idx = blockIdx.x;
    const slot_mapping_t slot_idx = slot_mapping[token_idx];
    if (slot_idx < 0)
    {
      // Padding token that should be ignored.
      return;
    }

    const int64_t block_idx = static_cast<int64_t>(slot_idx) / block_size;
    const int64_t block_offset = static_cast<int64_t>(slot_idx) % block_size;

    const int n = num_heads * head_size;
    for (int i = threadIdx.x; i < n; i += blockDim.x)
    {
      const int64_t src_key_idx = token_idx * key_stride + i;
      const int64_t src_value_idx = token_idx * value_stride + i;

      const int head_idx = i / head_size;
      const int head_offset = i % head_size;
      const int x_idx = head_offset / x;
      const int x_offset = head_offset % x;

      const int64_t tgt_key_idx =
          block_idx * num_heads * (head_size / x) * block_size * x +
          head_idx * (head_size / x) * block_size * x +
          x_idx * block_size * x +
          block_offset * x +
          x_offset;
      int64_t tgt_value_idx;
      if constexpr (asmLayout)
      { //[num_blocks, num_heads, block_size/X, head_size, X]
        const int x_idx_v = block_offset / x;
        const int x_offset_v = block_offset % x;
        tgt_value_idx =
            block_idx * num_heads * head_size * block_size +
            head_idx * head_size * block_size +
            x_idx_v * head_size * x +
            head_offset * x +
            x_offset_v;
      }
      else
      { //[num_blocks, num_heads, head_size, block_size]
        tgt_value_idx =
            block_idx * num_heads * head_size * block_size +
            head_idx * head_size * block_size +
            head_offset * block_size +
            block_offset;
      }
      scalar_t tgt_key = key[src_key_idx];
      scalar_t tgt_value = value[src_value_idx];
      if constexpr (kv_dt == Fp8KVCacheDataType::kAuto)
      {
        key_cache[tgt_key_idx] = tgt_key;
        value_cache[tgt_value_idx] = tgt_value;
      }
      else
      {
        key_cache[tgt_key_idx] =
            fp8::scaled_convert<cache_t, scalar_t, kv_dt>(tgt_key, k_scale);
        value_cache[tgt_value_idx] =
            fp8::scaled_convert<cache_t, scalar_t, kv_dt>(tgt_value, v_scale);
      }
    }
  }

  template <typename scalar_t, typename cache_t, Fp8KVCacheDataType kv_dt>
  __global__ void reshape_and_cache_flash_kernel(
      const scalar_t *__restrict__ key,         // [num_tokens, num_heads, head_size]
      const scalar_t *__restrict__ value,       // [num_tokens, num_heads, head_size]
      cache_t *__restrict__ key_cache,          // [num_blocks, block_size, num_heads,
                                                // head_size]
      cache_t *__restrict__ value_cache,        // [num_blocks, block_size, num_heads,
                                                // head_size]
      const int64_t *__restrict__ slot_mapping, // [num_tokens]
      const int block_stride, const int key_stride, const int value_stride,
      const int num_heads, const int head_size, const int block_size,
      const float k_scale, const float v_scale)
  {
    const int64_t token_idx = blockIdx.x;
    const int64_t slot_idx = slot_mapping[token_idx];
    // NOTE: slot_idx can be -1 if the token is padded
    if (slot_idx < 0)
    {
      return;
    }
    const int64_t block_idx = slot_idx / block_size;
    const int64_t block_offset = slot_idx % block_size;
    const int n = num_heads * head_size;
    for (int i = threadIdx.x; i < n; i += blockDim.x)
    {
      const int64_t src_key_idx = token_idx * key_stride + i;
      const int64_t src_value_idx = token_idx * value_stride + i;
      const int head_idx = i / head_size;
      const int head_offset = i % head_size;
      const int64_t tgt_key_value_idx = block_idx * block_stride +
                                        block_offset * num_heads * head_size +
                                        head_idx * head_size + head_offset;
      scalar_t tgt_key = key[src_key_idx];
      scalar_t tgt_value = value[src_value_idx];
      if constexpr (kv_dt == Fp8KVCacheDataType::kAuto)
      {
        key_cache[tgt_key_value_idx] = tgt_key;
        value_cache[tgt_key_value_idx] = tgt_value;
      }
      else
      {
        key_cache[tgt_key_value_idx] =
            fp8::scaled_convert<cache_t, scalar_t, kv_dt>(tgt_key, k_scale);
        value_cache[tgt_key_value_idx] =
            fp8::scaled_convert<cache_t, scalar_t, kv_dt>(tgt_value, v_scale);
      }
    }
  }

  namespace impl
  {
    template <typename DType, typename SType>
    __device__ DType type_convert(SType);

    template <>
    __device__ float type_convert<float, __half>(__half x)
    {
      return __half2float(x);
    }

    template <>
    __device__ float type_convert<float, __hip_bfloat16>(__hip_bfloat16 x)
    {
      return __bfloat162float(x);
    }

    template <>
    __device__ hip_fp8 type_convert<hip_fp8, float>(float x)
    {
      hip_fp8 f8{x};
      return f8;
    }
    template <>
    __device__ int8_t type_convert<int8_t, float>(float x)
    {
      return static_cast<int8_t>(x);
    }
    template <>
    __device__ float type_convert<float, float>(float x)
    {
      return x;
    }

    template <typename T, typename F>
    __device__ constexpr T wave_reduce(T local, F reduce_f)
    {
      constexpr int reduce_stage = 6; // 1<<6=64
      T v_local = local;
#pragma unroll
      for (int i_stage = 0; i_stage < reduce_stage; i_stage++)
      {
        int src_lane = __lane_id() ^ (1 << i_stage);
        int32_t v_remote_tmp =
            __builtin_amdgcn_ds_bpermute(src_lane << 2, __builtin_bit_cast(int32_t, v_local));
        T v_remote = __builtin_bit_cast(T, v_remote_tmp);
        v_local = reduce_f(v_local, v_remote);
      }
      return v_local;
    }

    __device__ float abs(float x)
    {
      union
      {
        float f32;
        uint32_t u32;
      } y;
      y.f32 = x;
      y.u32 = y.u32 & 0x7fffffff;
      return y.f32;
    };
  }

  // TODO: this is for kv pertoken quant
  template <typename scalar_t, typename cache_t, typename dequant_scale_t, bool asmLayout = false, int wg_size = 256>
  __global__ void reshape_and_cache_with_per_token_quant_kernel(
      const scalar_t *__restrict__ key,               // [num_tokens, num_heads, head_size]
      const scalar_t *__restrict__ value,             // [num_tokens, num_heads, head_size]
      cache_t *__restrict__ key_cache,                // [num_blocks, num_heads, head_size/x, block_size, x]
      cache_t *__restrict__ value_cache,              // [num_blocks, num_heads, head_size, block_size]
      dequant_scale_t *__restrict__ k_dequant_scales, // [num_heads, max_kv_tokens]
      dequant_scale_t *__restrict__ v_dequant_scales, // [num_heads, max_kv_tokens]
      const int64_t *__restrict__ slot_mapping,       // [num_tokens]
      const int key_stride, const int value_stride, const int num_heads,
      const int head_size, const int block_size, const int x,
      const int num_tokens, const int max_kv_tokens,
      float dtypeMax)
  {
    const int32_t tokens_per_wg = wg_size / warpSize;

    // every wave compute one token, one head, all the headim
    int wave_id = threadIdx.x / warpSize;
    int lane_id = threadIdx.x % warpSize;

    const int64_t token_idx = static_cast<int64_t>(blockIdx.x * tokens_per_wg + wave_id);
    const int32_t head_idx = blockIdx.y;
    const int64_t slot_idx = slot_mapping[token_idx];

    if (token_idx >= num_tokens || slot_idx < 0)
    {
      // Padding token that should be ignored.
      return;
    }

    const int64_t block_idx = slot_idx / block_size;
    const int64_t block_offset = slot_idx % block_size;

    auto f_absmax_f32 = [](float v_0_, float v_1_)
    {
      return __builtin_fmaxf(impl::abs(v_0_), impl::abs(v_1_));
    };
    auto f_max_f32 = [](float v_0_, float v_1_)
    {
      return __builtin_fmaxf(v_0_, v_1_);
    };

    constexpr int local_dim_elems = 8;

    float k_local_dim[local_dim_elems]{0}; // up to 64*8 = 512 hdim
    float v_local_dim[local_dim_elems]{0}; // up to 64*8 = 512 hdim
#pragma unroll
    for (int i_d = 0; i_d < local_dim_elems; i_d++)
    {
      int current_d = lane_id + i_d * warpSize;
      const int64_t src_k_idx = token_idx * key_stride + head_idx * head_size + current_d;
      const int64_t src_v_idx = token_idx * value_stride + head_idx * head_size + current_d;
      if (current_d < head_size)
      {
        k_local_dim[i_d] = impl::type_convert<float>(key[src_k_idx]);
        v_local_dim[i_d] = impl::type_convert<float>(value[src_v_idx]);
      }
    }

    // smoot-quant
    float k_local_max = [&]()
    {
      float max_ = k_local_dim[0];
#pragma unroll
      for (int i_d = 1; i_d < local_dim_elems; i_d++)
      {
        max_ = f_absmax_f32(max_, k_local_dim[i_d]);
      }
      return max_;
    }();

    float k_max = impl::wave_reduce(k_local_max, f_max_f32);

    float v_local_max = [&]()
    {
      float max_ = v_local_dim[0];
#pragma unroll
      for (int i_d = 1; i_d < local_dim_elems; i_d++)
      {
        max_ = f_absmax_f32(max_, v_local_dim[i_d]);
      }
      return max_;
    }();
    float v_max = impl::wave_reduce(v_local_max, f_max_f32);

    float k_token_scale = k_max / dtypeMax;
    float v_token_scale = v_max / dtypeMax;

#pragma unroll
    for (int i_d = 0; i_d < local_dim_elems; i_d++)
    {
      k_local_dim[i_d] = k_local_dim[i_d] / k_token_scale;
      v_local_dim[i_d] = v_local_dim[i_d] / v_token_scale;
    }

    // store the scale
    int scale_idx;
    if constexpr (asmLayout)
    {
      // [num_blocks, num_heads, block_size]
      scale_idx = block_size * num_heads * block_idx +
                  block_size * head_idx +
                  block_offset;
      k_dequant_scales[scale_idx] = k_token_scale;
      v_dequant_scales[scale_idx] = v_token_scale;
    }
    else
    {
      scale_idx = head_idx * max_kv_tokens + slot_idx;
      k_dequant_scales[scale_idx] = k_token_scale;
      v_dequant_scales[scale_idx] = v_token_scale;
    }

    // now let's store out
#pragma unroll
    for (int i = 0; i < local_dim_elems; i++)
    {
      // const int head_idx = i / head_size;
      // const int head_offset = i % head_size;
      int i_d = lane_id + i * warpSize;
      if (i_d >= head_size)
      {
        break;
      }
      const int x_idx = i_d / x;
      const int x_offset = i_d % x;

      const int64_t tgt_key_idx =
          block_idx * num_heads * (head_size / x) * block_size * x +
          head_idx * (head_size / x) * block_size * x +
          x_idx * block_size * x +
          block_offset * x +
          x_offset;
      int64_t tgt_value_idx;
      if constexpr (asmLayout)
      { //[num_blocks, num_heads, block_size/X, head_size, X]
        const int x_idx_v = block_offset / x;
        const int x_offset_v = block_offset % x;
        tgt_value_idx =
            block_idx * num_heads * head_size * block_size +
            head_idx * head_size * block_size +
            x_idx_v * head_size * x +
            i_d * x +
            x_offset_v;
      }
      else
      { //[num_blocks, num_heads, head_size, block_size]
        tgt_value_idx =
            block_idx * num_heads * head_size * block_size +
            head_idx * head_size * block_size +
            i_d * block_size +
            block_offset;
      }
      key_cache[tgt_key_idx] = impl::type_convert<cache_t>(k_local_dim[i]);
      value_cache[tgt_value_idx] = impl::type_convert<cache_t>(v_local_dim[i]);
    }
  }
} // namespace vllm

// KV_T is the stored data type of kv-cache.
// CACHE_T is the data type of key and value tensors.
// KV_DTYPE is the real data type of kv-cache.
#define CALL_RESHAPE_AND_CACHE(KV_T, CACHE_T, KV_DTYPE)               \
  vllm::reshape_and_cache_kernel<KV_T, CACHE_T, KV_DTYPE>             \
      <<<grid, block, 0, stream>>>(                                   \
          reinterpret_cast<KV_T *>(key.data_ptr()),                   \
          reinterpret_cast<KV_T *>(value.data_ptr()),                 \
          reinterpret_cast<CACHE_T *>(key_cache.data_ptr()),          \
          reinterpret_cast<CACHE_T *>(value_cache.data_ptr()),        \
          slot_mapping.data_ptr<int64_t>(), key_stride, value_stride, \
          num_heads, head_size, block_size, x, k_scale, v_scale);

#define CALL_RESHAPE_AND_CACHE_ASM(KV_T, CACHE_T, KV_DTYPE)           \
  vllm::reshape_and_cache_kernel<KV_T, CACHE_T, KV_DTYPE, true>       \
      <<<grid, block, 0, stream>>>(                                   \
          reinterpret_cast<KV_T *>(key.data_ptr()),                   \
          reinterpret_cast<KV_T *>(value.data_ptr()),                 \
          reinterpret_cast<CACHE_T *>(key_cache.data_ptr()),          \
          reinterpret_cast<CACHE_T *>(value_cache.data_ptr()),        \
          slot_mapping.data_ptr<int64_t>(), key_stride, value_stride, \
          num_heads, head_size, block_size, x, k_scale, v_scale);

void reshape_and_cache(
    torch::Tensor &key,   // [num_tokens, num_heads, head_size]
    torch::Tensor &value, // [num_tokens, num_heads, head_size]
    torch::Tensor &
        key_cache, // [num_blocks, num_heads, head_size/x, block_size, x]
    torch::Tensor &
        value_cache,             // [num_blocks, num_heads, head_size, block_size]
    torch::Tensor &slot_mapping, // [num_tokens]
    const std::string &kv_cache_dtype, const double k_scale,
    const double v_scale,
    const bool asm_layout)
{
  int num_tokens = key.size(0);
  int num_heads = key.size(1);
  int head_size = key.size(2);
  int block_size = key_cache.size(3);
  int x = key_cache.size(4);

  int key_stride = key.stride(0);
  int value_stride = value.stride(0);

  dim3 grid(num_tokens);
  dim3 block(std::min(num_heads * head_size, 512));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(key));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  if (asm_layout)
  {
    DISPATCH_BY_KV_CACHE_DTYPE(key.dtype(), kv_cache_dtype,
                               CALL_RESHAPE_AND_CACHE_ASM)
  }
  else
  {
    DISPATCH_BY_KV_CACHE_DTYPE(key.dtype(), kv_cache_dtype,
                               CALL_RESHAPE_AND_CACHE)
  }
}

// KV_T is the stored data type of kv-cache.
// CACHE_T is the data type of key and value tensors.
// KV_DTYPE is the real data type of kv-cache.
#define CALL_RESHAPE_AND_CACHE_FLASH(KV_T, CACHE_T, KV_DTYPE)         \
  vllm::reshape_and_cache_flash_kernel<KV_T, CACHE_T, KV_DTYPE>       \
      <<<grid, block, 0, stream>>>(                                   \
          reinterpret_cast<KV_T *>(key.data_ptr()),                   \
          reinterpret_cast<KV_T *>(value.data_ptr()),                 \
          reinterpret_cast<CACHE_T *>(key_cache.data_ptr()),          \
          reinterpret_cast<CACHE_T *>(value_cache.data_ptr()),        \
          slot_mapping.data_ptr<int64_t>(), block_stride, key_stride, \
          value_stride, num_heads, head_size, block_size, k_scale, v_scale);

void reshape_and_cache_flash(
    torch::Tensor &key,       // [num_tokens, num_heads, head_size]
    torch::Tensor &value,     // [num_tokens, num_heads, head_size]
    torch::Tensor &key_cache, // [num_blocks, block_size, num_heads, head_size]
    torch::Tensor &
        value_cache,             // [num_blocks, block_size, num_heads, head_size]
    torch::Tensor &slot_mapping, // [num_tokens]
    const std::string &kv_cache_dtype, const double k_scale,
    const double v_scale)
{
  int num_tokens = key.size(0);
  int num_heads = key.size(1);
  int head_size = key.size(2);
  int block_size = key_cache.size(1);

  int key_stride = key.stride(0);
  int value_stride = value.stride(0);
  int block_stride = key_cache.stride(0);
  TORCH_CHECK(key_cache.stride(0) == value_cache.stride(0));

  dim3 grid(num_tokens);
  dim3 block(std::min(num_heads * head_size, 512));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(key));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  DISPATCH_BY_KV_CACHE_DTYPE(key.dtype(), kv_cache_dtype,
                             CALL_RESHAPE_AND_CACHE_FLASH);
}

// KV_T is the stored data type of kv-cache.
// CACHE_T is the data type of key and value tensors.
// KV_DTYPE is the real data type of kv-cache.
#define CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(KV_T, CACHE_T, dequant_scale_t)            \
  if (asm_layout)                                                                             \
  {                                                                                           \
    vllm::reshape_and_cache_with_per_token_quant_kernel<KV_T, CACHE_T, dequant_scale_t, true> \
        <<<grid, block, 0, stream>>>(                                                         \
            reinterpret_cast<KV_T *>(key.data_ptr()),                                         \
            reinterpret_cast<KV_T *>(value.data_ptr()),                                       \
            reinterpret_cast<CACHE_T *>(key_cache.data_ptr()),                                \
            reinterpret_cast<CACHE_T *>(value_cache.data_ptr()),                              \
            reinterpret_cast<dequant_scale_t *>(k_dequant_scales.data_ptr()),                 \
            reinterpret_cast<dequant_scale_t *>(v_dequant_scales.data_ptr()),                 \
            slot_mapping.data_ptr<int64_t>(), key_stride, value_stride,                       \
            num_heads, head_size, block_size, x, num_tokens, max_kv_tokens, dtypeMax);        \
  }                                                                                           \
  else                                                                                        \
  {                                                                                           \
    vllm::reshape_and_cache_with_per_token_quant_kernel<KV_T, CACHE_T, dequant_scale_t>       \
        <<<grid, block, 0, stream>>>(                                                         \
            reinterpret_cast<KV_T *>(key.data_ptr()),                                         \
            reinterpret_cast<KV_T *>(value.data_ptr()),                                       \
            reinterpret_cast<CACHE_T *>(key_cache.data_ptr()),                                \
            reinterpret_cast<CACHE_T *>(value_cache.data_ptr()),                              \
            reinterpret_cast<dequant_scale_t *>(k_dequant_scales.data_ptr()),                 \
            reinterpret_cast<dequant_scale_t *>(v_dequant_scales.data_ptr()),                 \
            slot_mapping.data_ptr<int64_t>(), key_stride, value_stride,                       \
            num_heads, head_size, block_size, x, num_tokens, max_kv_tokens, dtypeMax);        \
  }

void reshape_and_cache_with_pertoken_quant(
    torch::Tensor &key,   // [num_tokens, num_heads, head_size]
    torch::Tensor &value, // [num_tokens, num_heads, head_size]
    torch::Tensor &
        key_cache, // [num_blocks, num_heads, head_size/x, block_size, x]
    torch::Tensor &
        value_cache,                 // [num_blocks, num_heads, head_size, block_size]
    torch::Tensor &k_dequant_scales, // [num_heads, max_kv_tokens]
    torch::Tensor &v_dequant_scales, // [num_heads, max_kv_tokens]
    torch::Tensor &slot_mapping,     // [num_tokens]
    const bool asm_layout)
{
  int num_tokens = key.size(0);
  int num_heads = key.size(1);
  int head_size = key.size(2);
  int block_size = key_cache.size(3);
  int x = key_cache.size(4);
  int max_kv_tokens = k_dequant_scales.size(1);

  int key_stride = key.stride(0);
  int value_stride = value.stride(0);

  dim3 grid((num_tokens + 3) / 4, num_heads);
  dim3 block(256);
  const at::cuda::OptionalCUDAGuard device_guard(device_of(key));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  using dequant_scale_t = float; // should align with k_dequant_scales/v_dequant_scales dtype

  float dtypeMax;
  if (key_cache.dtype() == at::ScalarType::Float8_e4m3fnuz)
  {
    dtypeMax = std::numeric_limits<c10::Float8_e4m3fnuz>::max();
    if (key.dtype() == at::ScalarType::Float)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(float, hip_fp8, dequant_scale_t);
    }
    else if (key.dtype() == at::ScalarType::Half)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(__half, hip_fp8, dequant_scale_t);
    }
    else if (key.dtype() == at::ScalarType::BFloat16)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(__nv_bfloat16, hip_fp8, dequant_scale_t);
    }
    else
    {
      TORCH_CHECK(false,
                  "Unsupported input type of kv: ", key.dtype());
    }
  }
  else if (key_cache.dtype() == at::ScalarType::Char)
  {
    dtypeMax = 127;
    if (key.dtype() == at::ScalarType::Float)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(float, int8_t, dequant_scale_t);
    }
    else if (key.dtype() == at::ScalarType::Half)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(__half, int8_t, dequant_scale_t);
    }
    else if (key.dtype() == at::ScalarType::BFloat16)
    {
      CALL_RESHAPE_AND_CACHE_WITH_PERTOKEN_QUANT(__nv_bfloat16, int8_t, dequant_scale_t);
    }
    else
    {
      TORCH_CHECK(false,
                  "Unsupported input type of kv: ", key.dtype(), " kv cache: ", key_cache.dtype());
    }
  }
  else
  {
    TORCH_CHECK(false, "Unsupported data type of kv cache: ", key_cache.dtype());
  }
}

namespace vllm
{

  template <typename Tout, typename Tin, Fp8KVCacheDataType kv_dt>
  __global__ void convert_fp8_kernel(const Tin *__restrict__ src_cache,
                                     Tout *__restrict__ dst_cache,
                                     const float scale,
                                     const int64_t block_stride)
  {
    const int64_t block_idx = blockIdx.x;
    for (int i = threadIdx.x; i < block_stride; i += blockDim.x)
    {
      int64_t idx = block_idx * block_stride + i;
      dst_cache[idx] =
          fp8::scaled_convert<Tout, Tin, kv_dt>(src_cache[idx], scale);
    }
  }

} // namespace vllm

#define CALL_CONVERT_FP8(Tout, Tin, KV_DTYPE)                                \
  vllm::convert_fp8_kernel<Tout, Tin, KV_DTYPE><<<grid, block, 0, stream>>>( \
      reinterpret_cast<Tin *>(src_cache.data_ptr()),                         \
      reinterpret_cast<Tout *>(dst_cache.data_ptr()), scale, block_stride);

// Only for testing.
void convert_fp8(torch::Tensor &dst_cache, torch::Tensor &src_cache,
                 const double scale, const std::string &kv_cache_dtype)
{
  torch::Device src_device = src_cache.device();
  torch::Device dst_device = dst_cache.device();
  TORCH_CHECK(src_device.is_cuda(), "src must be on a GPU")
  TORCH_CHECK(dst_device.is_cuda(), "dst must be on a GPU")
  TORCH_CHECK(src_device.index() == dst_device.index(),
              "src and dst must be on the same GPU");
  at::cuda::OptionalCUDAGuard device_guard(src_device);

  int64_t num_blocks = src_cache.size(0);
  int64_t block_stride = src_cache.stride(0);

  dim3 grid(num_blocks);
  dim3 block(std::min(block_stride, int64_t(512)));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  if (kv_cache_dtype == "auto")
  {
    if (src_cache.dtype() == at::ScalarType::Float)
    {
      CALL_CONVERT_FP8(uint8_t, float, vllm::Fp8KVCacheDataType::kAuto);
    }
    else if (src_cache.dtype() == at::ScalarType::Half)
    {
      CALL_CONVERT_FP8(uint8_t, uint16_t, vllm::Fp8KVCacheDataType::kAuto);
    }
    else if (src_cache.dtype() == at::ScalarType::BFloat16)
    {
      CALL_CONVERT_FP8(uint8_t, __nv_bfloat16, vllm::Fp8KVCacheDataType::kAuto);
    }
    else if (dst_cache.dtype() == at::ScalarType::Float)
    {
      CALL_CONVERT_FP8(float, uint8_t, vllm::Fp8KVCacheDataType::kAuto);
    }
    else if (dst_cache.dtype() == at::ScalarType::Half)
    {
      CALL_CONVERT_FP8(uint16_t, uint8_t, vllm::Fp8KVCacheDataType::kAuto);
    }
    else if (dst_cache.dtype() == at::ScalarType::BFloat16)
    {
      CALL_CONVERT_FP8(__nv_bfloat16, uint8_t, vllm::Fp8KVCacheDataType::kAuto);
    }
  }
  else if (kv_cache_dtype == "fp8" || kv_cache_dtype == "fp8_e4m3")
  {
    if (src_cache.dtype() == at::ScalarType::Float)
    {
      CALL_CONVERT_FP8(uint8_t, float, vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
    else if (src_cache.dtype() == at::ScalarType::Half)
    {
      CALL_CONVERT_FP8(uint8_t, uint16_t, vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
    else if (src_cache.dtype() == at::ScalarType::BFloat16)
    {
      CALL_CONVERT_FP8(uint8_t, __nv_bfloat16,
                       vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
    else if (dst_cache.dtype() == at::ScalarType::Float)
    {
      CALL_CONVERT_FP8(float, uint8_t, vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
    else if (dst_cache.dtype() == at::ScalarType::Half)
    {
      CALL_CONVERT_FP8(uint16_t, uint8_t, vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
    else if (dst_cache.dtype() == at::ScalarType::BFloat16)
    {
      CALL_CONVERT_FP8(__nv_bfloat16, uint8_t,
                       vllm::Fp8KVCacheDataType::kFp8E4M3);
    }
  }
  else
  {
    TORCH_CHECK(false, "Unsupported data type: ", kv_cache_dtype);
  }
}
