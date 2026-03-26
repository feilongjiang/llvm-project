# Stack Frames, Calling Conventions, and the ABI

*Part 3 of "Building an LLVM Backend From Scratch" — dissecting how Cpu0 manages function calls, stack frames, and the O32 ABI.*

---

## Why Calling Conventions Matter

Posts [1](01-anatomy.md) and [2](02-selectiondag.md) showed how LLVM turns IR into machine instructions for a single basic block. But real programs are made of *functions* --- and functions call each other. The moment a function calls another, a cascade of questions appears: Where do arguments go? Who saves which registers? How does the stack grow? Where is the return address?

The answers to these questions are collectively called the **calling convention** and **ABI** (Application Binary Interface). Getting them right is non-negotiable: if a caller and callee disagree on any of these rules, the program corrupts its own stack and crashes in ways that are brutally difficult to debug.

In this post, we'll trace a function call end-to-end through the Cpu0 backend, from the moment arguments leave the caller to the moment they arrive in the callee. Along the way, we'll examine every file that participates: the TableGen calling convention definition, the frame lowering code that emits prologues and epilogues, the call lowering that routes arguments to registers or the stack, and the pass pipeline that orchestrates everything.

---

## A Concrete Example: Three Arguments In, One Result Out

Let's start with a simple function that takes three `i32` arguments and returns their sum:

```llvm
define i32 @foo(i32 %a, i32 %b, i32 %c) {
  %sum = add i32 %a, %b
  %sum2 = add i32 %sum, %c
  ret i32 %sum2
}
```

Running `llc -march=cpu0 -relocation-model=pic` produces:

```asm
	.globl	foo
	.type	foo,@function
	.ent	foo
foo:
	.frame	$sp,0,$lr
	.mask 	0x00000000,0
	.set	noreorder
	.set	nomacro
	.cpload	$t9
	addu	$r2, $r4, $r5
	ld	$r3, 0($sp)
	addu	$r2, $r2, $r3
	ret	$lr
	nop
	.set	macro
	.set	reorder
	.end	foo
```

Several things are visible here:

1. **Arguments in registers**: `%a` is in `$r4` (A0), `%b` is in `$r5` (A1). These are the first two argument registers defined by the O32 calling convention.
2. **Third argument on the stack**: `%c` is loaded from `0($sp)` --- Cpu0 only has two argument registers (A0, A1), so the third argument spills to the stack.
3. **Return value in `$r2`**: The result goes into V0 (`$r2`), as specified by `RetCC_Cpu0EABI`.
4. **No prologue/epilogue**: The stack size is 0. No callee-saved registers need saving (no function calls, no spills). So `emitPrologue` is a no-op.
5. **`.cpload $t9`**: In PIC mode, this directive initializes the global pointer (`$gp`) relative to the function address in `$t9`.

Now let's trace each piece through the backend code.

---

## The Cpu0 Stack Frame Layout

Cpu0 follows a downward-growing stack model, similar to MIPS. The stack pointer (`$sp`) always points to the lowest allocated address. Here's the layout of a typical frame:

```
High addresses
┌────────────────────────────┐
│  Caller's frame            │
├────────────────────────────┤  ← Incoming $sp (before prologue)
│  Argument spill area       │  Arguments beyond A0/A1 are here
│  (passed by caller)        │
├────────────────────────────┤
│  Callee-saved registers    │  LR, FP, S0, S1 (if used)
│  (saved by prologue)       │
├────────────────────────────┤
│  Local variables           │  alloca / spill slots
│  (allocated by prologue)   │
├────────────────────────────┤
│  Outgoing argument area    │  Space for args to functions we call
│  (reserved by this frame)  │
├────────────────────────────┤  ← $sp after prologue
Low addresses
```

Key design decisions:

- **Stack alignment is 8 bytes.** This is set in `Cpu0Subtarget::stackAlignment()` and enforced in the frame lowering.
- **The stack grows down.** Declared by the `StackGrowsDown` parameter to `TargetFrameLowering`.
- **Frame pointer (\$fp) is optional.** It's only used when the function has variable-sized allocations (`alloca`) or when explicitly requested. When enabled, `$fp` points to the base of the frame, giving stable offsets for local variables even as `$sp` changes.

The frame lowering base class captures this:

```cpp
// From Cpu0FrameLowering.h
class Cpu0FrameLowering : public TargetFrameLowering {
public:
  explicit Cpu0FrameLowering(const Cpu0Subtarget &sti, unsigned Alignment)
      : TargetFrameLowering(StackGrowsDown, Align(Alignment), 0, Align(Alignment)),
        STI(sti) {}
};
```

---

## Prologue and Epilogue Emission

The `Cpu0SEFrameLowering::emitPrologue` method is called by LLVM's `PrologEpilogInserter` pass. It emits the code that runs at the start of every function to set up the stack frame. Let's walk through it:

