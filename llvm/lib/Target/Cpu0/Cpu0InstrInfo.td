//===- Cpu0InstrInfo.td - Target Description for Cpu0 Target -*- tablegen -*-=//
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


//===----------------------------------------------------------------------===//
// Cpu0 profiles and nodes
//===----------------------------------------------------------------------===//

def SDT_Cpu0Ret : SDTypeProfile<0, 1, [SDTCisInt<0>]>;

def SDT_Cpu0DivRem : SDTypeProfile<0, 2, [SDTCisInt<0>, SDTCisSameAs<0, 1>]>;

// Return
def Cpu0Ret : SDNode<"Cpu0ISD::Ret", SDTNone,
                     [SDNPHasChain, SDNPOptInGlue, SDNPVariadic]>;

// DivRem(u)
def Cpu0DivRem  : SDNode<"Cpu0ISD::DivRem",  SDT_Cpu0DivRem, [SDNPOutGlue]>;
def Cpu0DivRemU : SDNode<"Cpu0ISD::DivRemU", SDT_Cpu0DivRem, [SDNPOutGlue]>;

// Hi and Lo nodes are used to handle global addresses. Used on
// Cpu0ISelLowering to lower stuff loke GlobalAddress, ExternalSymbol
// static model. (nothing to do with Cpu0 Registers Hi and Lo)
def Cpu0Hi      : SDNode<"Cpu0ISD::Hi",      SDTIntUnaryOp>;
def Cpu0Lo      : SDNode<"Cpu0ISD::Lo",      SDTIntUnaryOp>;
def Cpu0GPRel   : SDNode<"Cpu0ISD::GPRel",   SDTIntUnaryOp>;

def Cpu0Wrapper : SDNode<"Cpu0ISD::Wrapper", SDTIntBinOp>;

//===----------------------------------------------------------------------===//
// Cpu0 Instruction Predicate Definitions
//===----------------------------------------------------------------------===//
def EnableOverflow  : Predicate<"Subtarget->enableOverflow()">;
def DisableOverFlow : Predicate<"Subtarget->disableOverflow()">;

def HasCmp          : Predicate<"Subtarget->hasCmp()">;
def HasSlt          : Predicate<"Subtarget->hasSlt()">;

def RelocPIC        : Predicate<"TM.getRelocationModel() == Reloc::PIC_">;

//===----------------------------------------------------------------------===//
// Instruction format superclass
//===----------------------------------------------------------------------===//

include "Cpu0InstrFormats.td"

//===----------------------------------------------------------------------===//
// Cpu0 Operand, Complex Patterns and Transformations Definitions
//===----------------------------------------------------------------------===//

// Instruction operand types

// Signed Operand
def simm16 : Operand<i32> {
  let DecoderMethod = "DecodeSimm16";
}

def shamt : Operand<i32>;

// Unsigned Operand
def uimm16 : Operand<i32> {
  let PrintMethod = "printUnsignedImm";
}

// Address Operand
def mem : Operand<iPTR> {
  let PrintMethod   = "printMemOperand";
  let MIOperandInfo = (ops CPURegs, simm16);
  let EncoderMethod = "getMemEncoding";
}

// Node immediate fits as 16-bit sign extended on target immediate.
// e.g. addi, andi
def immSExt16 : PatLeaf<(imm), [{ return isInt<16>(N->getSExtValue()); }]>;

// Get the lower 16 bits.
def LO16 : SDNodeXForm<imm, [{ return getImm(N, N->getZExtValue() & 0xffff); }]>;

// Get the higher 16 bits.
def HI16 : SDNodeXForm<imm, [{ return getImm(N, (N->getZExtValue() >> 16) & 0xffff); }]>;

// Node immediate fits as 16-bit zero extended on target immediate.
// The LO16 param means that only the lower 16 bits of the node
// immediate are caught.
def immZExt16 : PatLeaf<(imm), [{
  if (N->getValueType(0) == MVT::i32) {
    return (uint32_t)N->getZExtValue() == (unsigned short)N->getZExtValue();
  } else {
    return (uint64_t)N->getZExtValue() == (unsigned short)N->getZExtValue();
  }
}], LO16>;

