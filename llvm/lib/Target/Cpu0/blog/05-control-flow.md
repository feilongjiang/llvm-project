# Control Flow, Branches, and the Passes That Clean Up After You

*Part 5 of "Building an LLVM Backend From Scratch" — how branches, comparisons, and conditional moves work in Cpu0, and why three cleanup passes are needed.*

---

## The Problem With Branches

Everything we've discussed so far --- instruction selection, calling conventions, the MC layer --- operates on straight-line code. But real programs branch. They have `if/else`, `for` loops, `switch` statements. And branches are where the gap between LLVM IR and machine code is widest.

LLVM IR has structured, typed branch instructions: `br i1 %cond, label %true, label %false`. Cpu0 has raw comparison + branch pairs, delay slots after every taken branch, offset limits on branch immediates, and two entirely different comparison strategies depending on the ISA variant. Bridging this gap requires not just instruction selection, but three separate cleanup passes that run after register allocation.

---

## Branch Lowering: From IR to Machine Branches

When LLVM encounters a conditional branch in IR, the SelectionDAG builder produces an `ISD::BRCOND` node. For Cpu0, this operation is marked `Custom`:

```cpp
// From Cpu0ISelLowering.cpp constructor
setOperationAction(ISD::BRCOND, MVT::Other, Custom);
```

The custom lowering is deliberately minimal --- it simply returns the operand unchanged:

```cpp
SDValue Cpu0TargetLowering::lowerBRCOND(SDValue Op, SelectionDAG &DAG) const {
  return Op;
}
```

The actual pattern matching happens in TableGen. The `Cpu0InstrInfo.td` file defines branch instructions that match against the lowered DAG nodes. The key complementary operations that are expanded are:

```cpp
setOperationAction(ISD::BR_CC, MVT::i32, Expand);       // Expand to BRCOND + SETCC
setOperationAction(ISD::SELECT_CC, MVT::i32, Expand);   // Expand to SELECT + SETCC
```

By expanding `BR_CC` and `SELECT_CC`, LLVM splits combined compare-and-branch into separate comparison and branch operations. This gives Cpu0's two ISA variants the chance to handle the comparison differently while keeping the branch the same.

---

## CMP vs SLT: Two Comparison Strategies

```
C source:  if (a < b) { ... }

Cpu032I  (CMP-based)              Cpu032II  (SLT-based)
────────────────────              ─────────────────────
cmp   $sw, $a0, $a1               slt   $t0, $a0, $a1
# Sets SW status register         # $t0 = (a < b) ? 1 : 0
# SW encodes <, =, > result       # Explicit 0/1 in a register

jlt   target                      bne   $t0, $zero, target
nop          # delay slot         nop          # delay slot

CMP sets implicit condition       SLT produces explicit result
flags; branch tests flags.        in a register; branch tests
HasCmp=true, HasSlt=false.        the register. HasSlt=true.
```

This is the most architecturally interesting design decision in Cpu0. The two ISA variants --- Cpu032I and Cpu032II --- use fundamentally different comparison mechanisms:

**Cpu032I** uses a **CMP-based** approach:
- The `CMP` instruction compares two registers and writes the result to the status word register (`$sw`)
- Branch instructions (`JEQ`, `JNE`, `JLT`, `JGT`, `JLE`, `JGE`) test `$sw` directly

**Cpu032II** uses an **SLT-based** approach:
- The `SLT` instruction (Set Less Than) writes 1 or 0 to a general-purpose register
- Branch instructions (`BEQ`, `BNE`) compare that register against `$zero`

These flags are set in `Cpu0Subtarget.h`:

```cpp
// From Cpu0Subtarget.h
bool HasCmp;   // Cpu032I: CMP-based comparisons
bool HasSlt;   // Cpu032II: SLT-based comparisons

bool enableLongBranchPass() const { return hasCpu032II(); }
```

Let's see the difference in practice. For the IR:

