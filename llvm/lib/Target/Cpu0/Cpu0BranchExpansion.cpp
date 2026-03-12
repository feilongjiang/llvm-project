//===----------------------- Cpu0BranchExpansion.cpp ----------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
/// \file
/// This pass expands a branch or jump instruction into a long branch if its
/// offset is too large to fit into its immediate field.
///
/// FIXME: Fix pc-region jump instructions which cross 256MB segment boundaries.
//===----------------------------------------------------------------------===//

#include "Cpu0.h"
#include "Cpu0MachineFunction.h"
#include "Cpu0TargetMachine.h"
#include "MCTargetDesc/Cpu0BaseInfo.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/CodeGen/MachineFunctionPass.h"
#include "llvm/CodeGen/MachineInstrBuilder.h"
#include "llvm/CodeGen/TargetInstrInfo.h"
#include "llvm/CodeGen/TargetRegisterInfo.h"
#include "llvm/IR/Function.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Target/TargetMachine.h"

using namespace llvm;

#define DEBUG_TYPE "cpu0-branch-expansion"

STATISTIC(LongBranches, "Number of long branches.");

static cl::opt<bool>
    ForceLongBranch("force-cpu0-long-branch", cl::init(false),
                    cl::desc("CPU0: Expand all branches to long format."),
                    cl::Hidden);

namespace {

using Iter = MachineBasicBlock::iterator;
using ReverseIter = MachineBasicBlock::reverse_iterator;

struct MBBInfo {
  uint64_t Size = 0, Address = 0;
  bool HasLongBranch = false;
  MachineInstr *Br = nullptr;

  MBBInfo() = default;
};

class Cpu0BranchExpansion : public MachineFunctionPass {
public:
  static char ID;

  Cpu0BranchExpansion(TargetMachine &tm)
      : MachineFunctionPass(ID), TM(tm), IsPIC(TM.isPositionIndependent()),
        ABI(static_cast<const Cpu0TargetMachine &>(TM).getABI()) {}

  StringRef getPassName() const override {
    return "Cpu0 Branch Expansion Pass";
  }

  bool runOnMachineFunction(MachineFunction &F) override;

private:
  void splitMBB(MachineBasicBlock *MBB);
  void initMBBInfo();
  int64_t computeOffset(const MachineInstr *Br);
  void replaceBranch(MachineBasicBlock &MBB, Iter Br, const DebugLoc &DL,
                     MachineBasicBlock *MBBOpnd);
  void expandToLongBranch(MBBInfo &Info);

  const TargetMachine &TM;
  MachineFunction *MF;
  SmallVector<MBBInfo, 16> MBBInfos;
  bool IsPIC;
  Cpu0ABIInfo ABI;
  unsigned LongBranchSeqSize;
};

char Cpu0BranchExpansion::ID = 0;
} // end of anonymous namespace

/// Returns a pass that clears pipeline hazards.
FunctionPass *llvm::createCpu0BranchExpansionPass(Cpu0TargetMachine &tm) {
  return new Cpu0BranchExpansion(tm);
}

/// Iterate over list of Br's operands and search for a MachineBasicBlock
/// operand.
static MachineBasicBlock *getTargetMBB(const MachineInstr &Br) {
  for (unsigned I = 0, E = Br.getDesc().getNumOperands(); I < E; ++I) {
    const MachineOperand &MO = Br.getOperand(I);

    if (MO.isMBB()) {
      return MO.getMBB();
    }
  }

  llvm_unreachable("This instruction does not have an MBB operand.");
}

// Traverse the list of instructions backwards until a non-debug instruction is
// found or it reaches E.
static ReverseIter getNonDebugInstr(ReverseIter B, const ReverseIter &E) {
  for (; B != E; ++B) {
    if (!B->isDebugInstr()) {
      return B;
    }
  }

  return E;
}

