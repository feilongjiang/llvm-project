//===-- Cpu0TargetStreamer.cpp - Cpu0 Target Streamer Methods -------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file provides Cpu0 specific target streamer methods.
//
//===----------------------------------------------------------------------===//

#include "Cpu0TargetStreamer.h"
#include "Cpu0MCTargetDesc.h"
#include "Cpu0TargetObjectFile.h"
#include "InstPrinter/Cpu0InstPrinter.h"
#include "llvm/BinaryFormat/ELF.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCSectionELF.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/MCSymbolELF.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FormattedStream.h"

using namespace llvm;

Cpu0TargetStreamer::Cpu0TargetStreamer(MCStreamer &S) : MCTargetStreamer(S) {}

Cpu0TargetAsmStreamer::Cpu0TargetAsmStreamer(MCStreamer &S,
                                             formatted_raw_ostream &OS)
    : Cpu0TargetStreamer(S), OS(OS) {}
