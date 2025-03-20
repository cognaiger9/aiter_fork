// SPDX-License-Identifier: MIT
// Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.
#include "rocm_ops.hpp"
#include "fmha_v3_bwd.h"

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m)
{
    MHA_BWD_ASM_PYBIND;
}