```cpp
// From Cpu0SEFrameLowering.cpp
void Cpu0SEFrameLowering::emitPrologue(MachineFunction &MF,
                                       MachineBasicBlock &MBB) const {
  MachineFrameInfo &MFI = MF.getFrameInfo();
  // ...
  uint64_t StackSize = MFI.getStackSize();

  // No need to allocate space on the stack.
  if (StackSize == 0 && !MFI.adjustsStack())
    return;

  // Adjust stack.
  TII.adjustStackPtr(SP, -StackSize, MBB, MBBI);

  // emit ".cfi_def_cfa_offset StackSize"
  unsigned CFIIndex =
      MF.addFrameInst(MCCFIInstruction::cfiDefCfaOffset(nullptr, StackSize));
  BuildMI(MBB, MBBI, dl, TII.get(TargetOpcode::CFI_INSTRUCTION))
      .addCFIIndex(CFIIndex);
```

The first thing it does is check if a stack frame is needed at all. Our three-argument example above needed no frame (stack size was 0), so the function returned immediately. But for functions that do need a frame, the sequence is:

1. **Decrement `$sp`** by the stack size: `addiu $sp, $sp, -StackSize`
2. **Emit CFI directives** so debuggers and exception unwinders can walk the stack
3. **Save callee-saved registers** (if any). The `spillCalleeSavedRegisters` method handles this:

```cpp
// From Cpu0SEFrameLowering.cpp
bool Cpu0SEFrameLowering::spillCalleeSavedRegisters(
    MachineBasicBlock &MBB, MachineBasicBlock::iterator MI,
    ArrayRef<CalleeSavedInfo> CSI, const TargetRegisterInfo *TRI) const {
  for (unsigned i = 0, e = CSI.size(); i != e; ++i) {
    unsigned Reg = CSI[i].getReg();
    bool IsRAAndRetAddrIsTaken =
        (Reg == Cpu0::LR) && MF->getFrameInfo().isReturnAddressTaken();
    if (!IsRAAndRetAddrIsTaken) {
      EntryBlock->addLiveIn(Reg);
    }
    bool IsKill = !IsRAAndRetAddrIsTaken;
    const TargetRegisterClass *RC = TRI->getMinimalPhysRegClass(Reg);
    TII.storeRegToStackSlot(*EntryBlock, MI, Reg, IsKill, CSI[i].getFrameIdx(),
                            RC, TRI);
  }
  return true;
}
```

Each callee-saved register is stored to its assigned stack slot. The LLVM framework already figured out *which* registers need saving (by scanning the function body for uses), and *where* to save them (by assigning frame indices). This method just emits the actual `ST` (store) instructions.

4. **Set up \$fp** if needed. When `hasFP()` returns true, the prologue copies `$sp` to `$fp`:

```cpp
  if (hasFP(MF)) {
    // Insert instruction "move $fp, $sp" at this location.
    BuildMI(MBB, MBBI, dl, TII.get(ADDu), FP)
        .addReg(SP)
        .addReg(ZERO)
        .setMIFlag(MachineInstr::FrameSetup);
  }
```

The idiom `addu $fp, $sp, $zero` is Cpu0's way of expressing a register move (there's no dedicated `mov` instruction).

The epilogue in `emitEpilogue` does the inverse: restore `$sp` from `$fp` (if frame pointer is enabled), then add back the stack size to `$sp`:

```cpp
void Cpu0SEFrameLowering::emitEpilogue(MachineFunction &MF,
                                       MachineBasicBlock &MBB) const {
  // if framepointer enabled, restore the stack pointer.
  if (hasFP(MF)) {
    // Insert instruction "move $sp, $fp" at this location.
    BuildMI(MBB, I, DL, TII.get(ADDu), SP).addReg(FP).addReg(ZERO);
  }

  uint64_t StackSize = MFI.getStackSize();
  if (!StackSize)
    return;

  // Adjust stack.
  TII.adjustStackPtr(SP, StackSize, MBB, MBBI);
}
```

### The `determineCalleeSaves` Hook

Before the prologue runs, LLVM calls `determineCalleeSaves` to figure out which registers need saving. The Cpu0 implementation adds a few extra registers:

```cpp
void Cpu0SEFrameLowering::determineCalleeSaves(MachineFunction &MF,
                                               BitVector &SavedRegs,
                                               RegScavenger *RS) const {
  TargetFrameLowering::determineCalleeSaves(MF, SavedRegs, RS);

  // Mark $fp as used if function has dedicated frame pointer.
  if (hasFP(MF)) {
    setAliasRegs(MF, SavedRegs, FP);
  }

  // Create spill slots for eh data registers if function calls eh_return.
  if (Cpu0FI->callsEhReturn()) {
    Cpu0FI->createEhDataRegsFI();
  }

  // Always save $lr if function makes any calls.
  if (MF.getFrameInfo().hasCalls()) {
    setAliasRegs(MF, SavedRegs, Cpu0::LR);
  }
}
```

