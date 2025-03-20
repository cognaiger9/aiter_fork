// SPDX-License-Identifier: MIT
// Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.
#pragma once

#include <torch/extension.h>

torch::Tensor ck_moe(torch::Tensor &hidden_states,          // [m, k], input token
                     torch::Tensor &w1,                     // [e, n, k]/[e, 2*n, k], pre-shuffle([e, nr, kr, w])
                     torch::Tensor &w2,                     // [e, n, k], pre-shuffle([e, nr, kr, w])
                     torch::Tensor &topk_weights,           // [tokens, topk]
                     torch::Tensor &topk_ids,               // [tokens, topk]
                     std::optional<torch::Tensor> w1_scale, // [e, 1, n], gate(up) scale
                     std::optional<torch::Tensor> w2_scale, // [e, 1, k], down scale
                     std::optional<torch::Tensor> a1_scale, // [m, 1], token scale
                     std::optional<torch::Tensor> a2_scale, // [e, 1, n], smooth-quant-scale for 2nd gemm input
                     std::optional<int> block_m = 32,
                     std::optional<torch::Tensor> expert_mask = std::nullopt);

void ck_moe_stage1(torch::Tensor &hidden_states,     // [m, k], input token
                   torch::Tensor &w1,                // [e, n, k]/[e, 2*n, k], pre-shuffle([e, nr, kr, w])
                   torch::Tensor &w2,                // [e, n, k], pre-shuffle([e, nr, kr, w])
                   torch::Tensor &sorted_token_ids,  // [max_num_tokens_padded]
                   torch::Tensor &sorted_expert_ids, // [max_num_m_blocks]
                   torch::Tensor &num_valid_ids,     // [1]
                   torch::Tensor &out,               // [max_num_tokens_padded, inter_dim]
                   int topk,
                   std::optional<torch::Tensor> w1_scale, // [e, 1, n], gate(up) scale
                   std::optional<torch::Tensor> a1_scale, // [m, 1], token scale
                   std::optional<int> block_m);

void ck_moe_stage2(torch::Tensor &inter_states,      // [m, k], input token
                   torch::Tensor &w1,                // [e, n, k]/[e, 2*n, k], pre-shuffle([e, nr, kr, w])
                   torch::Tensor &w2,                // [e, n, k], pre-shuffle([e, nr, kr, w])
                   torch::Tensor &sorted_token_ids,  // [max_num_tokens_padded]
                   torch::Tensor &sorted_expert_ids, // [max_num_m_blocks]
                   torch::Tensor &sorted_weights,    // [max_num_tokens_padded]
                   torch::Tensor &num_valid_ids,     // [1]
                   torch::Tensor &out,               // [max_num_tokens_padded, inter_dim]
                   int topk,
                   std::optional<torch::Tensor> w2_scale, // [e, 1, n], gate(up) scale
                   std::optional<torch::Tensor> a2_scale, // [m, 1], token scale
                   std::optional<int> block_m);
