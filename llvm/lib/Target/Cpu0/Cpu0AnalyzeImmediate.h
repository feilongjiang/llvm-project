//===- Cpu0AnalyzeImmediate.h - Analyze Immediates -------------*- C++ -*--===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0ANALYZEIMMEDIATE_H
#define LLVM_LIB_TARGET_CPU0_CPU0ANALYZEIMMEDIATE_H

#include "llvm/ADT/SmallVector.h"
#include <cstdint>

namespace llvm {

class Cpu0AnalyzeImmediate {
public:
  struct Inst {
    unsigned Opc, ImmOpnd;

    Inst(unsigned Opc, unsigned ImmOpnd);
  };
  using InstSeq = SmallVector<Inst, 7>;

  /// Analyze - Get an instruction sequence to load immediate Imm. The last
  /// instruction in the sequence must be an ADDiu if LastInstrIsADDiu is
  /// true;
  const InstSeq &Analyze(uint64_t Imm, unsigned Size, bool LastInstrIsADDiu);

private:
  using InstSeqLs = SmallVector<InstSeq, 5>;

  /// AddInstr - Add I to all instruction sequences in SeqLs.
  void AddInstr(InstSeqLs &SeqLs, const Inst &I);

  /// GetInstSeqLsADDiu - Get instruction sequences which end with an ADDiu to
  /// load immediate Imm
  void GetInstSeqLsADDiu(uint64_t Imm, unsigned RemSize, InstSeqLs &SeqLs);

  /// GetInstSeqLsORi - Get instrutcion sequences which end with an ORi to
  /// load immediate Imm
  void GetInstSeqLsORi(uint64_t Imm, unsigned RemSize, InstSeqLs &SeqLs);

  /// GetInstSeqLsSHL - Get instruction sequences which end with a SHL to
  /// load immediate Imm
  void GetInstSeqLsSHL(uint64_t Imm, unsigned RemSize, InstSeqLs &SeqLs);

  /// GetInstSeqLs - Get instruction sequences to load immediate Imm.
  void GetInstSeqLs(uint64_t Imm, unsigned RemSize, InstSeqLs &SeqLs);

  /// ReplaceADDiuSHLWithLUi - Replace an ADDiu & SHL pair with a LUi.
  void ReplaceADDiuSHLWithLUi(InstSeq &Seq);

  /// GetShortestSeq - Find the shortest instruction sequence in SeqLs and
  /// return it in Insts.
  void GetShortestSeq(InstSeqLs &SeqLs, InstSeq &Insts);

  unsigned Size;
  unsigned ADDiu, ORi, SHL, LUi;
  InstSeq Insts;
};

} // end namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0ANALYZEIMMEDIATE_H