The key insight: **`$lr` (the link register) is saved whenever the function makes any call.** Unlike architectures with hardware-managed return address stacks, Cpu0 uses a single link register that gets overwritten by every `JSUB`/`JALR` instruction. If a function calls another function, it must save `$lr` first, or it won't know where to return to.

---

## The Calling Convention in TableGen

The calling convention is defined declaratively in `Cpu0CallingConv.td`. It's remarkably compact:

```tablegen
// From Cpu0CallingConv.td

def CSR_O32 : CalleeSavedRegs<(add LR, FP, (sequence "S%u", 1, 0))>;

def RetCC_Cpu0EABI : CallingConv<[
  // i32 are returned in registers V0, V1, A0, A1
  CCIfType<[i32], CCAssignToReg<[V0, V1, A0, A1]>>
]>;

def RetCC_Cpu0 : CallingConv<[
  CCDelegateTo<RetCC_Cpu0EABI>
]>;
```

Three definitions, three critical pieces of ABI:

**`CSR_O32`** defines the callee-saved registers: `$lr`, `$fp`, `$s1`, `$s0`. These are the registers that a function must preserve across calls --- if a function uses any of them, it must save them in the prologue and restore them in the epilogue. The `(sequence "S%u", 1, 0)` generates `S1, S0` --- note the reverse order, which affects spill slot layout.

**`RetCC_Cpu0EABI`** defines where return values go: `i32` values are assigned to registers `V0`, `V1`, `A0`, `A1`, in that order. A function returning one `i32` uses `V0` ($r2). A function returning a struct of two `i32`s would use `V0` and `V1`.

The argument-passing convention is handled differently --- not by TableGen, but by the `Cpu0CC` C++ class. This is because Cpu0's O32 ABI has complexities (byval arguments, varargs, reserved argument area) that go beyond what the TableGen `CallingConv` mechanism can express.

---

## The `Cpu0CC` Helper Class

The TableGen `CallingConv<>` mechanism handles the simple case: assign arguments to registers in order, spill the rest to the stack. But the O32 ABI has quirks that require C++ logic, so Cpu0 wraps the generated `CCState` in a custom class `Cpu0CC`.

`Cpu0CC` lives in `Cpu0ISelLowering.h` and its key responsibilities are:

**Argument register assignment**. The class knows about the two integer argument registers (A0 at `$r4`, A1 at `$r5`) and the rules for when arguments overflow to the stack:

```cpp
// From Cpu0ISelLowering.cpp -- inside the Cpu0CC class
void Cpu0CC::analyzeCallOperands(const SmallVectorImpl<ISD::OutputArg> &Args,
                                 bool IsVarArg, bool IsSoftFloat,
                                 const SDNode *CallNode,
                                 std::vector<ArgListEntry> &FuncArgs) {
  for (unsigned I = 0, E = Args.size(); I != E; ++I) {
    MVT ArgVT = Args[I].VT;
    ISD::ArgFlagsTy ArgFlags = Args[I].Flags;

    // If it's a byval argument, route it to the stack
    if (ArgFlags.isByVal()) {
      handleByValArg(I, ArgVT, ArgVT, CCValAssign::Full, ArgFlags);
      continue;
    }

    // Use generated TableGen logic for standard arguments
    if (CC_Cpu0(I, ArgVT, ArgVT, CCValAssign::Full, ArgFlags, CCInfo)) {
      dbgs() << "Call operand #" << I << " has unhandled type "
             << EVT(ArgVT).getEVTString() << '\n';
      llvm_unreachable(nullptr);
    }
  }
}
```

**Reserved argument area**. O32 mandates a 16-byte reserved area at the top of each frame (above the outgoing argument area). This is historical: the original MIPS O32 ABI reserved space for the first four argument registers so that variadic functions could always spill registers to a predictable location. Cpu0 preserves this convention:

```cpp
unsigned Cpu0CC::reservedArgArea() const {
  return (IsO32_ && (CallConv != CallingConv::Fast)) ? 16 : 0;
}
```

The `reservedArgArea()` method is called in `writeVarArgRegs` to compute the starting offset of variable arguments on the stack. Without this reservation, variadic functions would compute wrong offsets for arguments beyond the first register pair.

**`intArgRegs()` / `numIntArgRegs()`**. These return the list of integer argument registers for the current convention. This abstraction allows vararg handling to work without hardcoding register names:

```cpp
static const MCPhysReg O32IntRegs[] = { Cpu0::A0, Cpu0::A1 };

const ArrayRef<MCPhysReg> Cpu0CC::intArgRegs() const { return O32IntRegs; }
unsigned Cpu0CC::numIntArgRegs() const { return array_lengthof(O32IntRegs); }
```

The separation of `Cpu0CC` from the raw `CCState` is an important design pattern: `CCState` is LLVM's generic calling convention state machine; `Cpu0CC` is the target-specific adapter that adds Cpu0 and O32 semantics on top of it. This pattern also appears in MIPS, from which Cpu0's calling convention code is adapted.

---

## Byval Arguments: Passing Structs on the Stack

