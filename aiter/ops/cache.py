# SPDX-License-Identifier: MIT
# Copyright (c) 2024, Advanced Micro Devices, Inc. All rights reserved.

from torch import Tensor
from typing import List, Optional
from ..jit.core import compile_ops, CK_DIR, AITER_CSRC_DIR
import torch.nn.functional as F

MD_NAME = "module_cache"


@compile_ops("module_cache")
def swap_blocks(src: Tensor, dst: Tensor, block_mapping: Tensor): ...


@compile_ops("module_cache")
def copy_blocks(key_caches: Tensor, value_caches: Tensor, block_mapping: Tensor): ...


@compile_ops("module_cache")
def reshape_and_cache(
    key: Tensor,
    value: Tensor,
    key_cache: Tensor,
    value_cache: Tensor,
    slot_mapping: Tensor,
    kv_cache_dtype: str,
    k_scale: float,
    v_scale: float,
    asm_layout: bool
): ...


@compile_ops("module_cache")
def reshape_and_cache_flash(
    key: Tensor,
    value: Tensor,
    key_cache: Tensor,
    value_cache: Tensor,
    slot_mapping: Tensor,
    kv_cache_dtype: str,
    k_scale: float,
    v_scale: float,
): ...

@compile_ops("module_cache")
def reshape_and_cache_with_pertoken_quant(
    key: Tensor,
    value: Tensor,
    key_cache: Tensor,
    value_cache: Tensor,
    k_dequant_scales: Tensor,
    v_dequant_scales: Tensor,
    slot_mapping: Tensor,
    asm_layout: bool
): ...

@compile_ops("module_cache")
def convert_fp8(
    dst_cache: Tensor, src_cache: Tensor, scale: float, kv_cache_dtype: str
): ...