```llvm
define i32 @test_ifeq() nounwind {
entry:
  %a = alloca i32, align 4
  store i32 0, ptr %a, align 4
  %0 = load i32, ptr %a, align 4
  %cmp = icmp eq i32 %0, 0
  br i1 %cmp, label %if.then, label %if.end
if.then:
  %1 = load i32, ptr %a, align 4
  %inc = add i32 %1, 1
  store i32 %inc, ptr %a, align 4
  br label %if.end
if.end:
  %2 = load i32, ptr %a, align 4
  ret i32 %2
}
```

**Cpu032I** produces:

```asm
test_ifeq:
	# ...prologue...
	cmp   $sw, $r3, $r4
	jne   $sw, $BB0_2
	nop
	# if.then body
$BB0_2:
	# if.end
```

**Cpu032II** produces:

```asm
test_ifeq:
	# ...prologue...
	beq   $r3, $zero, $BB0_2
	nop
	# fallthrough to if.end (inverted)
$BB0_2:
	# if.then body
```

The Cpu032I path uses `CMP` to set flags, then `JNE` to branch if not equal (the condition is inverted because the if-taken block is the fall-through). The Cpu032II path is more direct: `BEQ $reg, $zero` branches when the value equals zero, without needing a separate comparison instruction.

For signed less-than (`icmp slt`), the difference is even more visible:

**Cpu032I**: `cmp $sw, $a, $b` + `jge $sw, $target` (inverted: skip if greater-or-equal)

**Cpu032II**: `slt $r, $a, $b` + `bne $r, $zero, $target` (branch if less-than flag is set)

The SLT approach has an advantage: the comparison result is in a general-purpose register, so it can be reused. If the same comparison feeds both a branch and a select, the SLT result is computed once. The CMP approach writes to a dedicated status register that's hard to spill or reuse.

---

## Conditional Moves: MOVZ and MOVN

```
C source:  result = (cond != 0) ? val1 : val2

With branch:                      With conditional move:
────────────                      ─────────────────────
beq   $cond, $zero, else_lbl      movz  $result, $val1, $cond
nop                               # move val1 if cond == 0
move  $result, $val1
jmp   end_lbl                     movn  $result, $val2, $cond
nop                               # move val2 if cond != 0
else_lbl:
move  $result, $val2              No branch → no pipeline stall
end_lbl:                          from branch misprediction.
                                  Cpu0CondMov.td TableGen patterns
Risk: branch misprediction        transform SELECT nodes → MOVZ/MOVN.
stall (pipeline flush).
```

The `select` IR instruction maps to conditional move instructions, avoiding branches entirely. Cpu0 defines two conditional moves in `Cpu0CondMov.td`:

```tablegen
// From Cpu0CondMov.td

class CondMovIntInt<RegisterClass CRC, RegisterClass DRC, bits<8> op,
                    string instr_asm>
  : FA<op, (outs DRC:$ra), (ins DRC:$rb, CRC:$rc, DRC:$F),
       !strconcat(instr_asm, "\t$ra, $rb, $rc"), [], IIAlu> {
  let shamt = 0;
  let Constraints = "$F = $ra";
}

def MOVZ_I_I : CondMovIntInt<CPURegs, CPURegs, 0x0a, "movz">;
def MOVN_I_I : CondMovIntInt<CPURegs, CPURegs, 0x0b, "movn">;
```

`MOVZ` (move if zero) copies `$rb` to `$ra` if `$rc` is zero. `MOVN` (move if not zero) copies if `$rc` is non-zero. The `$F = $ra` constraint tells the register allocator that the false-value input must be in the same register as the output --- if the condition is not met, the register keeps its old value.

The patterns that map `select` to these instructions are organized in multiclasses:

```tablegen
// select(seteq lhs, rhs) → MOVZ(T, XOR(lhs, rhs), F)
// If lhs == rhs, XOR gives 0, MOVZ fires (condition is zero)
multiclass MovzPats1<RegisterClass CRC, RegisterClass DRC,
                     Instruction MOVZInst, Instruction XOROp> {
  def : Pat<(select (i32 (seteq CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, (XOROp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select (i32 (seteq CRC:$lhs, 0)), DRC:$T, DRC:$F),
            (MOVZInst DRC:$T, CRC:$lhs, DRC:$F)>;
}

// select(setne lhs, rhs) → MOVN(T, XOR(lhs, rhs), F)
// If lhs != rhs, XOR gives non-zero, MOVN fires
multiclass MovnPats<RegisterClass CRC, RegisterClass DRC,
                    Instruction MOVNInst, Instruction XOROp> {
  def : Pat<(select (i32 (setne CRC:$lhs, CRC:$rhs)), DRC:$T, DRC:$F),
            (MOVNInst DRC:$T, (XOROp CRC:$lhs, CRC:$rhs), DRC:$F)>;
  def : Pat<(select CRC:$cond, DRC:$T, DRC:$F),
            (MOVNInst DRC:$T, CRC:$cond, DRC:$F)>;
}
```

The trick is XOR as an equality test: `XOR(a, b) == 0` if and only if `a == b`. So `select(eq a, b)` becomes `MOVZ(T, XOR(a, b), F)`.

For inequality comparisons on Cpu032II, additional patterns use SLT:

```tablegen
// Cpu032II-only: select(setge lhs, rhs) → MOVZ(T, SLT(lhs, rhs), F)
// If lhs >= rhs, SLT gives 0, MOVZ fires
let Predicates = [HasSlt] in {
  defm : MovzPats0Slt<CPURegs, CPURegs, MOVZ_I_I, SLT, SLTu, SLTi, SLTiu>;
}

// Available on both ISA variants (uses XOR, not SLT):
defm : MovzPats1<CPURegs, CPURegs, MOVZ_I_I, XOR>;
defm : MovnPats<CPURegs, CPURegs, MOVN_I_I, XOR>;
```

The `let Predicates = [HasSlt]` guard ensures the SLT-based patterns are only available on Cpu032II. The XOR-based patterns (`MovzPats1`, `MovnPats`) work on both variants.

For a `select` of the form:

```llvm
define i32 @select(i1 %cond, i32 %a, i32 %b) {
  %r = select i1 %cond, i32 %a, i32 %b
  ret i32 %r
}
```

Both ISA variants produce the same output:

```asm
movn  $r2, $r4, $r3
ret   $lr
nop
```

The generic `select(cond, T, F)` pattern matches `MovnPats`'s `(select CRC:$cond, DRC:$T, DRC:$F)` --- if `$cond` is non-zero, move `$T` to the result. This works on both Cpu032I and Cpu032II because it doesn't involve SLT.

---

## Jump Tables

For `switch` statements with many cases, LLVM generates jump tables. The `lowerJumpTable` method handles the address computation:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::lowerJumpTable(SDValue Op,
                                           SelectionDAG &DAG) const {
  JumpTableSDNode *N = cast<JumpTableSDNode>(Op);
  EVT Ty = Op.getValueType();

  if (!isPositionIndependent()) {
    return getAddrNonPIC(N, Ty, DAG);  // lui/ori absolute address
  }
  return getAddrLocal(N, Ty, DAG);     // GOT-relative address
}
```

In static mode, the jump table address is loaded with a `lui`/`ori` pair. In PIC mode, it's accessed through the GOT. The actual jump is expanded from `ISD::BR_JT` (which is marked `Expand`) into an indexed load + indirect jump.

### When LLVM Chooses Jump Tables

LLVM's switch lowering algorithm decides between three strategies based on the case density and count:

1. **Linear search / chain of branches**: For switches with ≤ 3 cases, or very sparse cases. Emits a sequence of `CMP`/`SLT` + branch pairs.
2. **Binary search tree**: For moderately sparse switches. Recursively bisects the case range.
3. **Jump table**: For dense switches (>= 4 cases, density ≥ 40%). Generates a single indexed load into an array of target addresses.

You can control the threshold with `-jump-table-cluster-factor` or by overriding `getMinimumJumpTableEntries()` in your target lowering. Cpu0 inherits the default threshold from `TargetLowering`. The generated jump table assembly looks like:

```asm
# switch (x) with cases 0..5
sltiu  $at, $r4, 6        # Check range (x < 6)
beq    $at, $zero, $default
nop
shl    $r4, $r4, 2        # x * 4 (pointer size)
ld     $at, %got($JTI0_0)($gp)  # Load jump table base
addu   $r4, $at, $r4     # Base + offset
ld     $r4, 0($r4)        # Load target address
jr     $r4                # Jump
nop