// Immediate can be loaded with LUi (32-bit int with lower 16-bit cleared).
def immLow16Zero : PatLeaf<(imm), [{
  int64_t Val = N->getSExtValue();
  return isInt<32>(Val) && !(Val & 0xffff);
}]>;

// shamt field must fit in 5 bits.
def immZExt5 : ImmLeaf<i32, [{ return Imm == (Imm & 0x1f); }]>;

// Cpu0 Address Mode! SDNode frameindex could posibily be a match since
// load and store instructions from stack used it.
def addr : ComplexPattern<iPTR, 2, "SelectAddr", [frameindex], [SDNPWantParent]>;

//===----------------------------------------------------------------------===//
// Pattern fragment for load/store
//===----------------------------------------------------------------------===//

class AlignedLoad<PatFrag Node>
  : PatFrag<(ops node:$ptr), (Node node:$ptr), [{
    LoadSDNode *LD = cast<LoadSDNode>(N);
    return LD->getMemoryVT().getSizeInBits()/8 <= LD->getAlignment();
  }]>;

class AlignedStore<PatFrag Node>
  : PatFrag<(ops node:$val, node:$ptr), (Node node:$val, node:$ptr), [{
    StoreSDNode *ST = cast<StoreSDNode>(N);
    return ST->getMemoryVT().getSizeInBits()/8 <= ST->getAlignment();
  }]>;


// Load/Store PatFrags
def load_a  : AlignedLoad<load>;
def store_a : AlignedStore<store>;

//===----------------------------------------------------------------------===//
// Instructions specific format
//===----------------------------------------------------------------------===//

// Arithmetic and logical instructions with 2 register operands
class ArithLogicI<bits<8> op, string instrAsm, SDNode opNode,
                  Operand od, PatLeaf immType, RegisterClass regClass>
  : FL<op, (outs GPROut:$ra), (ins regClass:$rb, od:$imm16),
       !strconcat(instrAsm, "\t$ra, $rb, $imm16"),
       [(set GPROut:$ra, (opNode regClass:$rb, immType:$imm16))], IIAlu> {
  let isReMaterializable = 1;
}