When a function is called with a `byval` argument (a struct passed by value), the calling convention must copy the entire struct onto the stack before the call. This is more complex than passing a simple integer:

```llvm
%struct.Point = type { i32, i32 }
define void @foo(%struct.Point* byval(%struct.Point) align 4 %p) { ... }
```

The `handleByValArg` method in `Cpu0CC` handles this case. For each byval argument:

1. **Compute alignment**: The struct's natural alignment determines whether it's placed at `$sp` or requires padding.
2. **Allocate stack space**: `CCInfo.AllocateStack(Size, Align)` reserves the right number of bytes.
3. **Record the stack offset**: The `CCValAssign::Mem` location type tells `LowerFormalArguments` to create a fixed stack object rather than a register live-in.

On the caller side, `LowerCall` handles byval differently from regular arguments. Instead of a `CopyToReg` node, it emits a sequence of `memcpy` operations (or inline stores for small structs):

```cpp
// For byval arguments, copy the struct to the argument area
if (Flags.isByVal()) {
  SDValue Arg = OutVals[i];
  unsigned Size = Flags.getByValSize();
  // Emit stores or SDNode memcpy
  passByValArg(Chain, DL, RegsToPass, MemOpChains, StackPtr,
               MFI, DAG, Arg, Cpu0CCInfo, VA, Flags, ...);
}
```

For small structs (≤ 8 bytes, fitting in two registers), the struct is split across A0 and A1. For larger structs, everything beyond 8 bytes goes to the stack. The callee then reconstructs the struct from its frame slot.

This complexity is why the `Cpu0CC` wrapper class exists: the generated `CC_Cpu0()` function from TableGen handles the simple integer/float assignment rules, but byval routing requires the additional C++ logic in `Cpu0CC::handleByValArg`.

---

## Call Lowering End-to-End

### The Caller Side: `LowerCall`

