//===----------------------- Cpu0DelUselessJMP.cpp ------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Simple pass to remove useless JMP instructions.
//
//===----------------------------------------------------------------------===//

#include "Cpu0.h"
#include "Cpu0TargetMachine.h"
#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Target/TargetMachine.h"

using namespace llvm;

#define DEBUG_TYPE "del-jmp"

STATISTIC(NumDelJmp, "Number of useless jmp deleted");

static cl::opt<bool>
    EnableDelJmp("enable-cpu0-del-useless-jmp", cl::init(true),
                 cl::desc("Delete useless jmp instructions: jmp 0."),
                 cl::Hidden);

namespace {

class DelJmp : public MachineFunctionPass {
public:
  DelJmp(TargetMachine &tm) : MachineFunctionPass(ID) {}

  StringRef getPassName() const override { return "Cpu0 Del Useless jmp"; }

  bool runOnMachineFunction(MachineFunction &F) override {
    bool Changed = false;
    if (EnableDelJmp) {
      MachineFunction::iterator FJ = F.begin();
      if (FJ != F.end()) {
        FJ++;
      }
      if (FJ == F.end()) {
        return Changed;
      }
      for (MachineFunction::iterator FI = F.begin(), FE = F.end(); FJ != FE;
           ++FI, ++FJ) {
        // In STL style, F.end() is the dummy BasicBlock() like '\0' in
        // C string.
        // FJ is the next BasicBlock of FI; When FI range from F.begin() to
        // the PreviousBasicBlock of F.end() call runOnMachineBasicBlock().
        Changed |= runOnMachineBasicBlock(*FI, *FJ);
      }
    }
    return Changed;
  }

private:
  bool runOnMachineBasicBlock(MachineBasicBlock &MBB, MachineBasicBlock &MBBN);

  static char ID;
};
char DelJmp::ID = 0;
} // end of anonymous namespace

bool DelJmp::runOnMachineBasicBlock(MachineBasicBlock &MBB,
                                    MachineBasicBlock &MBBN) {
  bool Changed = false;

  MachineBasicBlock::iterator I = MBB.end();
  if (I != MBB.begin()) {
    I--; // set I to the last instruction
  } else {
    return Changed;
  }

  if (I->getOpcode() == Cpu0::JMP && I->getOperand(0).getMBB() == &MBBN) {
    // I is the instruction of "jmp #offset=0", as follows,
    //    jmp $BB0_3
    // $BB0_3:
    //    ld  $4, 28($sp)
    ++NumDelJmp;
    MBB.erase(I);   // delete the "JMP 0" instruction
    Changed = true; // Notify LLVM kernel Changed
  }

  return Changed;
}

/// createCpu0DelJmpPass - Returns a pass that DelJmp in Cpu0 MachineFunctions
FunctionPass *llvm::createCpu0DelJmpPass(Cpu0TargetMachine &tm) {
  return new DelJmp(tm);
}