// Split MBB if it has two direct jumps/branches.
void Cpu0BranchExpansion::splitMBB(MachineBasicBlock *MBB) {
  ReverseIter End = MBB->rend();
  ReverseIter LastBr = getNonDebugInstr(MBB->rbegin(), End);

  // Return if MBB has no branch instructions.
  if ((LastBr == End) ||
      (!LastBr->isConditionalBranch() && !LastBr->isUnconditionalBranch())) {
    return;
  }

  ReverseIter FirstBr = getNonDebugInstr(std::next(LastBr), End);

  // MBB has only one branch instruction if FirstBr is not a branch
  // instruction.
  if ((FirstBr == End) ||
      (!FirstBr->isConditionalBranch() && !FirstBr->isUnconditionalBranch())) {
    return;
  }

  assert(!FirstBr->isIndirectBranch() && "Unexpected indirect branch found.");

  // Create a new MBB. Move instructions in MBB to the newly created MBB.
  MachineBasicBlock *NewMBB = MF->CreateMachineBasicBlock(MBB->getBasicBlock());

  // Insert NewMBB and fix control flow.
  MachineBasicBlock *Tgt = getTargetMBB(*FirstBr);
  NewMBB->transferSuccessors(MBB);
  if (Tgt != getTargetMBB(*LastBr)) {
    NewMBB->removeSuccessor(Tgt, true);
  }
  MBB->addSuccessor(NewMBB);
  MBB->addSuccessor(Tgt);
  MF->insert(std::next(MachineFunction::iterator(MBB)), NewMBB);

  NewMBB->splice(NewMBB->end(), MBB, LastBr.getReverse(), MBB->end());
}

// Fill MBBInfos.
void Cpu0BranchExpansion::initMBBInfo() {
  // Split the MBBs if they have two branches. Each basic block should have at
  // most one branch after this loop is executed.
  for (auto &MBB : *MF) {
    splitMBB(&MBB);
  }

  MF->RenumberBlocks();
  MBBInfos.clear();
  MBBInfos.resize(MF->size());

  const Cpu0InstrInfo *TII =
      static_cast<const Cpu0InstrInfo *>(MF->getSubtarget().getInstrInfo());
  for (unsigned I = 0, E = MBBInfos.size(); I < E; ++I) {
    MachineBasicBlock *MBB = MF->getBlockNumbered(I);

    // Compute size of MBB.
    for (MachineBasicBlock::instr_iterator MI = MBB->instr_begin();
         MI != MBB->instr_end(); ++MI) {
      MBBInfos[I].Size += TII->getInstSizeInBytes(*MI);
    }

    // Search for MBB's branch instruction.
    ReverseIter End = MBB->rend();
    ReverseIter Br = getNonDebugInstr(MBB->rbegin(), End);

    if ((Br != End) && !Br->isIndirectBranch() &&
        (Br->isConditionalBranch() || (Br->isUnconditionalBranch() && IsPIC))) {
      MBBInfos[I].Br = &(*Br.getReverse());
    }
  }
}

// Compute offset of branch in number of bytes.
int64_t Cpu0BranchExpansion::computeOffset(const MachineInstr *Br) {
  int64_t Offset = 0;
  int ThisMBB = Br->getParent()->getNumber();
  int TargetMBB = getTargetMBB(*Br)->getNumber();

  // Compute offset of a forward branch.
  if (ThisMBB < TargetMBB) {
    for (int N = ThisMBB + 1; N < TargetMBB; ++N) {
      Offset += MBBInfos[N].Size;
    }

    return Offset + 4;
  }

  // Compute offset of a backward branch.
  for (int N = ThisMBB; N >= TargetMBB; --N) {
    Offset += MBBInfos[N].Size;
  }

  return -Offset + 4;
}

// Replace Br with a branch which has the opposite condition code and a
// MachineBasicBlock operand MBBOpnd.
void Cpu0BranchExpansion::replaceBranch(MachineBasicBlock &MBB, Iter Br,
                                        const DebugLoc &DL,
                                        MachineBasicBlock *MBBOpnd) {
  const Cpu0InstrInfo *TII = static_cast<const Cpu0InstrInfo *>(
      MBB.getParent()->getSubtarget().getInstrInfo());
  unsigned NewOpc = TII->getOppositeBranchOpc(Br->getOpcode());
  const MCInstrDesc &NewDesc = TII->get(NewOpc);

  MachineInstrBuilder MIB = BuildMI(MBB, Br, DL, NewDesc);

  for (unsigned I = 0, E = Br->getDesc().getNumOperands(); I < E; ++I) {
    MachineOperand &MO = Br->getOperand(I);

    if (!MO.isReg()) {
      assert(MO.isMBB() && "MBB operand expected.");
      break;
    }

    MIB.addReg(MO.getReg());
  }

  MIB.addMBB(MBBOpnd);

  if (Br->hasDelaySlot()) {
    // Bundle the instruction in the delay slot to the newly created branch
    // and erase the original branch.
    assert(Br->isBundledWithSucc());
    MachineBasicBlock::instr_iterator II = Br.getInstrIterator();
    MIBundleBuilder(&*MIB).append((++II)->removeFromBundle());
  }
  Br->eraseFromParent();
}