When the SelectionDAG builder encounters a `call` IR instruction, it calls `Cpu0TargetLowering::LowerCall`. This is one of the most complex functions in the backend. Here's its structure:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::LowerCall(TargetLowering::CallLoweringInfo &CLI,
                                      SmallVectorImpl<SDValue> &InVals) const {
  // 1. Analyze where each argument should go (register or stack)
  SmallVector<CCValAssign, 16> ArgLocs;
  CCState CCInfo(CallConv, IsVarArg, DAG.getMachineFunction(), ArgLocs,
                 *DAG.getContext());
  Cpu0CC Cpu0CCInfo(CallConv, ABI.IsO32(), CCInfo, SpecialCallingConv);
  Cpu0CCInfo.analyzeCallOperands(Outs, IsVarArg, Subtarget.abiUsesSoftFloat(),
                                 Callee.getNode(), CLI.getArgs());

  // 2. Emit CALLSEQ_START to mark the beginning of the call frame
  unsigned NextStackOffset = CCInfo.getNextStackOffset();
  Chain = DAG.getCALLSEQ_START(Chain, NextStackOffset, 0, DL);

  // 3. Walk the argument list, routing each to its assigned location
  for (unsigned i = 0, e = ArgLocs.size(); i != e; ++i) {
    CCValAssign &VA = ArgLocs[i];

    // Arguments in registers go to RegsToPass
    if (VA.isRegLoc()) {
      RegsToPass.push_back(std::make_pair(VA.getLocReg(), Arg));
      continue;
    }

    // Arguments on the stack get written via store
    MemOpChains.push_back(passArgOnStack(StackPtr, VA.getLocMemOffset(),
                                         Chain, Arg, DL, IsTailCall, DAG));
  }

  // 4. Set up the callee address
  //    - PIC: load address through GOT, pass in $t9
  //    - Static: embed address directly
  if (IsPICCall) {
    Callee = getAddrGlobal(G, Ty, DAG, Cpu0II::MO_GOT_CALL, ...);
  } else {
    Callee = DAG.getTargetGlobalAddress(G->getGlobal(), DL, ...);
  }

  // 5. Emit the actual call node (Cpu0ISD::JmpLink)
  Chain = DAG.getNode(Cpu0ISD::JmpLink, DL, NodeTys, Ops);

  // 6. Emit CALLSEQ_END and extract return values
  Chain = DAG.getCALLSEQ_END(Chain, NextStackOffsetVal, ...);
  return LowerCallResult(Chain, InFlag, CallConv, IsVarArg, Ins, DL, DAG,
                         InVals, CLI.Callee.getNode(), CLI.RetTy);
}
```

The `CALLSEQ_START`/`CALLSEQ_END` pseudo-instructions are critical bookkeeping nodes. They tell the register allocator and frame lowering how much stack space this call requires, so it can reserve the appropriate outgoing argument area.

### PIC vs Static Calls

The `getOpndList` method reveals the PIC/static split:

```cpp
// From Cpu0ISelLowering.cpp
void Cpu0TargetLowering::getOpndList(
    SmallVectorImpl<SDValue> &Ops,
    std::deque<std::pair<unsigned, SDValue>> &RegsToPass, bool IsPICCall,
    bool GlobalOrExternal, bool InternalLinkage, ...) const {
  // T9 should contain the address of the callee function if
  // -relocation-model=pic or it is an indirect call.
  if (IsPICCall || !GlobalOrExternal) {
    unsigned T9Reg = Cpu0::T9;
    RegsToPass.push_front(std::make_pair(T9Reg, Callee));
  } else {
    Ops.push_back(Callee);
  }

  // Insert node "GP copy globalreg" before call to function.
  if (IsPICCall && !InternalLinkage) {
    unsigned GPReg = Cpu0::GP;
    EVT Ty = MVT::i32;
    RegsToPass.push_back(std::make_pair(GPReg, getGlobalReg(CLI.DAG, Ty)));
  }
}
```

In **static** mode, the callee address is encoded directly in the `JSUB` instruction as a 24-bit immediate. This is the simple case.

In **PIC** mode, two extra things happen:
1. The callee's address is loaded from the GOT and placed in `$t9`. The call uses `JALR $t9` (an indirect register call).
2. The `$gp` register is passed along so the callee can access its own GOT entries. This is required because lazy binding stubs need `$gp` to resolve symbols at runtime.

The `.cpload $t9` directive at the top of PIC functions initializes `$gp` relative to `$t9`. After any call returns, the function may need to restore `$gp` (this is what the `ENABLE_GPRESTORE` code handles, though it's conditionally compiled).

### The Callee Side: `LowerFormalArguments`

On the receiving end, `LowerFormalArguments` reverses the process:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::LowerFormalArguments(
    SDValue Chain, CallingConv::ID CallConv, bool IsVarArg,
    const SmallVectorImpl<ISD::InputArg> &Ins, ...) const {
  // Analyze where each argument will arrive
  SmallVector<CCValAssign, 16> ArgLocs;
  CCState CCInfo(CallConv, IsVarArg, DAG.getMachineFunction(), ArgLocs, ...);
  Cpu0CC Cpu0CCInfo(CallConv, ABI.IsO32(), CCInfo);
  Cpu0CCInfo.analyzeFormalArguments(Ins, UseSoftFloat, FuncArg);

  for (unsigned i = 0, e = ArgLocs.size(); i != e; ++i) {
    CCValAssign &VA = ArgLocs[i];

    // Arguments in registers: create virtual register, copy from physical
    if (ABI.IsO32() && IsRegLoc) {
      unsigned Reg = addLiveIn(MF, ArgReg, RC);
      SDValue ArgValue = DAG.getCopyFromReg(Chain, DL, Reg, RegVT);

      // Handle sub-word promotions (i8, i16 passed as i32)
      if (VA.getLocInfo() != CCValAssign::Full) {
        if (VA.getLocInfo() == CCValAssign::SExt)
          ArgValue = DAG.getNode(ISD::AssertSext, DL, RegVT, ArgValue, ...);
        ArgValue = DAG.getNode(ISD::TRUNCATE, DL, ValVT, ArgValue);
      }
      InVals.push_back(ArgValue);
    } else {
      // Arguments on the stack: create fixed stack object, load from it
      int FI = MFI.CreateFixedObject(ValVT.getSizeInBits() / 8,
                                     VA.getLocMemOffset(), true);
      SDValue FIN = DAG.getFrameIndex(FI, ...);
      SDValue Load = DAG.getLoad(LocVT, DL, Chain, FIN, ...);
      InVals.push_back(Load);
    }
  }
}
```

The flow: `Cpu0CC::analyzeFormalArguments` determines where each argument lives (A0, A1, or a stack offset). Then for each argument:
- **Register arguments** are made live-in and copied to virtual registers.
- **Stack arguments** become loads from fixed stack objects at known offsets.

Sub-word arguments (i8, i16) deserve special mention: they arrive promoted to i32 in the argument register, but the LLVM IR expects the original type. The `AssertSext`/`AssertZext` + `TRUNCATE` sequence communicates to the optimizer that the upper bits have a known value, while the truncate narrows back to the expected width.

---

## Varargs Handling

When a function accepts a variable number of arguments (`...`), all remaining argument registers must be saved to the stack so that `va_arg` can access them linearly. The `writeVarArgRegs` method handles this:

