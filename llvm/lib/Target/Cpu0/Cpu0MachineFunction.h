//===- Cpu0MachineFunctionInfo.h - Private data used for Cpu0 ---*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file declares the Cpu0 specific subclass of MachineFunctionInfo.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0MACHINEFUNCTION_H
#define LLVM_LIB_TARGET_CPU0_CPU0MACHINEFUNCTION_H

#include "Cpu0.h"
#include "llvm/CodeGen/MachineFrameInfo.h"
#include "llvm/CodeGen/MachineFunction.h"
#include "llvm/CodeGen/MachineMemOperand.h"
#include "llvm/CodeGen/PseudoSourceValue.h"
#include "llvm/Target/TargetMachine.h"
#include <map>

namespace llvm {

/// Cpu0FunctionInfo - This class is derived from MachineFunction private
/// Cpu0 target-specific information for each MachineFunction.
class Cpu0FunctionInfo : public MachineFunctionInfo {
public:
  Cpu0FunctionInfo(MachineFunction &MF)
      : MF(MF), VarArgsFrameIndex(0), SRetReturnReg(0), CallsEhReturn(false),
        CallsEhDwarf(false), GlobalBaseReg(0),
        InArgFIRange(std::make_pair(-1, 0)),
        OutArgFIRange(std::make_pair(-1, 0)), GPFI(0), DynAllocFI(0),
        MaxCallFrameSize(0), EmitNOAT(false) {}

  ~Cpu0FunctionInfo() override;

  bool isInArgFI(int FI) const {
    return FI <= InArgFIRange.first && FI >= InArgFIRange.second;
  }
  void setLastInArgFI(int FI) { InArgFIRange.second = FI; }
  bool isOutArgFI(int FI) const {
    return FI <= OutArgFIRange.first && FI >= OutArgFIRange.second;
  }

  int getGPFI() const { return GPFI; }
  void setGPFI(int FI) { GPFI = FI; }
  bool isGPFI(int FI) const { return GPFI && GPFI == FI; }

#ifdef ENABLE_GPRESTORE
  bool needGPSaveRestore() const { return getGPFI(); }
#endif

  bool isDynAllocFI(int FI) { return DynAllocFI && DynAllocFI == FI; }

  int getVarArgsFrameIndex() const { return VarArgsFrameIndex; }
  void setVarArgsFrameIndex(int Index) { VarArgsFrameIndex = Index; }

  unsigned getSRetReturnReg() const { return SRetReturnReg; }
  void setSRetReturnReg(unsigned Reg) { SRetReturnReg = Reg; }

  bool hasByvalArg() const { return HasByValArg; }
  void setFormalArgInfo(unsigned Size, bool HasByVal) {
    IncomingArgSize = Size;
    HasByValArg = HasByVal;
  }

  unsigned getIncomingArgSize() const { return IncomingArgSize; }

  bool callsEhReturn() const { return CallsEhReturn; }
  void setCallsEhReturn() { CallsEhReturn = true; }

  bool callsEhDwarf() const { return CallsEhDwarf; }
  void setCallsEhDwarf() { CallsEhDwarf = true; }

  void createEhDataRegsFI();
  int getEhDataRegFI(unsigned Reg) const { return EhDataRegFI[Reg]; }

  unsigned getMaxCallFrameSize() const { return MaxCallFrameSize; }
  void setMaxCallFrameSize(unsigned Size) { MaxCallFrameSize = Size; }

  bool getEmitNOAT() const { return EmitNOAT; }
  void setEmitNOAT() { EmitNOAT = true; }

  bool globalBaseRegFixed() const;
  bool globalBaseRegSet() const;
  unsigned getGlobalBaseReg();

  /// Create a MachinePointerInfo that has an ExternalSymbolPseudoSourceValue
  /// object representing a GOT entry for an external function.
  MachinePointerInfo callPtrInfo(const char *ES);

  /// Create a MachinePointerInfo that has a GlobalValuePseudoSourceValue object
  /// representing a GOT entry for a global function.
  MachinePointerInfo callPtrInfo(const GlobalValue *GV);

private:
  virtual void anchor();

  MachineFunction &MF;

  // Frame index for start of varargs area.
  int VarArgsFrameIndex;

  // Some subtargets require that sret lowering includes returning the value
  // of the returned struct in a register. This field holds the virtual
  // register into which the sret argument is passed.
  unsigned SRetReturnReg;

  // True if function has a byval argument.
  bool HasByValArg;

  // Size of incoming argument area.
  unsigned IncomingArgSize;

  // Whether the function calls llvm.eh.return.
  bool CallsEhReturn;

  // Whether the function calls llvm.eh.dwarf.
  bool CallsEhDwarf;

  // Frame objects for spilling eh data registers.
  int EhDataRegFI[2];

  // Keeps track of the virtual register initialized for
  // use as the global base register. This is used for PIC in some PIC
  // relocation models.
  unsigned GlobalBaseReg;

  // Range of frame object indices.
  // InArgFIRange: Range of indices of all frame objects created during call to
  //               LowerFormalArguments.
  // OutArgFIRange: Range of indices of all frame objects created during call to
  //                LowerCall except for the frame object for restoring $gp.
  std::pair<int, int> InArgFIRange, OutArgFIRange;

  int GPFI; // Index of the frame object for restoring $gp

  mutable int DynAllocFI; // Frame index of dynamically allocated stack area.

  unsigned MaxCallFrameSize;

  bool EmitNOAT;
};

} // end namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0MACHINEFUNCTION_H
