//===-- Cpu0Schedule.td - Cpu0 Scheduling Definitions ------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Functional units across Cpu0 chips sets. Based on GCC/Cpu0 backend files.
//===----------------------------------------------------------------------===//
def ALU     : FuncUnit;
def IMULDIV : FuncUnit;

//===----------------------------------------------------------------------===//
// Instruction Itinerary classes used for Cpu0
//===----------------------------------------------------------------------===//
def IIAlu           : InstrItinClass;
def IICLO           : InstrItinClass;
def IICLZ           : InstrItinClass;
def IILoad          : InstrItinClass;
def IIStore         : InstrItinClass;
def IIBranch        : InstrItinClass;

def IIPseudo        : InstrItinClass;

def IIHiLo          : InstrItinClass;
def IIImul          : InstrItinClass;
def IIIdiv          : InstrItinClass;



//===----------------------------------------------------------------------===//
// Cpu0 Generic instruction itineraries
//===----------------------------------------------------------------------===//
def Cpu0GenericItineraries : ProcessorItineraries<[ALU, IMULDIV], [], [
  InstrItinData<IIAlu             , [InstrStage<1,  [ALU]>]>,
  InstrItinData<IICLO             , [InstrStage<1,  [ALU]>]>,
  InstrItinData<IICLZ             , [InstrStage<1,  [ALU]>]>,
  InstrItinData<IILoad            , [InstrStage<3,  [ALU]>]>,
  InstrItinData<IIStore           , [InstrStage<1,  [ALU]>]>,
  InstrItinData<IIBranch          , [InstrStage<1,  [ALU]>]>,
  InstrItinData<IIHiLo            , [InstrStage<1,  [IMULDIV]>]>,
  InstrItinData<IIImul            , [InstrStage<17, [IMULDIV]>]>,
  InstrItinData<IIIdiv            , [InstrStage<38, [IMULDIV]>]>,
]>;