```cpp
// From Cpu0ISelLowering.cpp
void Cpu0TargetLowering::writeVarArgRegs(std::vector<SDValue> &OutChains,
                                         const Cpu0CC &CC, SDValue Chain,
                                         const SDLoc &DL,
                                         SelectionDAG &DAG) const {
  unsigned NumRegs = CC.numIntArgRegs();
  const ArrayRef<MCPhysReg> ArgRegs = CC.intArgRegs();
  unsigned Idx = CCInfo.getFirstUnallocated(ArgRegs);

  // Compute the offset of the first variable argument
  int VaArgOffset;
  if (NumRegs == Idx) {
    VaArgOffset = alignTo(CCInfo.getNextStackOffset(), RegSize);
  } else {
    VaArgOffset = (int)CC.reservedArgArea() -
                  (int)(RegSize * (NumRegs - Idx));
  }

  // Record the frame index for VASTART
  int FI = MFI.CreateFixedObject(RegSize, VaArgOffset, true);
  Cpu0FI->setVarArgsFrameIndex(FI);

  // Copy unused argument registers to the stack
  for (unsigned I = Idx; I < NumRegs; ++I, VaArgOffset += RegSize) {
    unsigned Reg = addLiveIn(MF, ArgRegs[I], RC);
    SDValue ArgValue = DAG.getCopyFromReg(Chain, DL, Reg, RegTy);
    FI = MFI.CreateFixedObject(RegSize, VaArgOffset, true);
    SDValue PtrOff = DAG.getFrameIndex(FI, ...);
    SDValue Store = DAG.getStore(Chain, DL, ArgValue, PtrOff, ...);
    OutChains.push_back(Store);
  }
}
```

The `lowerVASTART` implementation is then trivially simple --- it just stores the saved frame index into the `va_list` pointer:

```cpp
SDValue Cpu0TargetLowering::lowerVASTART(SDValue Op, SelectionDAG &DAG) const {
  Cpu0FunctionInfo *FuncInfo = MF.getInfo<Cpu0FunctionInfo>();
  SDValue FI = DAG.getFrameIndex(FuncInfo->getVarArgsFrameIndex(), ...);
  const Value *SV = cast<SrcValueSDNode>(Op.getOperand(2))->getValue();
  return DAG.getStore(Op.getOperand(0), DL, FI, Op.getOperand(1),
                      MachinePointerInfo(SV));
}
```

The remaining `va_arg`, `va_copy`, and `va_end` operations are all expanded by LLVM's generic code (they're marked `Expand` in the constructor).

---

## Return Value Lowering

`LowerReturn` is the complement to `LowerFormalArguments`:

```cpp
SDValue
Cpu0TargetLowering::LowerReturn(SDValue Chain, CallingConv::ID CallConv,
                                bool IsVarArg, ...) const {
  SmallVector<CCValAssign, 16> RVLocs;
  CCState CCInfo(CallConv, IsVarArg, MF, RVLocs, *DAG.getContext());
  Cpu0CC Cpu0CCInfo(CallConv, ABI.IsO32(), CCInfo);
  Cpu0CCInfo.analyzeReturn(Outs, Subtarget.abiUsesSoftFloat(),
                           MF.getFunction().getReturnType());

  // Copy each return value into its assigned physical register
  for (unsigned i = 0; i != RVLocs.size(); ++i) {
    Chain = DAG.getCopyToReg(Chain, DL, VA.getLocReg(), Val, Flag);
    Flag = Chain.getValue(1);
    RetOps.push_back(DAG.getRegister(VA.getLocReg(), VA.getLocVT()));
  }

  return DAG.getNode(Cpu0ISD::Ret, DL, MVT::Other, RetOps);
}
```

The `Cpu0ISD::Ret` node is the custom return node we saw in Post 2. It eventually becomes a `ret $lr` instruction --- an indirect jump through the link register.

Struct return is handled as a special case: when a function returns a struct by value, the sret pointer is copied from the virtual register (saved during `LowerFormalArguments`) back into `$v0` before return.

---

## The Pass Pipeline

All of this machinery is orchestrated by `Cpu0TargetMachine.cpp`, which defines the complete pass pipeline:

```cpp
// From Cpu0TargetMachine.cpp

void Cpu0PassConfig::addIRPasses() {
  TargetPassConfig::addIRPasses();
  addPass(createAtomicExpandPass());    // Expand atomics before ISel
}

bool Cpu0PassConfig::addInstSelector() {
  addPass(createCpu0SEISelDag(getCpu0TargetMachine(), getOptLevel()));
  return false;
}

void Cpu0PassConfig::addPreEmitPass() {
  Cpu0TargetMachine &TM = getCpu0TargetMachine();
  addPass(createCpu0DelJmpPass(TM));          // Remove useless jumps
  addPass(createCpu0DelaySlotFillerPass(TM)); // Fill delay slots
  addPass(createCpu0BranchExpansionPass(TM)); // Expand long branches
}
```

The calling convention work happens at multiple stages:

| Pass | Stage | What it does for calls |
|------|-------|----------------------|
| `addIRPasses` | IR | Expands atomics into LL/SC sequences |
| `addInstSelector` | ISel | `LowerFormalArguments`, `LowerCall`, `LowerReturn` run during DAG building |
| `PrologEpilogInserter` | Late | Calls `emitPrologue`/`emitEpilogue`, inserts CSR saves/restores |
| `addPreEmitPass` | Pre-emit | Delay slot filling, branch expansion |

The `PrologEpilogInserter` is not registered explicitly --- it's a standard pass that LLVM inserts automatically. It calls the frame lowering methods we examined above.

---

## A More Complex Example: Nested Calls

