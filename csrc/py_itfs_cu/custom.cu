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
#include <cuda_runtime.h>

// declare templates for front (cpp) and back (cuda) sides of function:
// template <typename T>

// void LLGemm_Silu(void* in_a, void* in_b, void* out_c, const int M, const int K,
//                  cudaStream_t stream, const int rows_per_block);
// void LLMM_Silu(at::Tensor& in_a, at::Tensor& in_b, at::Tensor& out_c,
//                const int64_t rows_per_block) {
//   auto M = in_a.size(0);
//   auto K = in_a.size(1);
//   LLGemm_Silu(in_a.data_ptr(), in_b.data_ptr(), out_c.data_ptr(), M, K,
//               at::cuda::getCurrentCUDAStream(), rows_per_block);
// }

void LLGemm1(void *in_a, void *in_b, void *out_c, const int M, const int K,
             cudaStream_t stream, const int rows_per_block);

// template <typename T>
void LLMM1(at::Tensor &in_a, at::Tensor &in_b, at::Tensor &out_c,
           const int64_t rows_per_block)
{
        auto M = in_a.size(0);
        auto K = in_a.size(1);
        // if (N != in_b.numel())
        //         throw std::invalid_argument("Size mismatch A.numel(): " +
        //         std::to_string(in_a.numel())
        //                           + ", B.numel(): " +
        //                           std::to_string(in_b.numel()));

        // out_c.resize_({N});

        // call the kernel function...
        const at::cuda::OptionalCUDAGuard device_guard(device_of(in_a));
        LLGemm1(in_a.data_ptr(), in_b.data_ptr(), out_c.data_ptr(), M, K,
                at::cuda::getCurrentCUDAStream(), rows_per_block);
}

void wvSpltK_(void *in_a, void *in_b, void *out_c, const int M, const int K,
              const int N, cudaStream_t stream, const int CuCount);

void wvSpltK(at::Tensor &in_a, at::Tensor &in_b, at::Tensor &out_c,
             const int64_t N_in, const int64_t CuCount)
{
        auto M = in_a.size(0);
        auto K = in_a.size(1);
        int N = N_in;
        const at::cuda::OptionalCUDAGuard device_guard(device_of(in_a));
        wvSpltK_(in_a.data_ptr(), in_b.data_ptr(), out_c.data_ptr(), M, K, N,
                 at::cuda::getCurrentCUDAStream(), CuCount);
}

void LLGemmZZ(void *in_a, void *in_b, void *out_c, const int M, const int K,
              cudaStream_t stream, const int solidx);

void LLZZ(at::Tensor in_a, at::Tensor in_b, at::Tensor out_c,
          const int64_t solidx = 0)
{
        auto M = in_a.size(0);
        auto K = in_a.size(1);
        const at::cuda::OptionalCUDAGuard device_guard(device_of(in_a));
        LLGemmZZ(in_a.data_ptr(), in_b.data_ptr(), out_c.data_ptr(), M, K,
                 at::cuda::getCurrentCUDAStream(), solidx);
}
// instantiate the CPP template for T=float:
// template void AddGPU<float>(at::Tensor in_a, at::Tensor in_b, at::Tensor
// out_c);

void MMGPUKernel(float *in_a, float *in_b, float *out_c, int numARows,
                 int numAColumns, int numBRows, int numBColumns, int numCRows,
                 int numCColumns, cudaStream_t stream);

void MMCustomGPU(at::Tensor &in_a, at::Tensor &in_b, at::Tensor &out_c)
{
        auto matA_sizes{in_a.sizes()};
        auto matB_sizes{in_b.sizes()};
        auto matO_sizes{out_c.sizes()};
        const at::cuda::OptionalCUDAGuard device_guard(device_of(in_a));
        MMGPUKernel(in_a.data_ptr<float>(), in_b.data_ptr<float>(),
                    out_c.data_ptr<float>(), matA_sizes[0], matA_sizes[1],
                    matB_sizes[0], matB_sizes[1], matO_sizes[0], matO_sizes[1],
                    at::cuda::getCurrentCUDAStream());
}
