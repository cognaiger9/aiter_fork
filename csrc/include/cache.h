#pragma once
// SPDX-License-Identifier: MIT
// Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.
#include <torch/extension.h>

#include <map>
#include <vector>

void swap_blocks(torch::Tensor &src, torch::Tensor &dst,
                 const torch::Tensor &block_mapping);

// Note: the key_caches and value_caches vectors are constant but
// not the Tensors they contain. The vectors need to be const refs
// in order to satisfy pytorch's C++ operator registration code.
void copy_blocks(std::vector<torch::Tensor> const &key_caches,
                 std::vector<torch::Tensor> const &value_caches,
                 const torch::Tensor &block_mapping);

void reshape_and_cache(torch::Tensor &key, torch::Tensor &value,
                       torch::Tensor &key_cache, torch::Tensor &value_cache,
                       torch::Tensor &slot_mapping,
                       const std::string &kv_cache_dtype, const double k_scale,
                       const double v_scale, const bool asm_layout);

void reshape_and_cache_flash(torch::Tensor &key, torch::Tensor &value,
                             torch::Tensor &key_cache,
                             torch::Tensor &value_cache,
                             torch::Tensor &slot_mapping,
                             const std::string &kv_cache_dtype,
                             const double k_scale, const double v_scale);

void reshape_and_cache_with_pertoken_quant(torch::Tensor &key, torch::Tensor &value,
                                           torch::Tensor &key_cache, torch::Tensor &value_cache,
                                           torch::Tensor &k_dequant_scales, torch::Tensor &v_dequant_scales,
                                           torch::Tensor &slot_mapping,
                                           const bool asm_layout);

// Just for unittest
void convert_fp8(torch::Tensor &dst_cache, torch::Tensor &src_cache,
                 const double scale, const std::string &kv_cache_dtype);