To see the full calling convention in action, consider a function that calls another function:

```llvm
declare i32 @bar(i32)
define i32 @caller(i32 %x) {
  %r = call i32 @bar(i32 %x)
  ret i32 %r
}
```

In PIC mode, this produces:

```asm
caller:
	.frame	$sp,16,$lr
	.mask 	0x00004000,-4
	.set	noreorder
	.cpload	$t9
	.set	nomacro
	lui	$r2, %hi(_gp_disp)
	addiu	$r2, $r2, %lo(_gp_disp)
	addiu	$sp, $sp, -16
	st	$lr, 12($sp)
	.cprestore	8
	ld	$t9, %call16(bar)($gp)
	jalr	$t9
	nop
	ld	$gp, 8($sp)
	ld	$lr, 12($sp)
	addiu	$sp, $sp, 16
	ret	$lr
	nop
```

Now we see everything:

1. **Prologue**: `addiu $sp, $sp, -16` allocates a 16-byte frame. `$lr` is saved at `12($sp)` — the top 4-byte slot of the frame. `.cprestore 8` saves `$gp` at `8($sp)` so it can be restored after the call. The remaining 8 bytes (`sp+0` to `sp+7`) form the O32 outgoing-argument reservation area.
2. **No frame pointer**: this function has no VLAs or address-taken stack objects, so `hasFP()` returns false. `$sp` is used directly throughout — no `$fp` save or setup.
3. **Call setup**: the `lui`/`ori`/`addu` sequence (expanded from `.cpload $t9`) initialises `$gp` from the function's start address. `ld $t9, %call16(bar)($gp)` then loads the callee address from the GOT. The argument (`%x`) is already in `$r4` (A0) from the caller's convention.
4. **The call**: `jalr $t9` performs the indirect call, overwriting `$lr` with the return address.
5. **Delay slot**: `nop` fills the mandatory delay slot after `jalr`.
6. **GP restore**: `ld $gp, 8($sp)` is inserted by the `Cpu0EmitGPRestore` pass because `jalr` clobbers `$gp` under the O32 PIC ABI.
7. **Epilogue**: `$lr` restored from `12($sp)`, stack deallocated with `addiu $sp, $sp, 16`.
8. **Return**: `ret $lr`.

The `.mask 0x00004000,-4` encodes which registers are saved: bit 14 corresponds to `$lr` (register 14). The `-4` is the offset from the canonical frame address to the highest saved register slot. Only `$lr` is callee-saved here — `$fp` is not used.

---

## The EmitGPRestore Pass

In PIC mode, every indirect call (`jalr $t9`) has a side effect: the global pointer `$gp` gets clobbered. The PIC calling convention specifies that after any indirect call, the caller must restore `$gp` from the stack slot where the prologue saved it. Without this restore, the next global variable access or function call would compute a wrong address.

This is handled by `Cpu0EmitGPRestore.cpp`, a `MachineFunctionPass` that runs as a pre-emit pass. It scans every `MachineBasicBlock` and inserts an `LD $gp, offset($sp)` immediately after each `JALR` instruction:

```cpp
// From Cpu0EmitGPRestore.cpp
bool Inserter::runOnMachineFunction(MachineFunction &F) {
  Cpu0FunctionInfo *Cpu0FI = F.getInfo<Cpu0FunctionInfo>();

  // Only runs in PIC mode when $gp is saved
  if ((TM.getRelocationModel() != Reloc::PIC_) ||
      (!Cpu0FI->globalBaseRegFixed()))
    return false;

  int FI = Cpu0FI->getGPFI(); // Frame index of saved $gp slot

  for (auto &MBB : F) {
    // Also restore after EH landing pad entry (exception unwind clobbers $gp)
    if (MBB.isEHPad()) {
      // Find EH_LABEL, then insert LD $gp after it
      auto I = MBB.begin();
      for (; I->getOpcode() != TargetOpcode::EH_LABEL; ++I) {}
      ++I;
      BuildMI(MBB, I, dl, TII->get(Cpu0::LD), Cpu0::GP)
          .addFrameIndex(FI).addImm(0);
    }

    // After every JALR: restore $gp from stack
    for (auto I = MBB.begin(); I != MBB.end(); ++I) {
      if (I->getOpcode() != Cpu0::JALR) continue;
      BuildMI(MBB, ++I, dl, TII->get(Cpu0::LD), Cpu0::GP)
          .addFrameIndex(FI).addImm(0);
    }
  }
  return Changed;
}
```

The before-and-after for a PIC call to `bar()`:

**Before EmitGPRestore:**
```asm
ld    $t9, %call16(bar)($gp)
jalr  $t9
nop
# $gp is now garbage — callee may have changed it!
ld    $r2, %got(global_var)($gp)  ← wrong address
```

**After EmitGPRestore:**
```asm
ld    $t9, %call16(bar)($gp)
jalr  $t9
nop
ld    $gp, 8($sp)                 ← restore from saved slot
ld    $r2, %got(global_var)($gp)  ← correct
```

