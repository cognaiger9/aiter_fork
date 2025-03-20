# SPDX-License-Identifier: MIT
# Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.

import torch
import torch.nn.functional as F
import aiter
from aiter.test_common import checkAllclose, perftest


@perftest()
def run_torch(input, weight, eps, residual=None):
    if residual is None:
        residual_out = None
        output = F.rms_norm(
            input=input,
            normalized_shape=(input.shape[-1],),
            weight=weight,
            eps=eps
        )
    else:
        residual_out = input + residual
        output = F.rms_norm(
            input=residual_out,
            normalized_shape=(input.shape[-1],),
            weight=weight,
            eps=eps
        )
    return output, residual_out


@perftest()
def run_ck(input, weight, eps, residual=None):
    if residual is None:
        residual_out = None
        output = aiter.rms_norm(
            input,
            weight,
            eps
        )
    else:
        residual_out = torch.empty_like(input)
        output = torch.empty_like(input)
        aiter.rmsnorm2d_fwd_with_add(
            output,
            input,
            residual,
            residual_out,
            weight,
            eps
        )
    return output, residual_out


@perftest()
def run_cu(input, weight, eps, residual=None):
    if residual is None:
        residual_out = None
        output = torch.empty_like(input)
        aiter.rms_norm_cu(output, input, weight, eps)
    else:
        aiter.fused_add_rms_norm_cu(
            input,
            residual,
            weight,
            eps
        )
        output = input
        residual_out = residual
    return output, residual_out


def test_rmsnorm2d(dtype, m, n):
    dim = (m, n)
    input = torch.randn(dim, dtype=dtype, device="cuda")
    weight = torch.randn(n, dtype=dtype, device="cuda")
    hidden_stats = torch.randn(m, n*8, dtype=dtype, device="cuda")
    # q, k, v = torch.split(hidden_stats, [6*n, n, n], dim=1)
    # input = k
    (a, *_), avg_a = run_torch(input, weight, 1e-5)
    (b, *_), avg_b = run_ck(input, weight, 1e-5)
    (c, *_), avg_c = run_cu(input, weight, 1e-5)
    msg = f"[perf] dim: {str(dim):<20}, dtype: {dtype}, torch avg: {avg_a:<8.2f} us, ck avg: {avg_b:<8.2f} us, cu avg: {avg_c:<8.2f} us, uplift: {avg_a/avg_b-1:<5.1%}"
    checkAllclose(a, b, msg=msg)
    checkAllclose(a, c, msg='cu')

def test_rmsnorm2d_fuseAdd(dtype, m, n):
    dim = (m, n)
    input = torch.randn(dim, dtype=dtype, device="cuda")
    weight = torch.randn(n, dtype=dtype, device="cuda")
    res = torch.randn(dim, dtype=dtype, device="cuda")
    hidden_stats = torch.randn(m, n*8, dtype=dtype, device="cuda")
    # q, k, v = torch.split(hidden_stats, [6*n, n, n], dim=1)
    # input = k
    (a, res_a, *_), avg_a = run_torch(input, weight, 1e-5, residual=res)
    (b, res_b, *_), avg_b = run_ck(input, weight, 1e-5, residual=res)
    (c, res_c, *_), avg_c = run_cu(input, weight, 1e-5, residual=res)

    msg = f"[perf] dim: {str(dim):<20}, dtype: {dtype}, torch avg: {avg_a:<8.2f} us, ck avg: {avg_b:<8.2f} us, cu avg: {avg_c:<8.2f} us,uplift: {avg_a/avg_b-1:<5.1%}"
    checkAllclose(a, b, atol=0.03, msg=msg)
    checkAllclose(res_a, res_b, msg='ck res check')
    # checkAllclose(a, c, atol=0.03, msg='cu')
    # checkAllclose(res_a, res_c, atol=0.01, msg='cu res check')


# for dtype in [torch.float16, torch.bfloat16]:
#     for m in [1, 2, 4, 8, 16, 32, 64, 128, 256]:
#         for n in [4096, 8192, 16384, 32768, 65536]:
#             test_rmsnorm2d(dtype, m, n)

print('\nstart fuse add test')
for dtype in [torch.float16, torch.bfloat16]:
    for m in [1, 2, 4, 8, 16, 32, 64, 128, 256]:
        for n in [4096, 8192, 16384, 32768, 65536]:
            test_rmsnorm2d_fuseAdd(dtype, m, n)