// Expand branch instructions to long branches.
// TODO: This function has to be fixed for beqz16 and bnez16, because it
// currently assumes that all branches have 16-bit offsets, and will produce
// wrong code if branches whose allowed offsets are [-128, -126, ..., 126]
// are present.
void Cpu0BranchExpansion::expandToLongBranch(MBBInfo &I) {
  MachineBasicBlock::iterator Pos;
  MachineBasicBlock *MBB = I.Br->getParent(), *TgtMBB = getTargetMBB(*I.Br);
  DebugLoc DL = I.Br->getDebugLoc();
  const BasicBlock *BB = MBB->getBasicBlock();
  MachineFunction::iterator FallThroughMBB = ++MachineFunction::iterator(MBB);
  MachineBasicBlock *LongBrMBB = MF->CreateMachineBasicBlock(BB);
  const Cpu0Subtarget &Subtarget =
      static_cast<const Cpu0Subtarget &>(MF->getSubtarget());
  const Cpu0InstrInfo *TII =
      static_cast<const Cpu0InstrInfo *>(MF->getSubtarget().getInstrInfo());

  MF->insert(FallThroughMBB, LongBrMBB);
  MBB->replaceSuccessor(TgtMBB, LongBrMBB);

  if (IsPIC) {
    MachineBasicBlock *BalTgtMBB = MF->CreateMachineBasicBlock(BB);
    MF->insert(FallThroughMBB, BalTgtMBB);
    LongBrMBB->addSuccessor(BalTgtMBB);
    BalTgtMBB->addSuccessor(TgtMBB);

    const unsigned BalOp = Cpu0::BAL;

    // $longbr:
    //  addiu $sp, $sp, -8
    //  st $lr, 0($sp)
    //  lui $at, %hi($tgt - $baltgt)
    //  addiu $at, $at, %lo($tgt - $baltgt)
    //  bal $baltgt
    //  nop
    // $baltgt:
    //  addu $at, $lr, $at
    //  ld $lr, 0($sp)
    //  addiu $sp, $sp, 8
    //  jr $at
    //  nop
    // $fallthrough:
    //

    Pos = LongBrMBB->begin();
    BuildMI(*LongBrMBB, Pos, DL, TII->get(Cpu0::ADDiu), Cpu0::SP)
        .addReg(Cpu0::SP)
        .addImm(-8);
    BuildMI(*LongBrMBB, Pos, DL, TII->get(Cpu0::ST))
        .addReg(Cpu0::LR)
        .addReg(Cpu0::SP)
        .addImm(0);

    // LUi and ADDiu instructions create 32-bit offset of the target basic
    // block from the target of BAL instruction.  We cannot use immediate
    // value for this offset because it cannot be determined accurately when
    // the program has inline assembly statements.  We therefore use the
    // relocation expressions %hi($tgt-$baltgt) and %lo($tgt-$baltgt) which
    // are resolved during the fixup, so the values will always be correct.
    //
    // Since we cannot create %hi($tgt-$baltgt) and %lo($tgt-$baltgt)
    // expressions at this point (it is possible only at the MC layer),
    // we replace LUi and ADDiu with pseudo instructions
    // LONG_BRANCH_LUi and LONG_BRANCH_ADDiu, and add both basic
    // blocks as operands to these instructions.  When lowering these pseudo
    // instructions to LUi and ADDiu in the MC layer, we will create
    // %hi($tgt-$baltgt) and %lo($tgt-$baltgt) expressions and add them as
    // operands to lowered instructions.

    BuildMI(*LongBrMBB, Pos, DL, TII->get(Cpu0::LONG_BRANCH_LUi), Cpu0::AT)
        .addMBB(TgtMBB)
        .addMBB(BalTgtMBB);
    BuildMI(*LongBrMBB, Pos, DL, TII->get(Cpu0::LONG_BRANCH_ADDiu), Cpu0::AT)
        .addReg(Cpu0::AT)
        .addMBB(TgtMBB)
        .addMBB(BalTgtMBB);
    MIBundleBuilder(*LongBrMBB, Pos)
        .append(BuildMI(*MF, DL, TII->get(BalOp)).addMBB(BalTgtMBB));

    Pos = BalTgtMBB->begin();

    BuildMI(*BalTgtMBB, Pos, DL, TII->get(Cpu0::ADDu), Cpu0::AT)
        .addReg(Cpu0::LR)
        .addReg(Cpu0::AT);
    BuildMI(*BalTgtMBB, Pos, DL, TII->get(Cpu0::LD), Cpu0::LR)
        .addReg(Cpu0::SP)
        .addImm(0);
    BuildMI(*BalTgtMBB, Pos, DL, TII->get(Cpu0::ADDiu), Cpu0::SP)
        .addReg(Cpu0::SP)
        .addImm(8);

    MIBundleBuilder(*BalTgtMBB, Pos)
        .append(BuildMI(*MF, DL, TII->get(Cpu0::JR)).addReg(Cpu0::AT))
        .append(BuildMI(*MF, DL, TII->get(Cpu0::NOP)));

    assert(LongBrMBB->size() + BalTgtMBB->size() == LongBranchSeqSize);
  } else {
    // $longbr:
    //  jmp $tgt
    //  nop
    // $fallthrough:
    //
    Pos = LongBrMBB->begin();
    LongBrMBB->addSuccessor(TgtMBB);
    MIBundleBuilder(*LongBrMBB, Pos)
        .append(BuildMI(*MF, DL, TII->get(Cpu0::JMP)).addMBB(TgtMBB))
        .append(BuildMI(*MF, DL, TII->get(Cpu0::NOP)));

    assert(LongBrMBB->size() == LongBranchSeqSize);
  }

  if (I.Br->isUnconditionalBranch()) {
    // Change branch destination.
    assert(I.Br->getDesc().getNumOperands() == 1);
    I.Br->removeOperand(0);
    I.Br->addOperand(MachineOperand::CreateMBB(LongBrMBB));
  } else {
    // Change branch destination and reverse condition.
    replaceBranch(*MBB, I.Br, DL, &*FallThroughMBB);
  }
}

