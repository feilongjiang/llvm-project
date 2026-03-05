//===-- Cpu0RegisterInfo.td - Cpu0 Register defs -----------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
//  Declarations that describe the Cpu0 register file
//===----------------------------------------------------------------------===//

// We have banks of 16 register each.

class Cpu0Reg<bits<16> Enc, string n> : Register<n> {
  // For tablegen(... -gen-emitter) in CMakeLists.txt
  let HWEncoding = Enc;
  let Namespace = "Cpu0";
}

// Cpu0 CPU Registers
class Cpu0GPRReg<bits<16> Enc, string n> : Cpu0Reg<Enc, n>;

// Co-processor 0 Registers
class Cpu0C0Reg<bits<16> Enc, string n> : Cpu0Reg<Enc, n>;

//===----------------------------------------------------------------------===//
//@Registers
//===----------------------------------------------------------------------===//
// The register string, such as "9" or "gp" will show on "llvm-objdump -d"
//@ All registers definition
let Namespace = "Cpu0" in {
  //@ General Purpose Registers
  def ZERO  : Cpu0GPRReg<0,   "zero">,  DwarfRegNum<[0]>;
  def AT    : Cpu0GPRReg<1,   "r1">,    DwarfRegNum<[1]>;
  def V0    : Cpu0GPRReg<2,   "r2">,    DwarfRegNum<[2]>;
  def V1    : Cpu0GPRReg<3,   "r3">,    DwarfRegNum<[3]>;
  def A0    : Cpu0GPRReg<4,   "r4">,    DwarfRegNum<[4]>;
  def A1    : Cpu0GPRReg<5,   "r5">,    DwarfRegNum<[5]>;
  def T9    : Cpu0GPRReg<6,   "t9">,    DwarfRegNum<[6]>;
  def T0    : Cpu0GPRReg<7,   "r7">,    DwarfRegNum<[7]>;
  def T1    : Cpu0GPRReg<8,   "r8">,    DwarfRegNum<[8]>;
  def S0    : Cpu0GPRReg<9,   "r9">,    DwarfRegNum<[9]>;
  def S1    : Cpu0GPRReg<10,  "r10">,   DwarfRegNum<[10]>;
  def GP    : Cpu0GPRReg<11,  "gp">,    DwarfRegNum<[11]>;
  def FP    : Cpu0GPRReg<12,  "fp">,    DwarfRegNum<[12]>;
  def SP    : Cpu0GPRReg<13,  "sp">,    DwarfRegNum<[13]>;
  def LR    : Cpu0GPRReg<14,  "lr">,    DwarfRegNum<[14]>;
  def SW    : Cpu0GPRReg<15,  "sw">,    DwarfRegNum<[15]>;

  // Hi/Lo register number and name
  def HI    : Cpu0Reg<0,     "ac0">,    DwarfRegNum<[18]>;
  def LO    : Cpu0Reg<0,     "ac0">,    DwarfRegNum<[19]>;

  def PC    : Cpu0C0Reg<0,    "pc">,    DwarfRegNum<[20]>;
  def EPC   : Cpu0C0Reg<1,    "epc">,   DwarfRegNum<[21]>;
}


//===----------------------------------------------------------------------===//
// @Register Classes
//===----------------------------------------------------------------------===//

def CPURegs : RegisterClass<"Cpu0", [i32], 32, (add
  // Reserved
  ZERO, AT,
  // Return Values and Arguments
  V0, V1, A0, A1,
  // Not preserved across procedure calls
  T9, T0, T1,
  // Callee save
  S0, S1,
  // Reserved
  GP, FP,
  SP, LR, SW)>;

// @Status Registers class
def SR : RegisterClass<"Cpu0", [i32], 32, (add SW)>;

// Hi/Lo Registers class
def HILO   : RegisterClass<"Cpu0", [i32], 32, (add HI, LO)>;

// @Co-processor 0 Registers class
def C0Regs : RegisterClass<"Cpu0", [i32], 32, (add PC, EPC)>;

def GPROut : RegisterClass<"Cpu0", [i32], 32, (add (sub CPURegs, SW))>;