// Arithmetic and logical instructions with 3 register operands.
class ArithLogicR<bits<8> op, string instrAsm, SDNode opNode,
                  InstrItinClass itin, RegisterClass RC, bit isComm = 0>
  : FA<op, (outs GPROut:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(instrAsm, "\t$ra, $rb, $rc"),
       [(set GPROut:$ra, (opNode RC:$rb, RC:$rc))], itin> {
  let shamt = 0;
  let isCommutable = isComm;  // e.g. add rb rc = add rc rb
  let isReMaterializable = 1;
}

// Shifts
class shift_rotate_imm<bits<8> op, bits<4> isRotate, string instrAsm,
                       SDNode opNode, PatFrag PF, Operand ImmOpnd,
                       RegisterClass RC>
  : FA<op, (outs GPROut:$ra), (ins RC:$rb, ImmOpnd:$shamt),
       !strconcat(instrAsm, "\t$ra, $rb, $shamt"),
       [(set GPROut:$ra, (opNode RC:$rb, PF:$shamt))], IIAlu> {
  let rc = 0;
}

class shift_rotate_reg<bits<8> op, bits<4> isRotate, string instrAsm,
                       SDNode opNode, RegisterClass RC>
  : FA<op, (outs GPROut:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(instrAsm, "\t$ra, $rb, $rc"),
       [(set GPROut:$ra, (opNode RC:$rb, RC:$rc))], IIAlu> {
  let shamt = 0;
}

// 32-bit shift instructions.
class shift_rotate_imm32<bits<8> op, bits<4> isRotate, string instrAsm, SDNode opNode>
  : shift_rotate_imm<op, isRotate, instrAsm, opNode, immZExt5, shamt, CPURegs>;

class LoadUpper<bits<8> op, string Asm, RegisterClass RC, Operand Imm>
  : FL<op, (outs RC:$ra), (ins Imm:$imm16),
       !strconcat(Asm, "\t$ra, $imm16"), [], IIAlu> {
  let rb = 0;
  let isReMaterializable = 1;
}

// Mul, Div
class Mult<bits<8> op, string strAsm, InstrItinClass itin,
           RegisterClass RC, list<Register> DefRegs>
  : FA<op, (outs), (ins RC:$ra, RC:$rb),
       !strconcat(strAsm, "\t$ra, $rb"), [], itin> {
  let rc = 0;
  let shamt = 0;
  let isCommutable = 1;
  let Defs = DefRegs;
  let hasSideEffects = 0;
}

class Mult32<bits<8> op, string strAsm, InstrItinClass itin>
  : Mult<op, strAsm, itin, CPURegs, [HI, LO]>;

class Div<SDNode opNode, bits<8> op, string strAsm, InstrItinClass itin,
          RegisterClass RC, list<Register> DefRegs>
  : FA<op, (outs), (ins RC:$ra, RC:$rb),
       !strconcat(strAsm, "\t$ra, $rb"),
       [(opNode RC:$ra, RC:$rb)], itin> {
  let rc = 0;
  let shamt = 0;
  let Defs = DefRegs;
}

class Div32<SDNode opNode, bits<8> op, string strAsm, InstrItinClass itin>
  : Div<opNode, op, strAsm, itin, CPURegs, [HI, LO]>;

// Move from Lo/Hi
class MoveFromLOHI<bits<8> op, string strAsm, RegisterClass RC, list<Register> UseRegs>
  : FA<op, (outs RC:$ra), (ins),
       !strconcat(strAsm, "\t$ra"), [], IIHiLo> {
  let rb = 0;
  let rc = 0;
  let shamt = 0;
  let Uses = UseRegs;
  let hasSideEffects = 0;
}

// Move to Lo/Hi
class MoveToLOHI<bits<8> op, string strAsm, RegisterClass RC, list<Register> DefRegs>
  : FA<op, (outs), (ins RC:$ra),
       !strconcat(strAsm, "\t$ra"), [], IIHiLo> {
  let rb = 0;
  let rc = 0;
  let shamt = 0;
  let Defs = DefRegs;
  let hasSideEffects = 0;
}

// Move from C0 (co-processor 0) Register
class MoveFromC0<bits<8> op, string strAsm, RegisterClass RC>
  : FA<op, (outs), (ins RC:$ra, C0Regs:$rb),
       !strconcat(strAsm, "\t$ra, $rb"), [], IIAlu> {
  let rc = 0;
  let shamt = 0;
  let hasSideEffects = 0;
}

// Move to C0 Register
class MoveToC0<bits<8> op, string strAsm, RegisterClass RC>
  : FA<op, (outs C0Regs:$ra), (ins RC:$rb),
       !strconcat(strAsm, "\t$ra, $rb"), [], IIAlu> {
  let rc = 0;
  let shamt = 0;
  let hasSideEffects = 0;
}

// Move from C0 Register to C0 Register
class C0Move<bits<8> op, string strAsm>
  : FA<op, (outs C0Regs:$ra), (ins C0Regs:$rb),
       !strconcat(strAsm, "\t$ra, $rb"), [], IIAlu> {
  let rc = 0;
  let shamt = 0;
  let hasSideEffects = 0;
}

// Compare
class CmpInstr<bits<8> op, string strAsm, InstrItinClass itin,
               RegisterClass RC, RegisterClass RD, bit isComm = 0>
  : FA<op, (outs RD:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(strAsm, "\t$ra, $rb, $rc"), [], itin> {
  let shamt = 0;
  let isCommutable = isComm;
  let Predicates = [HasCmp];
}

// Logical
class LogicNOR<bits<8> op, string strAsm, RegisterClass RC>
  : FA<op, (outs RC:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(strAsm, "\t$ra, $rb, $rc"),
       [(set RC:$ra, (not (or RC:$rb, RC:$rc)))], IIAlu> {
  let shamt = 0;
  let isCommutable = 1;
}

// SetCC
class SetCC_R<bits<8> op, string strAsm, PatFrag cond_op, RegisterClass RC>
  : FA<op, (outs GPROut:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(strAsm, "\t$ra, $rb, $rc"),
       [(set GPROut:$ra, (cond_op RC:$rb, RC:$rc))], IIAlu>, Requires<[HasSlt]> {
  let shamt = 0;
}

class SetCC_I<bits<8> op, string strAsm, PatFrag cond_op, Operand Od,
              PatLeaf imm_type, RegisterClass RC>
  : FL<op, (outs GPROut:$ra), (ins RC:$rb, Od:$imm16),
       !strconcat(strAsm, "\t$ra, $rb, $imm16"),
       [(set GPROut:$ra, (cond_op RC:$rb, imm_type:$imm16))], IIAlu>, Requires<[HasSlt]> {
}


class FMem<bits<8> op, dag outs, dag ins, string asmStr, list<dag> pattern, InstrItinClass itin>
  : FL<op, outs, ins, asmStr, pattern, itin> {
  bits<20> addr;
  let Inst{19-16}   = addr{19-16};
  let Inst{15-0}    = addr{15-0};
  let DecoderMethod = "DecodeMem";
}

// Memory Load/Store
let canFoldAsLoad = 1 in
class LoadM<bits<8> op, string instrAsm, PatFrag opNode, RegisterClass regClass, Operand od, bit pseudo>
  : FMem<op, (outs regClass:$ra), (ins od:$addr),
         !strconcat(instrAsm, "\t$ra, $addr"),
         [(set regClass:$ra, (opNode addr:$addr))], IILoad> {
  let isPseudo = pseudo;
}

class StoreM<bits<8> op, string instrAsm, PatFrag opNode, RegisterClass regClass, Operand od, bit pseudo>
  : FMem<op, (outs), (ins regClass:$ra, od:$addr),
         !strconcat(instrAsm, "\t$ra, $addr"),
         [(opNode regClass:$ra, addr:$addr)], IIStore> {
  let isPseudo = pseudo;
}

// 32-bit load
class LoadM32<bits<8> op, string instrAsm, PatFrag opNode, bit pseudo=0>
  : LoadM<op, instrAsm, opNode, GPROut, mem, pseudo> {}

// 32-bit store
class StoreM32<bits<8> op, string instrAsm, PatFrag opNode, bit pseudo=0>
  : StoreM<op, instrAsm, opNode, CPURegs, mem, pseudo> {}

// JumpFR
let isBranch=1, isTerminator=1, isBarrier=1, hasDelaySlot=1, isIndirectBranch=1 in
class JumpFR<bits<8> op, string instrAsm, RegisterClass regClass>
  : FL<op, (outs), (ins regClass:$ra),
       !strconcat(instrAsm, "\t$ra"), [(brind regClass:$ra)], IIBranch> {
  let rb    = 0;
  let imm16 = 0;
}

// Return
class RetBase<RegisterClass regClass> : JumpFR<0x3c, "ret", regClass> {
  let isReturn      = 1;
  let isCodeGenOnly = 1;
  let hasCtrlDep    = 1;
  let hasExtraSrcRegAllocReq = 1;
}

class Cpu0InstAlias<string Asm, dag Result, bit Emit = 0b1>
  : InstAlias<Asm, Result, Emit>;

//===----------------------------------------------------------------------===//
// Instruction definition
//===----------------------------------------------------------------------===//
// Load and Store Instructions
// aligned
def LD   : LoadM32<0x01,  "ld", load_a>;
def ST   : StoreM32<0x02, "st", store_a>;

// Arithmetic Instructions (ALU Immediate)
def ADDiu : ArithLogicI<0x09, "addiu", add, simm16, immSExt16, CPURegs>;
def ANDi  : ArithLogicI<0x0c, "andi", and, uimm16, immZExt16, CPURegs>;
def ORi   : ArithLogicI<0x0d, "ori", or, uimm16, immZExt16, CPURegs>;
def XORi  : ArithLogicI<0x0e, "xori", xor, uimm16, immZExt16, CPURegs>;

def LUi   : LoadUpper<0x0f, "lui", GPROut, uimm16>;

// Arithmetic Instrucitons (3-Operand, R-Type)
let Predicates = [DisableOverFlow] in {
  def ADDu  : ArithLogicR<0x11, "addu", add, IIAlu, CPURegs, 1>;
  def SUBu  : ArithLogicR<0x12, "subu", sub, IIAlu, CPURegs>;
}

let Predicates = [EnableOverflow] in {
  def ADD   : ArithLogicR<0x13, "add", add, IIAlu, CPURegs, 1>;
  def SUB   : ArithLogicR<0x14, "sub", sub, IIAlu, CPURegs>;
}

def AND     : ArithLogicR<0x18, "and", and, IIAlu, CPURegs, 1>;
def OR      : ArithLogicR<0x19, "or", or, IIAlu, CPURegs, 1>;
def XOR     : ArithLogicR<0x1a, "xor", xor, IIAlu, CPURegs, 1>;
def NOR     : LogicNOR<0x1b, "nor", CPURegs>;

// Multiply and Divide Instructions
def MUL     : ArithLogicR<0x17, "mul", mul, IIImul, CPURegs, 1>;
def MULT    : Mult32<0x41, "mult", IIImul>;
def MULTu   : Mult32<0x42, "multu", IIImul>;
def SDIV    : Div32<Cpu0DivRem, 0x43, "div", IIIdiv>;
def UDIV    : Div32<Cpu0DivRemU, 0x44, "divu", IIIdiv>;

// Shift Instrucitons
def SHL     : shift_rotate_imm32<0x1e, 0x00, "shl", shl>;
// sra is IR node for ashr llvm IR instruction of .bc
def ROL     : shift_rotate_imm32<0x1c, 0x01, "rol", rotl>;
def ROR     : shift_rotate_imm32<0x1d, 0x01, "ror", rotr>;
// srl is IR node for lshr llvm IR instruction of .bc
def SHR     : shift_rotate_imm32<0x1f, 0x00, "shr", srl>;
def SRA     : shift_rotate_imm32<0x20, 0x00, "sra", sra>;

def SRAV    : shift_rotate_reg<0x21, 0x00, "srav", sra,  CPURegs>;
def SHLV    : shift_rotate_reg<0x22, 0x00, "shlv", shl,  CPURegs>;
def SHRV    : shift_rotate_reg<0x23, 0x00, "shrv", srl,  CPURegs>;
def ROLV    : shift_rotate_reg<0x24, 0x01, "rolv", rotl, CPURegs>;
def RORV    : shift_rotate_reg<0x25, 0x01, "rorv", rotr, CPURegs>;

// Move Instructions
def MFHI    : MoveFromLOHI<0x46, "mfhi", CPURegs, [HI]>;
def MFLO    : MoveFromLOHI<0x47, "mflo", CPURegs, [LO]>;
def MTHI    : MoveToLOHI<0x48, "mthi", CPURegs, [HI]>;
def MTLO    : MoveToLOHI<0x49, "mtlo", CPURegs, [LO]>;

def MFC0    : MoveFromC0<0x50, "mfc0", CPURegs>;
def MTC0    : MoveToC0<0x51, "mtc0", CPURegs>;

def C0MOVE  : C0Move<0x52, "c0mov">;

// Compare Instructions
let Predicates = [HasCmp] in {
  def CMP   : CmpInstr<0x2a, "cmp", IIAlu, CPURegs, SR, 0>;
  def CMPu  : CmpInstr<0x2b, "cmpu", IIAlu, CPURegs, SR, 0>;
}

let Predicates = [HasSlt] in {
  def SLTi  : SetCC_I<0x26, "slti", setlt, simm16, immSExt16, CPURegs>;
  def SLTiu : SetCC_I<0x27, "sltiu", setult, simm16, immSExt16, CPURegs>;
  def SLT   : SetCC_R<0x28, "slt", setlt, CPURegs>;
  def SLTu  : SetCC_R<0x29, "sltu", setult, CPURegs>;
}

// Jump Instrucitons
def JR      : JumpFR<0x3c, "jr", GPROut>;

def RET     : RetBase<GPROut>;

let isReturn=1, isTerminator=1, hasDelaySlot=1, isBarrier=1, hasCtrlDep=1 in
  def RetLR : Cpu0Pseudo<(outs), (ins), "", [(Cpu0Ret)]>;

// No Operation Instructions
let addr=0 in
  def NOP   : FJ<0x00, (outs), (ins), "nop", [], IIAlu>;

//===----------------------------------------------------------------------===//
// Arbitrary patterns that map to one or more instructions
//===----------------------------------------------------------------------===//

// Small Immediates
def : Pat<(i32 immSExt16:$in), (ADDiu ZERO, imm:$in)>;
def : Pat<(i32 immZExt16:$in), (ORi ZERO, imm:$in)>;
def : Pat<(i32 immLow16Zero:$in), (LUi (HI16 imm:$in))>;

// Arbitrary immediates
def : Pat<(i32 imm:$imm), (ORi (LUi (HI16 imm:$imm)), (LO16 imm:$imm))>;

// 1's complement of in, ex. not(0xf000000f) == 0x0ffffff0
def : Pat<(not CPURegs:$in), (NOR CPURegs:$in, ZERO)>;

// setcc patterns
multiclass SeteqPatsCmp<RegisterClass RC> {
  // a == b
  def : Pat<(seteq RC:$lhs, RC:$rhs),
            (SHR (ANDi (CMP RC:$lhs, RC:$rhs), 2), 1)>;

  // a != b
  def : Pat<(setne RC:$lhs, RC:$rhs),
            (XORi (SHR (ANDi (CMP RC:$lhs, RC:$rhs), 2), 1), 1)>;
}

// a < b
multiclass SetltPatsCmp<RegisterClass RC> {
  def : Pat<(setlt RC:$lhs, RC:$rhs),
            (ANDi (CMP RC:$lhs, RC:$rhs), 1)>;
  // if cpu0 `define N `SW[31] instead of `SW[0] // Negative flag, then need
  // 2 more instructions as follows,
  //        (XORi (ANDi (SHR (CMP RC:$lhs, RC:$rhs)m (LUi 0x8000), 31), 1), 1)>;
  def : Pat<(setult RC:$lhs, RC:$rhs),
            (ANDi (CMPu RC:$lhs, RC:$rhs), 1)>;
}

// a <= b
multiclass SetlePatsCmp<RegisterClass RC> {
  // a <= b is equal to (XORi (b < a), 1)
  def : Pat<(setle RC:$lhs, RC:$rhs),
            (XORi (ANDi (CMP RC:$rhs, RC:$lhs), 1), 1)>;
  def : Pat<(setule RC:$lhs, RC:$rhs),
            (XORi (ANDi (CMP RC:$rhs, RC:$lhs), 1), 1)>;
}

// a > b
multiclass SetgtPatsCmp<RegisterClass RC> {
  // a > b is equal to b < a is equal to setlt(b, a)
  def : Pat<(setgt RC:$lhs, RC:$rhs),
            (ANDi (CMP RC:$rhs, RC:$lhs), 1)>;
  def : Pat<(setugt RC:$lhs, RC:$rhs),
            (ANDi (CMPu RC:$rhs, RC:$lhs), 1)>;
}

// a >= b
multiclass SetgePatsCmp<RegisterClass RC> {
  // a >= b is equal to b <= a
  def : Pat<(setge RC:$lhs, RC:$rhs),
            (XORi (ANDi (CMP RC:$lhs, RC:$rhs), 1), 1)>;
  def : Pat<(setuge RC:$lhs, RC:$rhs),
            (XORi (ANDi (CMPu RC:$lhs, RC:$rhs), 1), 1)>;
}

// setcc for slt instruction
multiclass SeteqPatsSlt<RegisterClass RC, Instruction SLTiuOp, Instruction XOROp,
                        Instruction SLTuOp, Register ZEROReg> {
  // a == b
  def : Pat<(seteq RC:$lhs, RC:$rhs),
            (SLTiuOp (XOROp RC:$lhs, RC:$rhs), 1)>;

  // a != b
  def : Pat<(setne RC:$lhs, RC:$rhs),
            (SLTuOp ZEROReg, (XOROp RC:$lhs, RC:$rhs))>;
}

// a <= b
multiclass SetlePatsSlt<RegisterClass RC, Instruction SLTOp, Instruction SLTuOp> {
  // a <= b is equal to (XORi (b < a), 1)
  def : Pat<(setle RC:$lhs, RC:$rhs),
            (XORi (SLTOp RC:$rhs, RC:$lhs), 1)>;
  def : Pat<(setule RC:$lhs, RC:$rhs),
            (XORi (SLTuOp RC:$rhs, RC:$lhs), 1)>;
}

// a > b
multiclass SetgtPatsSlt<RegisterClass RC, Instruction SLTOp, Instruction SLTuOp> {
  // a > b is equal to b < a is equal to setlt(b, a)
  def : Pat<(setgt RC:$lhs, RC:$rhs),
            (SLTOp RC:$rhs, RC:$lhs)>;
  def : Pat<(setugt RC:$lhs, RC:$rhs),
            (SLTuOp RC:$rhs, RC:$lhs)>;
}

// a >= b
multiclass SetgePatsSlt<RegisterClass RC, Instruction SLTOp, Instruction SLTuOp> {
  // a >= b is equal to b <= a
  def : Pat<(setge RC:$lhs, RC:$rhs),
            (XORi (SLTOp RC:$lhs, RC:$rhs), 1)>;
  def : Pat<(setuge RC:$lhs, RC:$rhs),
            (XORi (SLTuOp RC:$lhs, RC:$rhs), 1)>;
}

multiclass SetgeImmPatsSlt<RegisterClass RC, Instruction SLTiOp, Instruction SLTiuOp> {
  def : Pat<(setge RC:$lhs, immSExt16:$rhs),
            (XORi (SLTiOp RC:$lhs, immSExt16:$rhs), 1)>;
  def : Pat<(setuge RC:$lhs, immSExt16:$rhs),
            (XORi (SLTiuOp RC:$lhs, immSExt16:$rhs), 1)>;
}

let Predicates = [HasSlt] in {
  defm : SeteqPatsSlt<CPURegs, SLTiu, XOR, SLTu, ZERO>;
  defm : SetlePatsSlt<CPURegs, SLT, SLTu>;
  defm : SetgtPatsSlt<CPURegs, SLT, SLTu>;
  defm : SetgePatsSlt<CPURegs, SLT, SLTu>;
  defm : SetgeImmPatsSlt<CPURegs, SLTi, SLTiu>;
}

let Predicates = [HasCmp] in {
  defm : SeteqPatsCmp<CPURegs>;
  defm : SetltPatsCmp<CPURegs>;
  defm : SetlePatsCmp<CPURegs>;
  defm : SetgtPatsCmp<CPURegs>;
  defm : SetgePatsCmp<CPURegs>;
}

// hi/lo relocs
def : Pat<(Cpu0Hi tglobaladdr:$in), (LUi tglobaladdr:$in)>;
def : Pat<(Cpu0Lo tglobaladdr:$in), (ORi ZERO, tglobaladdr:$in)>;
def : Pat<(add CPURegs:$hi, (Cpu0Lo tglobaladdr:$lo)),
          (ORi CPURegs:$hi, tglobaladdr:$lo)>;

// gp_rel relocs
def : Pat<(add CPURegs:$gp, (Cpu0GPRel tglobaladdr:$in)),
          (ORi CPURegs:$gp, tglobaladdr:$in)>;

// wrapper_pic
class WrapperPat<SDNode node, Instruction ORiOp, RegisterClass RC>
  : Pat<(Cpu0Wrapper RC:$gp, node:$in),
        (ORiOp RC:$gp, node:$in)>;
def : WrapperPat<tglobaladdr, ORi, GPROut>;

//===----------------------------------------------------------------------===//
// Instruction aliases
//===----------------------------------------------------------------------===//

def : Cpu0InstAlias<"move $dst, $src", (ADDu GPROut:$dst, GPROut:$src, ZERO), 1>;
