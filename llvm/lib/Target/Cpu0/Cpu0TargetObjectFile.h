//===-- llvm/Target/Cpu0TargetObjectFile.h - Cpu0 Object Info ---*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0TARGETOBJECTFILE_H
#define LLVM_LIB_TARGET_CPU0_CPU0TARGETOBJECTFILE_H

#include "llvm/CodeGen/TargetLoweringObjectFileImpl.h"

namespace llvm {
class Cpu0TargetMachine;
class Cpu0TargetObjectFile : public TargetLoweringObjectFileELF {
  MCSection *SmallDataSection;
  MCSection *SmallBSSSection;
  const Cpu0TargetMachine *TM;

  bool IsGlobalInSmallSection(const GlobalObject *GO, const TargetMachine &TM,
                              SectionKind Kind) const;
  bool IsGlobalInSmallSectionImpl(const GlobalObject *GO,
                                  const TargetMachine &TM) const;

public:
  void Initialize(MCContext &Ctx, const TargetMachine &TM) override;

  /// Return true if this global address should be
  /// placed into small deta/bss section.
  bool IsGlobalInSmallSection(const GlobalObject *GO,
                              const TargetMachine &TM) const;

  MCSection *SelectSectionForGlobal(const GlobalObject *GO, SectionKind Kind,
                                    const TargetMachine &TM) const override;
};
} // end namespace llvm

#endif // LLVM_LIB_TARGET_CPU0_CPU0TARGETOBJECTFILE_H
