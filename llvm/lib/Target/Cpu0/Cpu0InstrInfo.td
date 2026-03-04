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

// Return
def Cpu0Ret : SDNode<"Cpu0ISD::Ret", SDTNone,
                     [SDNPHasChain, SDNPOptInGlue, SDNPVariadic]>;

//===----------------------------------------------------------------------===//
// Cpu0 Instruction Predicate Definitions
//===----------------------------------------------------------------------===//
def EnableOverflow  : Predicate<"Subtarget->enableOverflow()">;
def DisableOverFlow : Predicate<"Subtarget->disableOverflow()">;

def HasCmp          : Predicate<"Subtarget->hasCmp()">;
def HasSlt          : Predicate<"Subtarget->hasSlt()">;

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

// 32-bit shift instructions.
class shift_rotate_imm32<bits<8> op, bits<4> isRotate, string instrAsm, SDNode opNode>
  : shift_rotate_imm<op, isRotate, instrAsm, opNode, immZExt5, shamt, CPURegs>;

class LoadUpper<bits<8> op, string Asm, RegisterClass RC, Operand Imm>
  : FL<op, (outs RC:$ra), (ins Imm:$imm16),
       !strconcat(Asm, "\t$ra, $imm16"), [], IIAlu> {
  let rb = 0;
  let isReMaterializable = 1;
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
def ORi   : ArithLogicI<0x0d, "ori", or, uimm16, immZExt16, CPURegs>;

def LUi   : LoadUpper<0x0f, "lui", GPROut, uimm16>;

// Arithmetic Instrucitons (3-Operand, R-Type)
let Predicates = [DisableOverFlow] in {
  def ADDu  : ArithLogicR<0x11, "addu", add, IIAlu, CPURegs, 1>;
}

// Shift Instrucitons
def SHL     : shift_rotate_imm32<0x1e, 0x00, "shl", shl>;

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

//===----------------------------------------------------------------------===//
// Instruction aliases
//===----------------------------------------------------------------------===//

def : Cpu0InstAlias<"move $dst, $src", (ADDu GPROut:$dst, GPROut:$src, ZERO), 1>;
