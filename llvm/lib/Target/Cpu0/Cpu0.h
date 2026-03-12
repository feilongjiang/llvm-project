//===-- Cpu0.h - Top-level interface for Cpu0 representation ----*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains the entry points for global functions defined in
// the LLVM Cpu0 back-end.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0_H
#define LLVM_LIB_TARGET_CPU0_CPU0_H

#include "MCTargetDesc/Cpu0MCTargetDesc.h"
#include "llvm/Target/TargetMachine.h"

namespace llvm {
class Cpu0TargetMachine;
class FunctionPass;

#define ENABLE_GPRESSTORE // The $gp register caller saved register enable

FunctionPass *createCpu0DelJmpPass(Cpu0TargetMachine &TM);
FunctionPass *createCpu0DelaySlotFillerPass(Cpu0TargetMachine &TM);
FunctionPass *createCpu0BranchExpansionPass(Cpu0TargetMachine &TM);
} // namespace llvm

#endif
