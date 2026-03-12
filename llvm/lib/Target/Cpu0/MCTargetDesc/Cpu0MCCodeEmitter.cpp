//===-- Cpu0MCCodeEmitter.cpp - Convert Cpu0 Code to Machine Code ---------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the Cpu0MCCodeEmitter class.
//
//===----------------------------------------------------------------------===//

#include "Cpu0MCCodeEmitter.h"
#include "MCTargetDesc/Cpu0BaseInfo.h"
#include "MCTargetDesc/Cpu0FixupKinds.h"
#include "MCTargetDesc/Cpu0MCExpr.h"
#include "MCTargetDesc/Cpu0MCTargetDesc.h"
#include "llvm/MC/MCCodeEmitter.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCInst.h"
#include "llvm/MC/MCInstrInfo.h"
#include "llvm/MC/MCRegisterInfo.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#define DEBUG_TYPE "mccodeemitter"

#define GET_INSTRMAP_INFO
#include "Cpu0GenInstrInfo.inc"
#undef GET_INSTRMAP_INFO

namespace llvm {

MCCodeEmitter *createCpu0MCCodeEmitterEB(const MCInstrInfo &MCII,
                                         MCContext &Ctx) {
  return new Cpu0MCCodeEmitter(MCII, Ctx, false);
}

MCCodeEmitter *createCpu0MCCodeEmitterEL(const MCInstrInfo &MCII,
                                         MCContext &Ctx) {
  return new Cpu0MCCodeEmitter(MCII, Ctx, true);
}

} // end namespace llvm

void Cpu0MCCodeEmitter::EmitByte(unsigned char C, raw_ostream &OS) const {
  OS << (char)C;
}

void Cpu0MCCodeEmitter::EmitInstruction(uint64_t Val, unsigned Size,
                                        raw_ostream &OS) const {
  // Output the instruction encoding in little endian byte order.
  for (unsigned i = 0; i < Size; ++i) {
    unsigned Shift = IsLittleEndian ? i * 8 : (Size - 1 - i) * 8;
    EmitByte((Val >> Shift) & 0xff, OS);
  }
}

// Emit the instruction.
// Size the instruction (currently only 4 bytes)
void Cpu0MCCodeEmitter::encodeInstruction(const MCInst &MI, raw_ostream &OS,
                                          SmallVectorImpl<MCFixup> &Fixups,
                                          const MCSubtargetInfo &STI) const {
  uint32_t Binary = getBinaryCodeForInstr(MI, Fixups, STI);

  // Check for unimplemented opcodes.
  // Unfortunately in CPU0 both NOT and SLL will come in with Binary == 0
  // so we have tot special check for them.
  unsigned Opcode = MI.getOpcode();
  if ((Opcode != Cpu0::NOP) && (Opcode != Cpu0::SHL) && !Binary) {
    llvm_unreachable("unimplemented opcode in encodeInstruction()");
  }

  const MCInstrDesc &Desc = MCII.get(MI.getOpcode());
  uint64_t TSFlags = Desc.TSFlags;

  // Pseudo instructions don't get encoded and shouldn't be here
  // in the first place!
  if ((TSFlags & Cpu0II::FormMask) == Cpu0II::Pseudo) {
    llvm_unreachable("Pseudo opcode found in encodingInstruction()");
  }

  // For now all instructions are 4 bytes
  int Size = 4;
  EmitInstruction(Binary, Size, OS);
}

unsigned
Cpu0MCCodeEmitter::getBranch16TargetOpValue(const MCInst &MI, unsigned OpNo,
                                            SmallVectorImpl<MCFixup> &Fixups,
                                            const MCSubtargetInfo &STI) const {
  const MCOperand &MO = MI.getOperand(OpNo);

  // If the destination is an immediate, we have nothing to do.
  if (MO.isImm()) {
    return MO.getImm();
  }
  assert(MO.isExpr() && "getBranch16TargetOpValue expects only expressions");

  const MCExpr *Expr = MO.getExpr();
  Fixups.push_back(
      MCFixup::create(0, Expr, MCFixupKind(Cpu0::fixup_Cpu0_PC16)));

  return 0;
}

