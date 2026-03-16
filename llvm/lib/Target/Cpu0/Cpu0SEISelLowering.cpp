//===- Cpu0SEISelLowering.cpp - Cpu0SE DAG Lowering Interface -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Subclass of Cpu0TargetLowering specialized for Cpu032/64.
//
//===----------------------------------------------------------------------===//

#include "Cpu0SEISelLowering.h"
#include "Cpu0MachineFunction.h"

#include "Cpu0RegisterInfo.h"
#include "Cpu0Subtarget.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/MachineRegisterInfo.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#define DEBUG_TYPE "cpu0-isel"

static cl::opt<bool> EnableCpu0TailCalls("enable-cpu0-tail-calls", cl::Hidden,
                                         cl::desc("CPU0: Enable tail calls."),
                                         cl::init(false));

Cpu0SETargetLowering::Cpu0SETargetLowering(const Cpu0TargetMachine &TM,
                                           const Cpu0Subtarget &STI)
    : Cpu0TargetLowering(TM, STI) {
  // Set up the register classes.
  addRegisterClass(MVT::i32, &Cpu0::CPURegsRegClass);

  // must, computeRegisterProperties - Once all of the register classes are
  // added, this allows us to compute derived properties we expose.
  computeRegisterProperties(Subtarget.getRegisterInfo());
}

SDValue Cpu0SETargetLowering::LowerOperation(SDValue Op,
                                             SelectionDAG &DAG) const {
  return Cpu0TargetLowering::LowerOperation(Op, DAG);
}

bool Cpu0SETargetLowering::isEligibleForTailCallOptimization(
    const Cpu0CC &Cpu0CCInfo, unsigned NextStackOffset,
    const Cpu0FunctionInfo &FI) const {
  if (!EnableCpu0TailCalls) {
    return false;
  }

  // Return false if either the callee or caller has a byval argument.
  if (Cpu0CCInfo.hasByValArg() || FI.hasByvalArg()) {
    return false;
  }

  // Return true if the callee's argument area is no larger than the caller's.
  return NextStackOffset <= FI.getIncomingArgSize();
}

const Cpu0TargetLowering *
llvm::createCpu0SETargetLowering(const Cpu0TargetMachine &TM,
                                 const Cpu0Subtarget &STI) {
  return new Cpu0SETargetLowering(TM, STI);
}