.section .rodata
$JTI0_0:
.word  $BB_case0
.word  $BB_case1
.word  $BB_case2
# ...
```

The jump table itself lives in `.rodata`, and contains absolute addresses of the basic blocks. In PIC mode, it would contain relative offsets instead, requiring an extra addition step.

---

## Three Cleanup Passes

```
Before (Problem):                 After (Cpu0BranchExpansion pass):
─────────────────                 ─────────────────────────────────
beq  $a0, $a1, far_target         bne  $a0, $a1, skip_label
# 16-bit offset field             # condition INVERTED
# range: only ±32 KB              nop             # delay slot
# ERROR if target > 32 KB         jmp  far_target # 24-bit range: ±16 MB
                                  nop             # delay slot
                                  skip_label:
                                  # continue here

16-bit branch offset = ±32 KB range
24-bit jmp offset    = ±8 MB range
```

After instruction selection and register allocation, three pre-emit passes clean up the control flow. They run in sequence, and the order matters.

### Pass 1: DelUselessJMP

The simplest pass. It removes unconditional jumps that target the immediately following basic block --- fallthrough jumps:

```cpp
// From Cpu0DelUselessJMP.cpp
bool DelJmp::runOnMachineBasicBlock(MachineBasicBlock &MBB,
                                    MachineBasicBlock &MBBN) {
  MachineBasicBlock::iterator I = MBB.end();
  if (I != MBB.begin()) I--;
  else return false;

  if (I->getOpcode() == Cpu0::JMP && I->getOperand(0).getMBB() == &MBBN) {
    // "jmp $BB0_3" where $BB0_3 is the next block — delete it
    MBB.erase(I);
    return true;
  }
  return false;
}
```

LLVM's code generator tends to produce explicit jumps between every basic block, even when the target is the natural fallthrough. This pass catches and removes them. It's a pure size optimization --- the jumps would work correctly, they're just wasteful.

### Pass 2: DelaySlotFiller

**What is a delay slot?** On early RISC processors (MIPS, SPARC, early ARM), the CPU pipeline would fetch the next instruction while the branch was being processed. By the time the branch's destination was computed (one cycle later), the following instruction was already in the decode stage. Rather than stall the pipeline (which would cost one cycle every branch), the architects defined the *branch delay slot*: the instruction after every branch always executes unconditionally. The compiler is responsible for putting something useful there — or a NOP if nothing is available.

Cpu0, being modeled after MIPS, inherits this design: the instruction immediately after any branch (`jmp`, `jalr`, `ret`, `beq`, `bne`) always executes before the branch takes effect. The `Cpu0DelaySlotFiller` pass is responsible for filling these slots:

```cpp
// From Cpu0DelaySlotFiller.cpp
bool Filler::runOnMachineBasicBlock(MachineBasicBlock &MBB) {
  bool Changed = false;
  for (Iter I = MBB.begin(); I != MBB.end(); ++I) {
    if (!hasUnoccupiedSlot(&*I))
      continue;

    ++FilledSlots;
    Changed = true;

    // Bundle the NOP to the instruction with the delay slot.
    BuildMI(MBB, std::next(I), I->getDebugLoc(), TII->get(Cpu0::NOP));
    MIBundleBuilder(MBB, I, std::next(I, 2));
  }
  return Changed;
}
```

The current implementation always fills with `NOP`. A production backend would try to move a useful instruction from before the branch into the delay slot. The `MIBundleBuilder` call **bundles** the NOP with the branch, so subsequent passes and the assembly printer treat them as a unit. This is why you see `nop` after every branch in Cpu0 output.

The `hasUnoccupiedSlot` check ensures we only fill delay slots that haven't already been filled (e.g., by the long branch expansion):

```cpp
static bool hasUnoccupiedSlot(const MachineInstr *MI) {
  return MI->hasDelaySlot() && !MI->isBundledWithSucc();
}
```

### Pass 3: BranchExpansion

The most complex cleanup pass. Branch instructions have limited offset ranges: 16-bit for conditional branches (`BEQ`/`BNE`), 24-bit for unconditional jumps (`JMP`). When a branch target is too far away, the instruction needs **expansion** into a longer sequence.

The pass runs iteratively, because expanding one branch increases code size, which might push other branches beyond their offset limits:

```cpp
// From Cpu0BranchExpansion.cpp
bool Cpu0BranchExpansion::runOnMachineFunction(MachineFunction &F) {
  if (!STI.enableLongBranchPass()) return false;

  LongBranchSeqSize = !IsPIC ? 2 : 10;
  initMBBInfo();

  bool EverMadeChange = false, MadeChange = true;
  while (MadeChange) {
    MadeChange = false;
    for (auto &I : MBBInfos) {
      if (!I.Br || I.HasLongBranch) continue;

      int64_t Offset = computeOffset(I.Br) / 4;
      if (!ForceLongBranch && isInt<16>(Offset)) continue;

      I.HasLongBranch = true;
      I.Size += LongBranchSeqSize * 4;
      ++LongBranches;
      EverMadeChange = MadeChange = true;
    }
  }
  // ... expand all marked branches
}
```

The algorithm:
1. Compute the size and address of every basic block
2. For each branch, compute the offset to its target
3. If the offset doesn't fit in 16 bits (the immediate field size), mark it for expansion
4. Repeat until no more branches need expansion (fixed-point iteration)

In **static** mode, expansion is simple --- replace the branch with an unconditional jump:

```
$longbr:
  jmp $tgt
  nop
