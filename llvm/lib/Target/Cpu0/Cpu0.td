//===-- Cpu0.td - Describe the Cpu0 Target Machine ---------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
// This is the top level entry point for the Cpu0 target.
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Target-independent interfaces
//===----------------------------------------------------------------------===//

include "llvm/Target/Target.td"

// Register Information
include "Cpu0RegisterInfo.td"

// Calling Convention
include "Cpu0Schedule.td"

// Instruction Description
include "Cpu0InstrInfo.td"

// Calling Convention
include "Cpu0CallingConv.td"

// Without this will have error: 'cpu032I' is not a recognized processor for
//  this target (ignoring processor)
//===----------------------------------------------------------------------===//
// Cpu0 Subtarget features                                                    //
//===----------------------------------------------------------------------===//


def FeatureCmp          : SubtargetFeature<"cmp", "HasCmp", "true",
                                           "Enable 'cmp' instructions.">;
def FeatureSlt          : SubtargetFeature<"slt", "HasSlt", "true",
                                           "Enable 'slt' instructions.">;
def FeatureCpu032I      : SubtargetFeature<"cpu032I", "Cpu0ArchVersion", "Cpu032I",
                                           "Cpu032I ISA Support",
                                           [FeatureCmp]>;
def FeatureCpu032II     : SubtargetFeature<"cpu032II", "Cpu0ArchVersion", "Cpu032II",
                                           "Cpu032II ISA Support (slt)",
                                           [FeatureCmp, FeatureSlt]>;

//===----------------------------------------------------------------------===//
// Cpu0 processors supported.
//===----------------------------------------------------------------------===//

class Proc<string Name, list<SubtargetFeature> Features>
 : Processor<Name, Cpu0GenericItineraries, Features>;

def : Proc<"cpu032I", [FeatureCpu032I]>;
def : Proc<"cpu032II", [FeatureCpu032II]>;
// Above make Cpu0GenSubtargetInfo.inc set feature bit as the following order:
// enum {
//   FeatureCmp = 0,
//   FeatureCpu032I = 1,
//   FeatureCpu032II = 2,
//   FeatureSlt = 3,
//   NumSubtargetFeatures = 4
// };

def Cpu0InstrInfo : InstrInfo;

def Cpu0AsmWriter : AsmWriter {
    int PassSubtarget = 1;
}

// Whill generate Cpu0GenAsmWrite.inc included by Cpu0InstPrinter.cpp, contents
// as follows,
// void Cpu0InstPrinter::printInstruction(const MCInst *MI, raw_ostream &O) {...}
// const char* Cpu0InstPrinter::getRegisterName(unsigned RegNo) {...}
def Cpu0 : Target {
    // def Cpu0InstrInfo : InstrInfo as before.
    let InstructionSet = Cpu0InstrInfo;
    let AssemblyWriters = [Cpu0AsmWriter];
}
