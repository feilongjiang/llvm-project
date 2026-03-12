//===-- Cpu0CondMov.td - Describe Cpu0 Conditional Moves --*- tablegen -*--===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This is the Conditional Moves implementation.
//
//===----------------------------------------------------------------------===//

// Conditional moves:
// These instructions are expanded in
// Cpu0ISelLowering::EmitInstrWithCustomInserter if target does not have
// conditional move instructions.
// cond:int, data:int
class CondMovIntInt<RegisterClass CRC, RegisterClass DRC, bits<8> op,
                    string instr_asm>
  : FA<op, (outs DRC:$ra), (ins DRC:$rb, CRC:$rc, DRC:$F),
       !strconcat(instr_asm, "\t$ra, $rb, $rc"), [], IIAlu> {
  let shamt = 0;
  let Constraints = "$F = $ra";
}

// select patterns
multiclass MovzPats0Slt<RegisterClass CRC, RegisterClass DRC,
                        Instruction MOVZInst, Instruction SLTOp,
                        Instruction SLTuOp,   Instruction SLTiOp,
                        Instruction SLTiuOp> {
  def : Pat<(select (i32 (setge CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTOp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (setuge CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTuOp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (setge CRC:$lhs, immSExt16:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTiOp CRC:$lhs, immSExt16:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (setuge CRC:$lhs, immSExt16:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTiuOp CRC:$lhs, immSExt16:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (setle CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTOp CRC:$rhs, CRC:$lhs), DRC:$F)>;
  def : Pat<(select (i32 (setule CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (SLTuOp CRC:$rhs, CRC:$lhs), DRC:$F)>;
}

multiclass MovzPats1<RegisterClass CRC, RegisterClass DRC,
                     Instruction MOVZInst, Instruction XOROp> {
  def : Pat<(select (i32 (seteq CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (XOROp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (seteq CRC:$lhs, 0)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, CRC:$lhs, DRC:$F)>;
}

multiclass MovnPats<RegisterClass CRC, RegisterClass DRC,
                    Instruction MOVNInst, Instruction XOROp> {
  def : Pat<(select (i32 (setne CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVNInst DRC:$T, (XOROp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select CRC:$cond, DRC:$T, DRC:$F),
            (MOVNInst DRC:$T, CRC:$cond, DRC:$F)>;
  def : Pat<(select (i32 (setne CRC:$lhs, 0)), DRC:$T, DRC:$F),
            (MOVNInst DRC:$T, CRC:$lhs, DRC:$F)>;
}

// Instantiation of instructions.
def MOVZ_I_I    : CondMovIntInt<CPURegs, CPURegs, 0x0a, "movz">;
def MOVN_I_I    : CondMovIntInt<CPURegs, CPURegs, 0x0b, "movn">;

// Instantiation of conditional move patterns.
let Predicates = [HasSlt] in {
  defm : MovzPats0Slt<CPURegs, CPURegs, MOVZ_I_I, SLT, SLTu, SLTi, SLTiu>;
}

defm : MovzPats1<CPURegs, CPURegs, MOVZ_I_I, XOR>;
defm : MovnPats<CPURegs, CPURegs, MOVN_I_I, XOR>;