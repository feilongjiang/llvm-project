//===-- Cpu0SEISelDAGToDAG.h - A Dag to Dag Inst Selector for Cpu0SE -----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Subclass of Cpu0DAGToDAGISel specialized for Cpu032.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_CPU0_CPU0SEISELDAGTODAG_H
#define LLVM_LIB_TARGET_CPU0_CPU0SEISELDAGTODAG_H

#include "Cpu0ISelDAGToDAG.h"

namespace llvm {

class Cpu0SEDAGToDAGISel : public Cpu0DAGToDAGISel {

public:
  explicit Cpu0SEDAGToDAGISel(Cpu0TargetMachine &TM, CodeGenOpt::Level OL)
      : Cpu0DAGToDAGISel(TM, OL) {}

private:
  bool runOnMachineFunction(MachineFunction &MF) override;

  bool trySelect(SDNode *Node) override;

  void processFunctionAfterISel(MachineFunction &MF) override;

  void selectAddESubE(unsigned MOp, SDValue InFlag, SDValue CmpLHS,
                      const SDLoc &DL, SDNode *Node) const;

  std::pair<SDNode *, SDNode *> selectMULT(SDNode *N, unsigned Opc,
                                           const SDLoc &DL, EVT Ty, bool HasLo,
                                           bool HasHi);
};

FunctionPass *createCpu0SEISelDag(Cpu0TargetMachine &TM,
                                  CodeGenOpt::Level OptLevel);
} // namespace llvm

#endif