$fallthrough:
```

In **PIC** mode, expansion is much more complex because we can't use absolute addresses. The expanded sequence computes the target address relative to the current PC using `BAL` (Branch And Link):

```
$longbr:
  addiu $sp, $sp, -8       # Save space for $lr
  st    $lr, 0($sp)        # Save $lr (BAL will overwrite it)
  lui   $at, %hi($tgt - $baltgt)   # Upper 16 bits of offset
  addiu $at, $at, %lo($tgt - $baltgt)  # Lower 16 bits
  bal   $baltgt            # Jump to $baltgt, set $lr = PC+8
  nop
$baltgt:
  addu  $at, $lr, $at      # $at = PC + offset = target address
  ld    $lr, 0($sp)        # Restore $lr
  addiu $sp, $sp, 8        # Restore stack
  jr    $at                # Jump to target
  nop
```

This 10-instruction sequence (hence `LongBranchSeqSize = 10` for PIC) uses the `BAL` instruction to capture the current PC in `$lr`, then adds the pre-computed offset to reach the target. The offset is expressed as `%hi($tgt - $baltgt)` and `%lo($tgt - $baltgt)` --- relative to the `BAL` target, not the branch itself.

Note that this expansion is only enabled on Cpu032II:

```cpp
bool enableLongBranchPass() const { return hasCpu032II(); }
```

This is because Cpu032I uses condition-flag branches (JEQ/JNE/etc.) with 24-bit offsets, which are large enough that long branches are rarely needed. Cpu032II's `BEQ`/`BNE` have 16-bit offsets, making long branches more likely.

---

## Loop Lowering: Induction Variables and Back Edges

A simple counted loop in C is a good test of how the backend handles back-edges (branches from the bottom of the loop body back to the top):

```llvm
define i32 @sum(i32 %n) {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
  %s = phi i32 [ 0, %entry ], [ %s.next, %loop ]
  %i.next = add i32 %i, 1
  %s.next = add i32 %s, %i
  %cmp = icmp slt i32 %i.next, %n
  br i1 %cmp, label %loop, label %exit
exit:
  ret i32 %s.next
}
```

On **Cpu032II** this produces:

```asm
sum:
  addiu $sp, $sp, -8
  # Entry: initialize loop vars
  addu  $r3, $zero, $zero   # i = 0
  addu  $r2, $zero, $zero   # s = 0

