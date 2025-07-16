//===- Cpu0InstrInfo.h - Cpu0 Instruction Information -----------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains the Cpu0 implementation of the TargetInstrInfo class.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0INSTRINFO_H
#define LLVM_LIB_TARGET_CPU0_CPU0INSTRINFO_H

#include "Cpu0.h"
#include "Cpu0RegisterInfo.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/TargetInstrInfo.h"

#define GET_INSTRINFO_HEADER
#include "Cpu0GenInstrInfo.inc"

namespace llvm {

class MachineInstr;
class MachineOperand;
class Cpu0Subtarget;
class TargetRegisterClass;
class TargetRegisterInfo;

class Cpu0InstrInfo : public Cpu0GenInstrInfo {
  virtual void anchor();

protected:
  const Cpu0Subtarget &Subtarget;

public:
  explicit Cpu0InstrInfo(const Cpu0Subtarget &STI);

  static const Cpu0InstrInfo *create(const Cpu0Subtarget &STI);

  /// getRegisterInfo - TargetInstrInfo is a superset of MRegister info.
  /// As such, whenever a client has an instance of instruction info, it should
  /// always be able to get register info as well (through this method).
  ///
  virtual const Cpu0RegisterInfo &getRegisterInfo() const = 0;

  /// Return the number of bytes of code the specified instruction may be.
  unsigned GetInstSizeInBytes(const MachineInstr &MI) const;

protected:
};

/// Create Cpu0InstrInfo objects.
const Cpu0InstrInfo *createCpu0SEInstrInfo(const Cpu0Subtarget &STI);
} // end namespace llvm

#endif // LLVM_LIB_TARGET_MIPS_MIPSINSTRINFO_H
