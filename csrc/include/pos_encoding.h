#pragma once
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
#include <torch/extension.h>

void rotary_embedding(torch::Tensor &positions, torch::Tensor &query,
                      torch::Tensor &key, int64_t head_size,
                      torch::Tensor &cos_cache, torch::Tensor &sin_cache, bool is_neox, bool is_nope_first);

void batched_rotary_embedding(torch::Tensor &positions, torch::Tensor &query,
                              torch::Tensor &key, int64_t head_size,
                              torch::Tensor &cos_cache, torch::Tensor &sin_cache, bool is_neox, bool is_nope_first,
                              int64_t rot_dim,
                              torch::Tensor &cos_sin_cache_offsets);