$BB0_1:                      # loop:
  addu  $r5, $r3, $zero     # save i for s += i
  addiu $r3, $r3, 1         # i = i + 1 (increment first)
  addu  $r2, $r2, $r5       # s = s + i_old
  slt   $r5, $r3, $r4       # r5 = (i < n) ? 1 : 0
  bne   $r5, $zero, $BB0_1  # loop if i < n
  nop                        # delay slot

$BB0_2:                      # exit:
  addiu $sp, $sp, 8
  ret   $lr
  nop
```

Several things are noteworthy:

1. **PHI nodes become register copies**: The `phi [ 0, %entry ], [ %i.next, %loop ]` is resolved by the register allocator: the initial value comes from the entry block, and the loop-back assignment overwrites the same physical register at the loop tail.

2. **The back edge is a `BNE` + NOP pair**: The `bne $r5, $zero, $BB0_1` branches back to the loop header if `i < n`. The delay slot is a NOP.

3. **No jump table needed**: A simple counted loop compiles to a single compare-and-branch, with no need for MOVZ/MOVN or jump tables.

For **Cpu032I**, the loop produces `cmp $sw, $r3, $r4` + `jgt $sw, $BB0_1` instead of the SLT + BNE pair. The function body is otherwise identical — two instructions for the comparison, one for the branch, one NOP.

This example also shows why the `DelUselessJMP` pass matters. The initial code generation often produces an explicit `JMP $BB0_1` at the end of the loop body (the unconditional back edge), plus a `JMP $BB0_2` at the end of the entry block. After `DelUselessJMP`, these become natural fallthroughs.

---

## How the Passes Interact

The three passes run in a carefully chosen order:

```cpp
void Cpu0PassConfig::addPreEmitPass() {
  addPass(createCpu0DelJmpPass(TM));          // 1. Remove useless jumps
  addPass(createCpu0DelaySlotFillerPass(TM)); // 2. Fill delay slots
  addPass(createCpu0BranchExpansionPass(TM)); // 3. Expand long branches
}
```

**Why this order?**

1. **DelJmp first**: Removing useless jumps reduces code size, which means branch offsets are smaller, reducing the chance of needing long branch expansion.
2. **DelaySlotFiller second**: Delay slots must be filled before branch expansion, because the expansion pass generates `MIBundleBuilder` sequences that include their own NOPs. If we filled delay slots after expansion, we'd double-NOP the expanded sequences.
3. **BranchExpansion last**: This pass must run after all other code-size changes, so its offset computations are accurate.

---

## Seeing It All Together

Consider this function through Cpu032I and Cpu032II:

```llvm
define i32 @test_iflt(i32 %a, i32 %b) {
entry:
  %cmp = icmp slt i32 %a, %b
  br i1 %cmp, label %if.then, label %if.end
if.then:
  %r = add i32 %a, 1
  br label %if.end
if.end:
  %result = phi i32 [ %r, %if.then ], [ %a, %entry ]
  ret i32 %result
}
```

**Cpu032I** (CMP-based):
```asm
test_iflt:
	cmp   $sw, $r4, $r5      # Compare a, b → status word
	jge   $sw, $BB0_2        # Skip if.then if a >= b (inverted)
	nop
	# if.then:
	addiu $r4, $r4, 1
$BB0_2:
	addu  $r2, $r4, $zero    # result → V0
	ret   $lr
	nop
