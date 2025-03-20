# SPDX-License-Identifier: MIT
# Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.

from aiter.test_common import checkAllclose, perftest, tensor_dump
import torch
import torch.nn.functional as F
import numpy as np
import sys
import os
import aiter
from aiter.ops.shuffle import shuffle_weight

@perftest()
def test_aiter_perTensorQuantFp8(input, scale=None):
    out = torch.empty(input.shape, dtype=torch.float8_e4m3fnuz, device=input.device)
    if scale is None:
        scale = torch.empty(1, dtype=torch.float32, device=input.device)
        aiter.dynamic_scaled_fp8_quant(out, input, scale)
    else:
        aiter.static_scaled_fp8_quant(out, input, scale)
    return out, scale

@perftest()
def test_torch_perTensorQuantFp8(input, scale=None):
    if scale is None:
        max_val = torch.max(torch.abs(input.view(-1)))
        # dtypeMax = torch.finfo(torch.float8_e4m3fnuz).max
        dtypeMax = 240.0
        scale = max_val.to(torch.float32) / dtypeMax
        out = (input / scale).to(torch.float8_e4m3fnuz)
    else:
        out = (input / scale).to(torch.float8_e4m3fnuz)
    return out, scale.view(1)
    

@perftest()
def test_aiter_perTokenQuantFp8(input):
    # orign_shape = input.shape
    token_num = input.view(-1, input.shape[-1]).shape[0]
    out = torch.empty(input.shape, dtype=torch.float8_e4m3fnuz, device=input.device)
    scales = torch.empty(token_num, dtype=torch.float32, device=input.device)
    aiter.dynamic_per_token_scaled_fp8_quant(out, input, scales)
    return out, scales


@perftest()
def test_torch_perTokenQuantFp8(input):
    return aiter.pertoken_quant(input, torch.float, quant_dtype=torch.float8_e4m3fnuz)


def test_quant(m, n, dtype=torch.bfloat16):
    dim = (m, n)
    input = torch.randn(dim, dtype=dtype, device='cuda')
    max_val = torch.max(torch.abs(input.view(-1)))
    print(f'{max_val=}')

    (a, a_scale), avg_a = test_torch_perTensorQuantFp8(input)
    (b, b_scale), avg_b = test_aiter_perTensorQuantFp8(input)
    msg = f"[perf] dynamic_perTensorQuantFp8 dim: {str(dim):<20} dtype: {dtype}, torch avg: {avg_a:<8.2f} us, aiter avg: {avg_b:<8.2f} us, uplift: {avg_a/avg_b-1:<5.1%}"
    checkAllclose(a.to(torch.float), b.to(torch.float), rtol=0.125, atol=1e-3, msg=msg)
    checkAllclose(a_scale, b_scale, msg='scale')
    # print(f'{a_scale=}, {b_scale=}')

    scale = a_scale
    (a, a_scale), avg_a = test_torch_perTensorQuantFp8(input, scale)
    (b, b_scale), avg_b = test_aiter_perTensorQuantFp8(input, scale)
    msg = f"[perf] static_perTensorQuantFp8 dim: {str(dim):<20} dtype: {dtype}, torch avg: {avg_a:<8.2f} us, aiter avg: {avg_b:<8.2f} us, uplift: {avg_a/avg_b-1:<5.1%}"
    checkAllclose(a.to(torch.float), b.to(torch.float), rtol=0.125, atol=1e-3, msg=msg)

    (a, a_scale), avg_a = test_torch_perTokenQuantFp8(input)
    (b, b_scale), avg_b = test_aiter_perTokenQuantFp8(input)
    msg = f"[perf] dynamic_perTokenQuantFp8 dim: {str(dim):<20} dtype: {dtype}, torch avg: {avg_a:<8.2f} us, aiter avg: {avg_b:<8.2f} us, uplift: {avg_a/avg_b-1:<5.1%}"
    checkAllclose(a.to(torch.float), b.to(torch.float), rtol=0.125, atol=1e-3, msg=msg)
    checkAllclose(a_scale.view(-1), b_scale, msg='scale')


for dtype in [torch.float16, torch.bfloat16][1:]:
    for m in [1, 16, 32, 64, 128, 192, 256]:
        for n in [4096, 8192]:
            test_quant(m, n, dtype=dtype)
    


