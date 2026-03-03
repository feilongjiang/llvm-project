//===-- Cpu0SEInstrInfo.h - Cpu0 Instruction Information --------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains the Cpu04 implementation of the TargetInstrInfo class.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0SEINSTRINFO_H
#define LLVM_LIB_TARGET_CPU0_CPU0SEINSTRINFO_H

#include "Cpu0InstrInfo.h"
#include "Cpu0SERegisterInfo.h"

namespace llvm {

class Cpu0SEInstrInfo : public Cpu0InstrInfo {
  const Cpu0SERegisterInfo RI;

public:
  explicit Cpu0SEInstrInfo(const Cpu0Subtarget &STI);

  const Cpu0RegisterInfo &getRegisterInfo() const override;

  bool expandPostRAPseudo(MachineInstr &MI) const override;

private:
  void expandRetLR(MachineBasicBlock &MBB, MachineBasicBlock::iterator I) const;
};

} // namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0SEINSTRINFO_H