unsigned
Cpu0MCCodeEmitter::getBranch24TargetOpValue(const MCInst &MI, unsigned OpNo,
                                            SmallVectorImpl<MCFixup> &Fixups,
                                            const MCSubtargetInfo &STI) const {
  const MCOperand &MO = MI.getOperand(OpNo);

  // If the destination is an immediate, we have nothing to do.
  if (MO.isImm()) {
    return MO.getImm();
  }
  assert(MO.isExpr() && "getBranch24TargetOpValue expects only expressions");

  const MCExpr *Expr = MO.getExpr();
  Fixups.push_back(
      MCFixup::create(0, Expr, MCFixupKind(Cpu0::fixup_Cpu0_PC24)));

  return 0;
}

unsigned
Cpu0MCCodeEmitter::getJumpTargetOpValue(const MCInst &MI, unsigned OpNo,
                                        SmallVectorImpl<MCFixup> &Fixups,
                                        const MCSubtargetInfo &STI) const {
  unsigned Opcode = MI.getOpcode();
  const MCOperand &MO = MI.getOperand(OpNo);

  // If the destination is an immediate, we have nothing to do.
  if (MO.isImm()) {
    return MO.getImm();
  }
  assert(MO.isExpr() && "getJumpTargetOpValue expects only expressions");

  const MCExpr *Expr = MO.getExpr();
  if (Opcode == Cpu0::JMP || Opcode == Cpu0::BAL) {
    Fixups.push_back(
        MCFixup::create(0, Expr, MCFixupKind(Cpu0::fixup_Cpu0_PC24)));
  } else {
    llvm_unreachable("unexpected opcode in getJumpTargetOpValue()");
  }

  return 0;
}

unsigned Cpu0MCCodeEmitter::getExprOpValue(const MCExpr *Expr,
                                           SmallVectorImpl<MCFixup> &Fixups,
                                           const MCSubtargetInfo &STI) const {
  MCExpr::ExprKind Kind = Expr->getKind();
  if (Kind == MCExpr::Constant) {
    return cast<MCConstantExpr>(Expr)->getValue();
  }

  if (Kind == MCExpr::Binary) {
    unsigned Res =
        getExprOpValue(cast<MCBinaryExpr>(Expr)->getLHS(), Fixups, STI);
    Res += getExprOpValue(cast<MCBinaryExpr>(Expr)->getRHS(), Fixups, STI);
    return Res;
  }

  if (Kind == MCExpr::Target) {
    const Cpu0MCExpr *Cpu0Expr = cast<Cpu0MCExpr>(Expr);

    Cpu0::Fixups FixupKind = Cpu0::Fixups(0);
    switch (Cpu0Expr->getKind()) {
    default:
      llvm_unreachable("Unsupported fixup kind for target expression!");
    }
    Fixups.push_back(MCFixup::create(0, Expr, MCFixupKind(FixupKind)));
    return 0;
  }

  // All of the information is in the fixup.
  return 0;
}

unsigned
Cpu0MCCodeEmitter::getMachineOpValue(const MCInst &MI, const MCOperand &MO,
                                     SmallVectorImpl<MCFixup> &Fixups,
                                     const MCSubtargetInfo &STI) const {
  if (MO.isReg()) {
    unsigned Reg = MO.getReg();
    unsigned RegNo = Ctx.getRegisterInfo()->getEncodingValue(Reg);
    return RegNo;
  } else if (MO.isImm()) {
    return static_cast<unsigned>(MO.getImm());
  } else if (MO.isDFPImm()) {
    return static_cast<unsigned>(bit_cast<double>(MO.getDFPImm()));
  }

  // MO must be an Expr.
  assert(MO.isExpr());
  return getExprOpValue(MO.getExpr(), Fixups, STI);
}

// Return binary encoding of memory related operand.
// If the offset operand requires relocation, record the relocation.
unsigned Cpu0MCCodeEmitter::getMemEncoding(const MCInst &MI, unsigned OpNo,
                                           SmallVectorImpl<MCFixup> &Fixups,
                                           const MCSubtargetInfo &STI) const {
  // Base register is encoded in bits 20-16, offset is encoded in bits 15-0.
  assert(MI.getOperand(OpNo).isReg());
  unsigned RegBits = getMachineOpValue(MI, MI.getOperand(OpNo), Fixups, STI)
                     << 16;
  unsigned OffBits =
      getMachineOpValue(MI, MI.getOperand(OpNo + 1), Fixups, STI);

  return (OffBits & 0xffff) | RegBits;
}

#include "Cpu0GenMCCodeEmitter.inc"
