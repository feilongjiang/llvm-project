//===- Cpu0SEISelLowering.h - Cpu0SE DAG Lowering Interface -----*- C++ -*-===//
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

#ifndef LLVM_LIB_TARGET_CPU0_CPU0SEISELLOWERING_H
#define LLVM_LIB_TARGET_CPU0_CPU0SEISELLOWERING_H

#include "Cpu0ISelLowering.h"
#include "Cpu0RegisterInfo.h"

namespace llvm {

class MachineBasicBlock;
class MachineInstr;
class Cpu0Subtarget;
class Cpu0TargetMachine;
class SelectionDAG;
class TargetRegisterClass;

class Cpu0SETargetLowering : public Cpu0TargetLowering {
public:
  explicit Cpu0SETargetLowering(const Cpu0TargetMachine &TM,
                                const Cpu0Subtarget &STI);

  SDValue LowerOperation(SDValue Op, SelectionDAG &DAG) const override;

private:
};

} // end namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0SEISELLOWERING_H
