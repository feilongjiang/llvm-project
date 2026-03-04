//===- Cpu0RegisterInfo.cpp - CPU0 Register Information -------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file contains the Cpu0 implementation of the TargetRegisterInfo class.
//
//===----------------------------------------------------------------------===//

#include "Cpu0RegisterInfo.h"
#include "Cpu0.h"
#include "Cpu0MachineFunction.h"
#include "Cpu0Subtarget.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#define DEBUG_TYPE "cpu0-reg-info"

#define GET_REGINFO_TARGET_DESC
#include "Cpu0GenRegisterInfo.inc"

Cpu0RegisterInfo::Cpu0RegisterInfo(const Cpu0Subtarget &Subtarget)
    : Cpu0GenRegisterInfo(Cpu0::LR), Subtarget(Subtarget) {}

//===----------------------------------------------------------------------===//
// Callee Saved Registers methods
//===----------------------------------------------------------------------===//
/// Cpu0 Callee Saved Registers
// In Cpu0CallConv.td,
// def CSR_O32 : CalleeSavedRegs<(add LR, FP, (sequence "S%u", 1, 0))>;
// llc create CSR_O32_SaveList and CSR_O32_RegMask from above defined.
const MCPhysReg *
Cpu0RegisterInfo::getCalleeSavedRegs(const MachineFunction *MF) const {
  return CSR_O32_SaveList;
}

const uint32_t *
Cpu0RegisterInfo::getCallPreservedMask(const MachineFunction &MF,
                                       CallingConv::ID) const {
  return CSR_O32_RegMask;
}

// pure virtual method
BitVector Cpu0RegisterInfo::getReservedRegs(const MachineFunction &MF) const {
  static const uint16_t ReservedCPURegs[] = {
      Cpu0::ZERO, Cpu0::AT, Cpu0::SP, Cpu0::LR, /* Cpu0::SW, */ Cpu0::PC};
  BitVector Reserved(getNumRegs());

  for (unsigned I = 0; I < array_lengthof(ReservedCPURegs); ++I) {
    Reserved.set(ReservedCPURegs[I]);
  }

  return Reserved;
}

// If no eliminateFrameIndex(), it will hang on run.
// pure virtual method
// FrameIndex represent objects inside a abstract stack.
// We must replace FrameIndex with an stack/frame pointer
// direct reference.
void Cpu0RegisterInfo::eliminateFrameIndex(MachineBasicBlock::iterator II,
                                           int SPAdj, unsigned FIOperandNum,
                                           RegScavenger *RS) const {
  MachineInstr &MI = *II;
  MachineFunction &MF = *MI.getParent()->getParent();
  MachineFrameInfo &MFI = MF.getFrameInfo();
  Cpu0FunctionInfo *Cpu0FI = MF.getInfo<Cpu0FunctionInfo>();

  unsigned i = 0;
  while (!MI.getOperand(i).isFI()) {
    ++i;
    assert(i < MI.getNumOperands() && "Instr doesn't have FrameIndex operand!");
  }

  LLVM_DEBUG(errs() << "\nFunction : " << MF.getFunction().getName() << "\n";
             errs() << "<--------->\n " << MI);

  int FrameIndex = MI.getOperand(i).getIndex();
  uint64_t StackSize = MF.getFrameInfo().getStackSize();
  int64_t spOffset = MF.getFrameInfo().getObjectOffset(FrameIndex);

  LLVM_DEBUG(errs() << "FrameIndex: " << FrameIndex << "\n"
                    << "spOffset: " << spOffset << "\n"
                    << "StackSize: " << StackSize << "\n");

  const std::vector<CalleeSavedInfo> &CSI = MFI.getCalleeSavedInfo();
  int MinCSFI = 0;
  int MaxCSFI = -1;

  if (CSI.size()) {
    MinCSFI = CSI[0].getFrameIdx();
    MaxCSFI = CSI[CSI.size() - 1].getFrameIdx();
  }

  // The following stack frame objects are always referenced relative to $sp:
  // 1. Outgoing arguments.
  // 2. Pointer to dynamically allocated stack space.
  // 3. Locations for callee-saved registers.
  // Everything else is referenced relative to whatever register
  // getFrameRegister() returns.
  unsigned FrameReg;

  FrameReg = Cpu0::SP;

  // Calculate final offset.
  // - There is no need to change the offset if the frame object is one of the
  //   following: an outgoing argument, pointer to a dynamically allocated
  //   stack space or a $gp restore location,
  //- If the frame object is any of the following, its offset must be adjusted
  //  by adding the size of the stack:
  //  incoming argument, callee-saved register location or local variable.
  int64_t Offset;
  Offset = spOffset + (int64_t)StackSize;

  Offset += MI.getOperand(i + 1).getImm();

  LLVM_DEBUG(errs() << "Offset    : " << Offset << "\n"
                    << "<------------>\n");

  // If MI is not a debug value, make sure Offset fits in the 16-bit immediate
  // field. if (!MI.isDebugValue() && !isInt<16>(Offset)) {
  //   errs() << "!!!ERROR!!! Not support large frame over 16-bit at this
  //   point.\n"; assert(0 && "!MI.isDebugValue() && !isInt<16>(Offset)");
  // }

  if (!MI.isDebugValue() && !isInt<16>(Offset)) {
    assert("(!MI.isDebugValue() && !isInt<16>(Offset))");
  }

  MI.getOperand(i).ChangeToRegister(FrameReg, false);
  MI.getOperand(i + 1).ChangeToImmediate(Offset);
}

bool Cpu0RegisterInfo::requiresRegisterScavenging(
    const MachineFunction &MF) const {
  return true;
}

bool Cpu0RegisterInfo::trackLivenessAfterRegAlloc(
    const MachineFunction &MF) const {
  return true;
}

// pure virtual method
Register Cpu0RegisterInfo::getFrameRegister(const MachineFunction &MF) const {
  const TargetFrameLowering *TFI = MF.getSubtarget().getFrameLowering();
  return TFI->hasFP(MF) ? Cpu0::FP : Cpu0::SP;
}