static void emitGPDisp(MachineFunction &F, const Cpu0InstrInfo *TII) {
  MachineBasicBlock &MBB = F.front();
  MachineBasicBlock::iterator I = MBB.begin();
  DebugLoc DL = MBB.findDebugLoc(MBB.begin());
  BuildMI(MBB, I, DL, TII->get(Cpu0::LUi), Cpu0::V0)
      .addExternalSymbol("_gp_disp", Cpu0II::MO_ABS_HI);
  BuildMI(MBB, I, DL, TII->get(Cpu0::ADDiu), Cpu0::V0)
      .addReg(Cpu0::V0)
      .addExternalSymbol("_gp_disp", Cpu0II::MO_ABS_LO);
  MBB.removeLiveIn(Cpu0::V0);
}

bool Cpu0BranchExpansion::runOnMachineFunction(MachineFunction &F) {
  const Cpu0Subtarget &STI =
      static_cast<const Cpu0Subtarget &>(F.getSubtarget());
  const Cpu0InstrInfo *TII =
      static_cast<const Cpu0InstrInfo *>(STI.getInstrInfo());
  LongBranchSeqSize = !IsPIC ? 2 : 10;

  if (!STI.enableLongBranchPass()) {
    return false;
  }
  if (IsPIC && static_cast<const Cpu0TargetMachine &>(TM).getABI().IsO32() &&
      F.getInfo<Cpu0FunctionInfo>()->globalBaseRegSet()) {
    emitGPDisp(F, TII);
  }

  MF = &F;
  initMBBInfo();

  SmallVectorImpl<MBBInfo>::iterator I, E = MBBInfos.end();
  bool EverMadeChange = false, MadeChange = true;

  while (MadeChange) {
    MadeChange = false;

    for (I = MBBInfos.begin(); I != E; ++I) {
      // Skip if this MBB doesn't have a branch or the branch has already been
      // converted to a long branch.
      if (!I->Br || I->HasLongBranch) {
        continue;
      }

      int ShVal = 4;
      int64_t Offset = computeOffset(I->Br) / ShVal;

      // Check if offset fits into 16-bit immediate field of branches.
      if (!ForceLongBranch && isInt<16>(Offset)) {
        continue;
      }

      I->HasLongBranch = true;
      I->Size += LongBranchSeqSize * 4;
      ++LongBranches;
      EverMadeChange = MadeChange = true;
    }
  }

  if (!EverMadeChange) {
    return true;
  }

  // Compute basic block addresses.
  if (IsPIC) {
    uint64_t Address = 0;

    for (I = MBBInfos.begin(); I != E; Address += I->Size, ++I) {
      I->Address = Address;
    }
  }

  // Do the expansion.
  for (I = MBBInfos.begin(); I != E; ++I) {
    if (I->HasLongBranch) {
      expandToLongBranch(*I);
    }
  }

  MF->RenumberBlocks();

  return true;
}
