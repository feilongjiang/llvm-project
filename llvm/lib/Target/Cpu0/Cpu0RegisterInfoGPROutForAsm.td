//===-- Cpu0RegisterInfoGPROutForAskm.td - Cpu0 Register defs ----------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// @Register Classes
//===----------------------------------------------------------------------===//

def GPROut : RegisterClass<"Cpu0", [i32], 32, (add CPURegs)>;