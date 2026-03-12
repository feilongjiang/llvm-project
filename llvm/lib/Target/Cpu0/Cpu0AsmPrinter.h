//===- Cpu0AsmPrinter.h - Cpu0 LLVM Assembly Printer -----------*- C++ -*--===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Cpu0 Assembly printer class.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0ASMPRINTER_H
#define LLVM_LIB_TARGET_CPU0_CPU0ASMPRINTER_H

#include "Cpu0MCInstLower.h"
#include "Cpu0MachineFunction.h"
#include "Cpu0Subtarget.h"
#include "Cpu0TargetMachine.h"
#include "llvm/CodeGen/AsmPrinter.h"
#include "llvm/MC/MCStreamer.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Target/TargetMachine.h"

namespace llvm {

class MCStreamer;
class MachineInstr;
class MachineBasicBlock;
class Module;
class raw_ostream;

class LLVM_LIBRARY_VISIBILITY Cpu0AsmPrinter : public AsmPrinter {

  void EmitInstrWithMacroNoAT(const MachineInstr *MI);

private:
  // lowerOperand - Convert a MachineOperand into the equivalent MCOperand.
  bool lowerOperand(const MachineOperand &MO, MCOperand &MCOp);

  bool isLongBranchPseudo(int Opcode) const;

public:
  const Cpu0Subtarget *Subtarget;
  const Cpu0FunctionInfo *Cpu0FI;
  Cpu0MCInstLower MCInstLowering;

  explicit Cpu0AsmPrinter(TargetMachine &TM,
                          std::unique_ptr<MCStreamer> Streamer)
      : AsmPrinter(TM, std::move(Streamer)), MCInstLowering(*this) {
    Subtarget = static_cast<Cpu0TargetMachine &>(TM).getSubtargetImpl();
  }

  StringRef getPassName() const override { return "Cpu0 Assembly Printer"; }

  virtual bool runOnMachineFunction(MachineFunction &MF) override;

  // - emitInstruction() must exists or will have run time error.
  void emitInstruction(const MachineInstr *MI) override;
  void printSavedRegsBitmask(raw_ostream &O);
  void printHex32(unsigned int Value, raw_ostream &O);
  void emitFrameDirective();
  const char *getCurrentABIString() const;
  void emitFunctionEntryLabel() override;
  void emitFunctionBodyStart() override;
  void emitFunctionBodyEnd() override;
  void emitStartOfAsmFile(Module &M) override;
  void PrintDebugValueComment(const MachineInstr *MI, raw_ostream &OS);
};

} // end namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0ASMPRINTER_H