The `ld $gp, 8($sp)` restore is emitted for *every* `JALR`, not just calls to external symbols. Even calls to local symbols go through `$t9` in large-GOT PIC mode, so all of them need the restore.

The pass also handles EH landing pads: when an exception unwinds from a callee, `$gp` may be in an arbitrary state. The pass inserts a `$gp` restore immediately after the EH label, before any landing pad code runs.

Note that `Cpu0EmitGPRestore.cpp` is guarded by `#ifdef ENABLE_GPRESTORE`. This guard mirrors the MIPS backend's approach, where GP restore is conditional on the ABI variant and optimization level. When disabled, the prologue's `.cpload` must ensure `$gp` never becomes stale — which requires all calls to be direct (`jsub`) rather than indirect (`jalr`).

---

## PIC vs Static: The `jalr` vs `jsub` Difference

```
       Caller                              Callee
         │                                   │
         │  set $a0=$arg0, $a1=$arg1         │
         │  (stack if >2 args)               │
         │                                   │
         │─── jsub func (static) ───────────▶│
         │    jalr $t9   (PIC)               │
         │                                   │  prologue: addiu $sp, $sp, -N
         │                                   │  save callee regs ($lr, $fp, S0, S1)
         │                                   │  set $fp = $sp (if needed)
         │                                   │
         │                                   │  ... function body ...
         │                                   │
         │                                   │  restore callee regs
         │                                   │  epilogue: addiu $sp, $sp, +N
         │◀── ret $lr ───────────────────────│
         │                                   │
         │  (PIC) restore $gp from stack     │
```

The choice between PIC and static linking fundamentally changes how call instructions are generated. This is controlled by the relocation model passed to `llc`:

```bash
llc -march=cpu0 -relocation-model=pic    # PIC mode: indirect calls
llc -march=cpu0 -relocation-model=static # Static: direct calls
```

In **static mode**, `lowerCall()` emits a direct `jsub symbol` instruction. The assembler encodes the 24-bit relative offset directly into the instruction. No GOT, no `$t9`, no `$gp` restore needed:

```asm
# Static call to bar:
jsub  bar      # direct 24-bit branch
nop
```

In **PIC mode**, the callee address must be loaded from the GOT (because shared libraries can be mapped at any address). `lowerCall()` emits the `%call16()` GOT load sequence before `jalr`:

```asm
# PIC call to bar:
ld    $t9, %call16(bar)($gp)   # load address from GOT
jalr  $t9                       # indirect call through $t9
nop
ld    $gp, offset($sp)          # restore $gp (EmitGPRestore pass)
```

The `%call16` relocation type asks the linker to create a GOT entry for `bar` and patch the 16-bit offset of that entry relative to `$gp`. This is one of the 17 relocation types we'll catalog fully in [Post 8: Globals & Relocations](08-globals-relocations.md).

---

## Summary

The calling convention involves at least six files working in concert:

| File | Role |
|------|------|
| `Cpu0CallingConv.td` | Declares callee-saved registers and return value assignment |
| `Cpu0ISelLowering.cpp` | `LowerCall`, `LowerFormalArguments`, `LowerReturn` --- the argument routing logic |
| `Cpu0SEFrameLowering.cpp` | `emitPrologue`, `emitEpilogue` --- stack frame setup and teardown |
| `Cpu0FrameLowering.h` | Stack growth direction, alignment, `hasFP()` |
| `Cpu0MachineFunction.h` | Per-function metadata: `VarArgsFrameIndex`, `SRetReturnReg`, GP-related info |
| `Cpu0EmitGPRestore.cpp` | Restores `$gp` after every PIC indirect call |
| `Cpu0TargetMachine.cpp` | Pass pipeline registration |

The most important insight from this post: **the calling convention is not a single piece of code --- it's a contract distributed across the entire backend.** The TableGen definition specifies *what* should happen. The ISel lowering methods implement *how* arguments flow at the DAG level. And the frame lowering methods handle the *physical* stack manipulation. All three must agree perfectly, or the ABI breaks.

---

## Further Reading

- [LLVM Code Generator: Calling Conventions](https://llvm.org/docs/CodeGenerator.html) --- Official docs on the `CCState` and `CCValAssign` framework
- [Writing an LLVM Backend: Calling Conventions](https://llvm.org/docs/WritingAnLLVMBackend.html#calling-conventions) --- Backend writing guide section on calling conventions
- [LLVM Code Generator: Prologue/Epilogue Insertion](https://llvm.org/docs/CodeGenerator.html#prolog-epilog-code-insertion) --- How LLVM handles frame setup
- [The LLVM Target-Independent Code Generator](https://llvm.org/docs/CodeGenerator.html) --- Full pipeline reference

---

*Previous: [Post 2 — From IR to Machine Instructions: How SelectionDAG Actually Works](02-selectiondag.md)*

*Next up: [Post 4 — The MC Layer: From Abstract Instructions to Real Bytes](04-mc-layer.md)*