```

**Cpu032II** (SLT-based):
```asm
test_iflt:
	slt   $r3, $r4, $r5      # r3 = (a < b) ? 1 : 0
	bne   $r3, $zero, $BB0_2 # Branch to if.then if a < b
	nop
	# fallthrough to if.end
	...
$BB0_2:
	# if.then:
	addiu $r4, $r4, 1
	...
```

The CMP approach is one instruction fewer (no need for an intermediate register), but the SLT approach is more flexible (the result register can be reused for conditional moves).

A key architectural observation: the CMP approach creates an implicit dependency through `$sw`. Any instruction that reads `$sw` must wait for the `CMP` to finish. This limits instruction-level parallelism — the branch must come immediately after the compare. The SLT approach writes to a general-purpose register, which has no implicit dependency on subsequent branches. A scheduler could potentially reorder other instructions between `SLT` and `BNE` if their operands don't conflict.

LLVM's `TableGen` patterns handle the ISA variant selection transparently. Both `JEQ`/`JNE`/etc. (Cpu032I) and `BEQ`/`BNE` (Cpu032II) are defined as `isCompare = 1` instructions, and the backend uses the `HasCmp`/`HasSlt` feature flags to guard which set is used during pattern matching.

With `-force-cpu0-long-branch` on Cpu032II in static mode:
```asm
test_iflt:
	slt   $r3, $r4, $r5
	bne   $r3, $zero, $BB0_3  # Branch OVER the long branch
	nop
	jmp   $BB0_2              # Long branch to if.end
	nop
$BB0_3:
	# if.then body
```

The conditional branch is inverted (BNE becomes "skip the long branch"), and the unconditional `JMP` reaches the distant target. This is the simplest form of long branch expansion.

---

## Summary

Control flow in Cpu0 involves three levels of machinery:

| Level | Mechanism | Files |
|-------|-----------|-------|
| **ISel** | Pattern matching for branches, conditional moves | `Cpu0InstrInfo.td`, `Cpu0CondMov.td`, `Cpu0ISelLowering.cpp` |
| **Subtarget** | CMP vs SLT selection via `HasCmp`/`HasSlt` flags | `Cpu0Subtarget.h`, `Cpu0.td` |
| **Pre-emit passes** | DelJmp, DelaySlotFiller, BranchExpansion | Three separate `.cpp` files, registered in `Cpu0TargetMachine.cpp` |

The key takeaway: instruction selection handles the *semantics* of control flow (what does "less than" mean?), but three separate passes handle the *mechanics* (is this jump necessary? is the delay slot filled? does the offset fit?). This separation is a deliberate design choice --- each pass has one job, and they compose cleanly. A more monolithic approach would be harder to test and harder to get right.

The CMP vs SLT design is also worth reflecting on. Real ISAs make the same choice: x86 uses flags (like CMP), while RISC-V uses SLT-style comparisons. Both approaches work. The flag-based approach uses fewer registers but creates implicit dependencies on the flag register. The SLT approach uses more registers but is more orthogonal. Cpu0 implements both, letting you compare them side-by-side --- which is exactly the kind of insight that makes an educational architecture valuable.

---

## Further Reading

- [LLVM Code Generator: Pre-Emit Passes](https://llvm.org/docs/CodeGenerator.html#late-machine-code-optimizations) --- Where cleanup passes fit in the pipeline
- [Branch Folding](https://llvm.org/docs/CodeGenerator.html#late-machine-code-optimizations) --- LLVM's generic branch optimization pass
- [TableGen: Instruction Selection Patterns](https://llvm.org/docs/TableGen/ProgRef.html) --- Pattern matching syntax reference
- [RISC-V Branch Comparison](https://github.com/riscv/riscv-isa-manual/releases/download/riscv-user-2.2/riscv-spec-v2.2.pdf) --- RISC-V's SLT-style approach for comparison

---

*Previous: [Post 4 — The MC Layer: From Abstract Instructions to Real Bytes](04-mc-layer.md)*

*Next up: [Post 6 — Round-Tripping: Building an Assembler and Disassembler](06-assembler-disassembler.md)*
