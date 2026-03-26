# Under the Hood: Custom SDNodes, Type Legalization, and Backend Internals

*Part 9 of "Building an LLVM Backend From Scratch" — the infrastructure that makes everything else work.*

---

## The Invisible Machinery

The previous eight posts focused on what the Cpu0 backend *does* -- selecting instructions, lowering calls, generating object files. This final post looks at the infrastructure *beneath* those features: the custom SDNode vocabulary, the type legalization rules, the immediate-materialization algorithm, the per-function metadata, the MC component registration system, and the scheduling model.

These are the pieces you never think about until they break. They form the skeleton that every other part of the backend hangs on.

---

## The 15 Custom SDNodes

```
Cpu0ISD (15 custom nodes)
│
├── Address Materialization ── Hi, Lo, GPRel, Wrapper
│
├── Calls & Returns ────────── JmpLink, TailCall, Ret, EH_RETURN
│
├── Arithmetic ─────────────── DivRem, DivRemU
│
├── Memory / Sync ──────────── DynAlloc, Sync
│
└── TLS ────────────────────── TlsGd, TpHi, TpLo
```

Every LLVM backend defines a set of **target-specific SDNode opcodes** in a `TargetISD` namespace. These nodes represent operations that have no equivalent in the generic ISD vocabulary -- things like "return from function" or "load the high 16 bits of an address."

Cpu0 defines 15 custom nodes in `Cpu0ISD`:

```cpp
// From Cpu0ISelLowering.h
namespace Cpu0ISD {
enum NodeType : unsigned {
  FIRST_NUMBER = ISD::BUILTIN_OP_END,

  JmpLink,     // Jump and link (call)
  TailCall,    // Tail call
  Hi,          // Get the higher 16 bits from a 32-bit immediate
  Lo,          // Get the lower 16 bits from a 32-bit immediate
  GPRel,       // Handle gp_rel (small data/bss sections) relocation
  Ret,         // Return
  EH_RETURN,   // Exception handling return
  DivRem,      // Signed division with remainder
  DivRemU,     // Unsigned division with remainder
  Wrapper,     // Wraps a target address node for GOT access
  DynAlloc,    // Dynamic stack allocation
  Sync,        // Memory barrier / sync
  TlsGd,       // General Dynamic TLS access
  TpHi,        // Thread pointer high 16 bits (Local Exec TLS)
  TpLo         // Thread pointer low 16 bits (Local Exec TLS)
};
}
```

Each node has a specific role in the backend pipeline. Let's group them by function:

### Address Materialization: `Hi`, `Lo`, `GPRel`, `Wrapper`

These four nodes handle the construction of addresses, as detailed in Post 8. `Hi` and `Lo` represent the upper and lower halves of a 32-bit value. `GPRel` handles the GP-relative addressing mode for small data. `Wrapper` combines a base register with an offset to form a GOT-relative address.

`Wrapper` is particularly important -- it serves as a "container" that holds a base register and a target address, preventing the DAG combiner from trying to fold the address computation into other nodes prematurely.

### Function Calls and Returns: `JmpLink`, `TailCall`, `Ret`, `EH_RETURN`

`JmpLink` is the call node -- it represents a jump-and-link instruction that saves the return address. `TailCall` is its tail-call variant. `Ret` wraps the return instruction. `EH_RETURN` handles the special return sequence for exception handling, which must restore the exception-handling data registers before returning.

### Arithmetic: `DivRem`, `DivRemU`

Cpu0's `div` and `divu` instructions produce both quotient (in LO) and remainder (in HI) simultaneously. The `DivRem` and `DivRemU` nodes model this behavior, allowing the DAG combiner to recognize when both results are needed and avoid computing the division twice.

The `performDivRemCombine` function in `Cpu0ISelLowering.cpp` handles this optimization: when it sees a generic `ISD::SDIVREM` or `ISD::UDIVREM` node, it replaces it with a `Cpu0ISD::DivRem` or `Cpu0ISD::DivRemU` node that produces both results from a single division instruction.

### Synchronization: `Sync`

The `Sync` node represents a memory barrier instruction. It is used to implement `__atomic_thread_fence` and the fences around atomic operations. On Cpu0, it maps to the `sync` instruction.

### Thread-Local Storage: `TlsGd`, `TpHi`, `TpLo`

These nodes support TLS access. `TlsGd` handles General Dynamic TLS (the most general model, used when the compiler doesn't know which module defines the TLS variable). `TpHi` and `TpLo` handle Local Exec TLS, which uses the thread pointer register directly -- the fastest model, but only usable for TLS variables defined in the main executable.

### How Custom Nodes Get Names

Every custom node needs a human-readable name for debug output. The `getTargetNodeName` method provides this:

```cpp
// From Cpu0ISelLowering.cpp
const char *Cpu0TargetLowering::getTargetNodeName(unsigned Opcode) const {
  switch (Opcode) {
  case Cpu0ISD::JmpLink:   return "Cpu0ISD::JmpLink";
  case Cpu0ISD::TailCall:  return "Cpu0ISD::TailCall";
  case Cpu0ISD::Hi:        return "Cpu0ISD::Hi";
  case Cpu0ISD::Lo:        return "Cpu0ISD::Lo";
  case Cpu0ISD::GPRel:     return "Cpu0ISD::GPRel";
  case Cpu0ISD::Ret:       return "Cpu0ISD::Ret";
  case Cpu0ISD::EH_RETURN: return "Cpu0ISD::EH_RETURN";
  case Cpu0ISD::DivRem:    return "Cpu0ISD::DivRem";
  case Cpu0ISD::DivRemU:   return "Cpu0ISD::DivRemU";
  case Cpu0ISD::Wrapper:   return "Cpu0ISD::Wrapper";
  case Cpu0ISD::Sync:      return "Cpu0ISD::Sync";
  case Cpu0ISD::TlsGd:     return "Cpu0ISD::TlsGd";
  case Cpu0ISD::TpHi:      return "Cpu0ISD::TpHi";
  case Cpu0ISD::TpLo:      return "Cpu0ISD::TpLo";
  default:                 return NULL;
  }
}
```

When you run `llc -debug`, these names appear in the DAG dumps, making it possible to trace how target-specific lowering transforms the generic DAG.

---

## Type Legalization: Making Types Fit the Hardware

```
Input type    Action         Result    Notes
──────────────────────────────────────────────────────────────────
i1          → Promote   →   i32       setBooleanContents(ZeroOrOne)
i8          → Promote   →   i32       No 8-bit ALU ops in ISA
i16         → Promote   →   i32       No 16-bit ALU ops in ISA
i32         → Legal     →   i32       Native type, all ops supported
i64         → (not generated)         No 64-bit instructions in ISA

Special: SIGN_EXTEND_INREG i8  →  Expand
  shl $r, $r, 24   # put sign bit at bit 31
  sra $r, $r, 24   # arithmetic shift extends sign downward
```

Cpu0 is a 32-bit architecture with a single register class of 32-bit GPRs. It has no floating-point unit, no vector unit, and no native support for 64-bit integers. This means LLVM's type legalization pass must handle several type mismatches between IR and hardware.

### How LLVM's Legalization Framework Works

LLVM's legalization runs as two distinct phases:

**Phase 1: Type Legalization.** Transforms the DAG so every value has a legal type. There are four possible transformations:
- **Promote**: Widen a type to a larger legal type (`i1` → `i32`, `i8` → `i32`). The value fits in the larger register; the backend handles narrowing when storing back.
- **Expand**: Split a wide type into multiple legal-width parts (`i64` → two `i32` values). Complex multi-value nodes follow.
- **Soften**: Convert floating-point operations to integer equivalents (used when there's no FPU).
- **Scalarize**: Break a vector type into scalar elements.

Cpu0 only uses Promote (for sub-word integer types) and never sees Soften or Scalarize because it has no vector or FP operations.

**Phase 2: Operation Legalization.** After type legalization, every value has a legal type, but not every operation on that type may be supported. The `setOperationAction` calls declare each operation's status. The legalizer applies the declared transformation: Legal operations pass through, Custom operations call `LowerOperation`, Expand operations get decomposed into simpler legal operations by LLVM core.

The legalization rules are established in the `Cpu0TargetLowering` constructor:

### Boolean and i1 Handling

```cpp
// From Cpu0ISelLowering.cpp
setBooleanContents(ZeroOrOneBooleanContent);
setBooleanVectorContents(ZeroOrNegativeOneBooleanContent);

// SETCC results are i32
AddPromotedToType(ISD::SETCC, MVT::i1, MVT::i32);
```

Cpu0 has no `i1` type in hardware. Comparison results are always `i32` values that are either 0 or 1. The `AddPromotedToType` call tells the legalizer to promote any `i1` SETCC result to `i32`.

### Load Extension for i1

```cpp
for (MVT VT : MVT::integer_valuetypes()) {
  setLoadExtAction(ISD::EXTLOAD, VT, MVT::i1, Promote);
  setLoadExtAction(ISD::ZEXTLOAD, VT, MVT::i1, Promote);
  setLoadExtAction(ISD::SEXTLOAD, VT, MVT::i1, Promote);
}
```

Any load of an `i1` value must be promoted to a wider type. This loop registers the promotion for all integer types that might load an `i1`.

### `SIGN_EXTEND_INREG` Expansion

```cpp
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i1, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i8, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i16, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i32, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::Other, Expand);
```

Cpu0 has no native sign-extension-in-register instruction. When LLVM needs to sign-extend a narrow value to 32 bits (e.g., extending an `i8` to `i32`), it expands this into a `SHL`/`SRA` pair: shift left to move the sign bit to bit 31, then arithmetic shift right to replicate it across the upper bits.

For example, sign-extending an `i8` value in register `$r2`:

```asm
shl     $r2, $r2, 24    # Move bit 7 to bit 31
sra     $r2, $r2, 24    # Arithmetic shift right replicates the sign
```

### Division Expansion

```cpp
setOperationAction(ISD::SDIV, MVT::i32, Expand);
setOperationAction(ISD::SREM, MVT::i32, Expand);
setOperationAction(ISD::UDIV, MVT::i32, Expand);
setOperationAction(ISD::UREM, MVT::i32, Expand);
```

This looks surprising -- Cpu0 *does* have division instructions. The `Expand` here means that standalone `SDIV`/`SREM` nodes are expanded into `SDIVREM` nodes (which compute both quotient and remainder), and the DAG combiner then replaces those with `Cpu0ISD::DivRem` to use the hardware's combined div/rem result.

### Operations That Don't Exist

Several operations are expanded because Cpu0 simply doesn't have them:

```cpp
setOperationAction(ISD::CTPOP, MVT::i32, Expand);    // Population count
setOperationAction(ISD::CTTZ, MVT::i32, Expand);     // Count trailing zeros
setOperationAction(ISD::CTTZ_ZERO_UNDEF, MVT::i32, Expand);
setOperationAction(ISD::CTLZ_ZERO_UNDEF, MVT::i32, Expand);
setOperationAction(ISD::BSWAP, MVT::i32, Expand);    // Byte swap
setOperationAction(ISD::SHL_PARTS, MVT::i32, Expand); // 64-bit shift parts
setOperationAction(ISD::SRA_PARTS, MVT::i32, Expand);
setOperationAction(ISD::SRL_PARTS, MVT::i32, Expand);
```

`CTPOP` (popcount), `CTTZ` (count trailing zeros), and `BSWAP` (byte reversal) are all expanded into sequences of simpler instructions. The `*_PARTS` operations handle 64-bit shifts on a 32-bit architecture, expanding into sequences that shift the high and low halves independently.

### Custom Lowering

Several operations use `Custom` instead of `Expand`, meaning the backend provides its own lowering logic in `LowerOperation`:

```cpp
setOperationAction(ISD::GlobalAddress, MVT::i32, Custom);
setOperationAction(ISD::GlobalTLSAddress, MVT::i32, Custom);
setOperationAction(ISD::BlockAddress, MVT::i32, Custom);
setOperationAction(ISD::JumpTable, MVT::i32, Custom);
setOperationAction(ISD::BRCOND, MVT::Other, Custom);
setOperationAction(ISD::SELECT, MVT::i32, Custom);
setOperationAction(ISD::VASTART, MVT::Other, Custom);
setOperationAction(ISD::EH_RETURN, MVT::Other, Custom);
setOperationAction(ISD::ADD, MVT::i32, Custom);
setOperationAction(ISD::ATOMIC_FENCE, MVT::Other, Custom);
```

`Custom` means "call my `LowerOperation` method for this opcode." Each of these has a corresponding `lower*` method (e.g., `lowerGlobalAddress`, `lowerSELECT`, `lowerVASTART`) that performs target-specific transformation. The `ADD` lowering is notable -- it handles the special case where an `add` with a frame index operand needs to use the stack pointer or frame pointer instead of a generic register.

### The Atomic Conundrum

```cpp
setOperationAction(ISD::ATOMIC_LOAD, MVT::i32, Expand);
setOperationAction(ISD::ATOMIC_LOAD, MVT::i64, Expand);
setOperationAction(ISD::ATOMIC_STORE, MVT::i32, Expand);
setOperationAction(ISD::ATOMIC_STORE, MVT::i64, Expand);
```

Basic atomic loads and stores are expanded into regular loads/stores plus fences (because `shouldInsertFencesForAtomic` returns `true`). The more complex atomic operations (compare-and-swap, atomicrmw) use custom inserter pseudo-instructions that expand into LL/SC loops at the MachineInstr level.

---

## Large Immediate Handling: The `Cpu0AnalyzeImmediate` Algorithm

```
Input: 0x12345678 (32-bit, does not fit in 16 bits)

Three strategies (pick shortest):

  Strategy 1 (ADDiu):        Strategy 2 (ORi):          Strategy 3 (SHL):
  Recurse on 0x12340000      Recurse on 0x12340000       Count trailing zeros.
  → LUi 0x1234               → LUi 0x1234                0x12345678 has 3 → skip.
  ADDiu 0x5678               ORi  0x5678                 (Best for 0x04440000:
  = 2 instructions           = 2 instructions             LUi 0x0444 = 1 instr)

GetShortestSeq picks minimum:

  LUi  $r, 0x1234      # load upper 16 bits into bits 31:16
  ORi  $r, $r, 0x5678  # OR lower 16 bits into bits 15:0

Peephole: ADDiu + SHL(>=16) → single LUi (saves one instruction).
```

Loading a 32-bit immediate into a register is not a single instruction on Cpu0 (or on most RISC architectures). The `Cpu0AnalyzeImmediate` class solves this with a dynamic-programming-style search for the shortest instruction sequence.

### The Interface

```cpp
// From Cpu0AnalyzeImmediate.h
class Cpu0AnalyzeImmediate {
public:
  struct Inst {
    unsigned Opc, ImmOpnd;
    Inst(unsigned Opc, unsigned ImmOpnd);
  };
  using InstSeq = SmallVector<Inst, 7>;

  const InstSeq &Analyze(uint64_t Imm, unsigned Size, bool LastInstrIsADDiu);
};
```

You call `Analyze(Imm, Size, LastInstrIsADDiu)` with the immediate value, the bit width, and a flag indicating whether the last instruction must be an `ADDiu` (needed when the immediate is being added to a base register). It returns a sequence of up to 7 instructions.

### The Algorithm

The algorithm explores three decomposition strategies and picks the shortest:

**Strategy 1: ADDiu termination** (`GetInstSeqLsADDiu`)
Round up the immediate to the nearest 16-bit boundary, recursively decompose the upper part, and append an `ADDiu` for the lower 16 bits:

```cpp
void Cpu0AnalyzeImmediate::GetInstSeqLsADDiu(uint64_t Imm, unsigned RemSize,
                                             InstSeqLs &SeqLs) {
  GetInstSeqLs((Imm + 0x8000ULL) & 0xffffffffffff0000ULL, RemSize, SeqLs);
  AddInstr(SeqLs, Inst(ADDiu, Imm & 0xffffULL));
}
```

The `+ 0x8000` compensates for sign extension -- the same `%hi`/`%lo` correction mentioned in Post 8.

**Strategy 2: ORi termination** (`GetInstSeqLsORi`)
Similar to Strategy 1, but uses `ORi` instead of `ADDiu` for the lower 16 bits:

```cpp
void Cpu0AnalyzeImmediate::GetInstSeqLsORi(uint64_t Imm, unsigned RemSize,
                                           InstSeqLs &SeqLs) {
  GetInstSeqLs(Imm & 0xffffffffffff0000ULL, RemSize, SeqLs);
  AddInstr(SeqLs, Inst(ORi, Imm & 0xffffULL));
}
```

`ORi` is used when bit 15 is set (where `ADDiu` and `ORi` produce different results due to sign extension).

**Strategy 3: SHL** (`GetInstSeqLsSHL`)
If the immediate has trailing zeros, shift a smaller value left:

```cpp
void Cpu0AnalyzeImmediate::GetInstSeqLsSHL(uint64_t Imm, unsigned RemSize,
                                           InstSeqLs &SeqLs) {
  unsigned Shamt = countTrailingZeros(Imm);
  GetInstSeqLs(Imm >> Shamt, RemSize - Shamt, SeqLs);
  AddInstr(SeqLs, Inst(SHL, Shamt));
}
```

### The ADDiu+SHL to LUi Optimization

After generating all candidate sequences, a peephole optimization replaces an `ADDiu` followed by `SHL` with a single `LUi` when possible:

```cpp
void Cpu0AnalyzeImmediate::ReplaceADDiuSHLWithLUi(InstSeq &Seq) {
  if ((Seq.size() < 2) || (Seq[0].Opc != ADDiu) || (Seq[1].Opc != SHL) ||
      (Seq[1].ImmOpnd < 16))
    return;

  int64_t Imm = SignExtend64<16>(Seq[0].ImmOpnd);
  int64_t ShiftedImm = (uint64_t)Imm << (Seq[1].ImmOpnd - 16);

  if (!isInt<16>(ShiftedImm))
    return;

  Seq[0].Opc = LUi;
  Seq[0].ImmOpnd = (unsigned)(ShiftedImm & 0xffff);
  Seq.erase(Seq.begin() + 1);
}
```

For example, loading `0x04440000`:
- Without optimization: `ADDiu 0x0111; SHL 18` (2 instructions)
- With optimization: `LUi 0x0444` (1 instruction)

The `GetShortestSeq` method selects the shortest sequence across all strategies, guaranteeing optimality up to 7 instructions.

---

## Per-Function Metadata: `Cpu0FunctionInfo`

Every LLVM backend can attach custom data to each `MachineFunction`. Cpu0 uses `Cpu0FunctionInfo` (aliased as `Cpu0FunctionInfo` in the code, declared in `Cpu0MachineFunction.h`) to track state that spans multiple passes:

```cpp
// From Cpu0MachineFunction.h
class Cpu0FunctionInfo : public MachineFunctionInfo {
  MachineFunction &MF;
  int VarArgsFrameIndex;       // Frame index for start of varargs area
  unsigned SRetReturnReg;      // Virtual register for struct return
  bool HasByValArg;            // Whether function has byval arguments
  unsigned IncomingArgSize;    // Total size of incoming arguments
  bool CallsEhReturn;         // Whether the function calls llvm.eh.return
  bool CallsEhDwarf;          // Whether the function calls llvm.eh.dwarf
  int EhDataRegFI[2];         // Frame objects for EH data registers
  unsigned GlobalBaseReg;      // Virtual register for $gp
  std::pair<int, int> InArgFIRange;  // Frame object range for incoming args
  std::pair<int, int> OutArgFIRange; // Frame object range for outgoing args
  int GPFI;                    // Frame index for restoring $gp
  mutable int DynAllocFI;     // Frame index for dynamic alloca
  unsigned MaxCallFrameSize;   // Largest call frame in the function
  bool EmitNOAT;               // Whether .set noat has been requested
  // ...
};
```

### Key Fields Explained

**`GlobalBaseReg`** -- In PIC mode, every function needs the global pointer register (`$gp`) to access the GOT. This field caches the virtual register that holds `$gp`, created lazily by `getGlobalBaseReg()`. The prologue emitter uses it to insert the `$gp` setup sequence.

**`VarArgsFrameIndex`** -- For variadic functions, this points to the stack frame object where the unnamed arguments begin. The `va_start` lowering (`lowerVASTART`) stores this frame index into the `va_list` structure.

**`SRetReturnReg`** -- When a function returns a struct by pointer (the `sret` calling convention), this field holds the virtual register containing the pointer. The return lowering copies it to `$v0`.

**`InArgFIRange` / `OutArgFIRange`** -- These track the range of frame object indices created during argument lowering. They are used by `isInArgFI` and `isOutArgFI` to determine whether a frame index belongs to the argument area, which affects how the frame is laid out.

**`GPFI`** -- In PIC mode, `$gp` must be saved and restored around function calls (since the callee might modify it). This is the frame index where `$gp` is spilled. The `isGPFI` method lets the frame lowering code identify this slot.

**`MaxCallFrameSize`** -- The largest outgoing call frame needed by any call in the function. This determines how much stack space must be reserved in the prologue for outgoing arguments.

**`EmitNOAT`** -- Set when the assembler encounters a `.set noat` directive. This disables the assembler's use of `$at` (the assembler temporary register) for expanding pseudo-instructions, giving the programmer full control over register usage.

**`EhDataRegFI[2]`** -- Frame objects for spilling the two exception-handling data registers (`$a0` for the exception pointer, `$a1` for the type selector). Created by `createEhDataRegsFI()` only in functions that use `llvm.eh.return`.

---

## MCTargetDesc: Component Registration

The MC (Machine Code) layer is LLVM's lowest-level code representation -- below MachineInstr, below the DAG. Each backend must register a set of MC components so that tools like `llvm-mc`, `llvm-objdump`, and `llc` can work with the target.

The registration happens in `Cpu0MCTargetDesc.cpp`, in the `LLVMInitializeCpu0TargetMC` function:

```cpp
// From Cpu0MCTargetDesc.cpp
extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeCpu0TargetMC() {
  Target &theCpu0Target = getTheCpu0Target();
  Target &theCpu0elTarget = getTheCpu0elTarget();

  for (Target *T : {&theCpu0Target, &theCpu0elTarget}) {
    RegisterMCAsmInfoFn X(*T, createCpu0MCAsmInfo);
    TargetRegistry::RegisterMCInstrInfo(*T, createCpu0MCInstrInfo);
    TargetRegistry::RegisterMCRegInfo(*T, createCpu0MCRegisterInfo);
    TargetRegistry::RegisterELFStreamer(*T, createMCStreamer);
    TargetRegistry::RegisterAsmTargetStreamer(*T, createCpu0AsmTargetStreamer);
    TargetRegistry::RegisterMCAsmBackend(*T, createCpu0AsmBackend);
    TargetRegistry::RegisterMCSubtargetInfo(*T, createCpu0MCSubtargetInfo);
    TargetRegistry::RegisterMCInstrAnalysis(*T, createCpu0MCInstrAnalysis);
    TargetRegistry::RegisterMCInstPrinter(*T, createCpu0MCInstPrinter);
  }

  // Endian-specific: code emitter differs for big vs. little endian
  TargetRegistry::RegisterMCCodeEmitter(theCpu0Target,
                                        createCpu0MCCodeEmitterEB);
  TargetRegistry::RegisterMCCodeEmitter(theCpu0elTarget,
                                        createCpu0MCCodeEmitterEL);
}
```

### The Nine Components

Here is what each registration does:

| Component | Factory Function | Purpose |
|-----------|-----------------|---------|
| **MCAsmInfo** | `createCpu0MCAsmInfo` | Assembly syntax details (comment char, directives, initial frame state) |
| **MCInstrInfo** | `createCpu0MCInstrInfo` | Instruction metadata (from TableGen-generated `Cpu0GenInstrInfo.inc`) |
| **MCRegInfo** | `createCpu0MCRegisterInfo` | Register metadata (from `Cpu0GenRegisterInfo.inc`), return address register = `SW` |
| **ELFStreamer** | `createMCStreamer` | Streams MC instructions into ELF object format |
| **AsmTargetStreamer** | `createCpu0AsmTargetStreamer` | Target-specific assembly directives (`.cpload`, `.set`, etc.) |
| **MCAsmBackend** | `createCpu0AsmBackend` | Fixup handling, relaxation, NOP writing |
| **MCSubtargetInfo** | `createCpu0MCSubtargetInfo` | CPU features (from `Cpu0GenSubtargetInfo.inc`) |
| **MCInstrAnalysis** | `createCpu0MCInstrAnalysis` | Branch/call analysis for disassembly tools |
| **MCInstPrinter** | `createCpu0MCInstPrinter` | Renders `MCInst` to assembly text |

The **MCCodeEmitter** is registered separately for each endianness because byte ordering affects instruction encoding. The big-endian target (`cpu0`) uses `createCpu0MCCodeEmitterEB` and the little-endian target (`cpu0el`) uses `createCpu0MCCodeEmitterEL`.

### The Subtarget Feature Selection

The `createCpu0MCSubtargetInfo` function handles CPU feature selection:

```cpp
static MCSubtargetInfo *createCpu0MCSubtargetInfo(const Triple &TT,
                                                  StringRef CPU, StringRef FS) {
  std::string ArchFS = selectCpu0ArchFeture(TT, CPU);
  if (!FS.empty()) {
    if (!ArchFS.empty())
      ArchFS = ArchFS + "," + FS.str();
    else
      ArchFS = FS.str();
  }
  return createCpu0MCSubtargetInfoImpl(TT, CPU, CPU, ArchFS);
}
```

When no CPU is specified (or `generic` is used), it defaults to `cpu032II`. This affects which instructions are available -- for example, `SLT`-based comparisons are only available on Cpu032II, while `CMP`-based comparisons are only on Cpu032I.

### MCAsmInfo Setup

The `createCpu0MCAsmInfo` function does more than just create the object -- it establishes the initial DWARF frame state:

```cpp
static MCAsmInfo *createCpu0MCAsmInfo(const MCRegisterInfo &MRI,
                                      const Triple &TT,
                                      const MCTargetOptions &Options) {
  MCAsmInfo *MAI = new Cpu0MCAsmInfo(TT);

  unsigned SP = MRI.getDwarfRegNum(Cpu0::SP, true);
  MCCFIInstruction Inst = MCCFIInstruction::createDefCfaRegister(nullptr, SP);
  MAI->addInitialFrameState(Inst);

  return MAI;
}
```

The `addInitialFrameState` call tells DWARF that the Canonical Frame Address (CFA) is initially defined by the stack pointer register. This is the starting point for all frame unwinding information.

---

## Instruction Scheduling

Cpu0 defines a scheduling model in `Cpu0Schedule.td`, though it is primarily used for correctness (itinerary information) rather than aggressive scheduling optimization:

```tablegen
// From Cpu0Schedule.td
def ALU     : FuncUnit;
def IMULDIV : FuncUnit;

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

def Cpu0GenericItineraries : ProcessorItineraries<[ALU, IMULDIV], [], [
  InstrItinData<IIAlu,     [InstrStage<1,  [ALU]>]>,
  InstrItinData<IICLO,     [InstrStage<1,  [ALU]>]>,
  InstrItinData<IICLZ,     [InstrStage<1,  [ALU]>]>,
  InstrItinData<IILoad,    [InstrStage<3,  [ALU]>]>,
  InstrItinData<IIStore,   [InstrStage<1,  [ALU]>]>,
  InstrItinData<IIBranch,  [InstrStage<1,  [ALU]>]>,
  InstrItinData<IIHiLo,    [InstrStage<1,  [IMULDIV]>]>,
  InstrItinData<IIImul,    [InstrStage<17, [IMULDIV]>]>,
  InstrItinData<IIIdiv,    [InstrStage<38, [IMULDIV]>]>,
]>;
```

### What the Itineraries Tell Us

The model defines two functional units: `ALU` (for most operations) and `IMULDIV` (for multiply and divide). The latency numbers reveal the hardware's performance characteristics:

- **ALU operations** (add, sub, logic, compare): 1 cycle
- **CLO/CLZ** (count leading ones/zeros): 1 cycle
- **Loads**: 3 cycles (memory access latency)
- **Stores**: 1 cycle (fire-and-forget)
- **Branches**: 1 cycle
- **HI/LO register moves**: 1 cycle on the IMULDIV unit
- **Multiply**: 17 cycles on the IMULDIV unit
- **Divide**: 38 cycles on the IMULDIV unit

The multiply and divide latencies are deliberately long -- they model the iterative shift-and-add/subtract hardware that a simple RISC implementation would use. The key insight is that `IMULDIV` is a separate functional unit, so multiplications and divisions do not block the ALU pipeline.

In practice, LLVM's instruction scheduler uses these itineraries to avoid scheduling dependent instructions back-to-back when the producer has multi-cycle latency. For example, it won't schedule an instruction that reads the HI register immediately after a `div` -- it will try to fill those 38 cycles with independent work.

### Why the Scheduling Model is Minimal

Production backends like ARM and x86 use much more detailed scheduling models with per-instruction resource tables, bypass paths, and micro-op decomposition. Cpu0's model is deliberately simple for two reasons:

1. Cpu0 is an in-order, single-issue processor -- there are no out-of-order execution resources to model.
2. The backend is educational -- complexity in the scheduling model would obscure the fundamentals.

The `IIPseudo` itinerary class has no entry in the itinerary table because pseudo-instructions are expanded before scheduling.

---

## Dynamic Stack Allocation: `alloca` and `DynAllocFI`

When a function contains a variable-length array or a dynamic `alloca`, the stack frame size is not known at compile time:

```c
void foo(int n) {
  int arr[n];  // size not known until runtime
  // ...
}
```

Cpu0 handles this by setting `ISD::DYNAMIC_STACKALLOC` to `Expand` in `Cpu0ISelLowering.cpp`:

```cpp
setOperationAction(ISD::DYNAMIC_STACKALLOC, MVT::i32, Expand);
```

LLVM's generic expander converts the `alloca` into a `$sp` subtract at the point of allocation — no custom lowering method is needed. The resulting assembly subtracts the (runtime) size from `$sp` and uses the new `$sp` as the array base:

```asm
# llc -march=cpu0 -relocation-model=static vla.ll -o -
foo:
    addiu  $sp, $sp, -8          # static frame: reserve slot for saved $fp
    st     $fp, 4($sp)           # save callee-saved $fp
    move   $fp, $sp              # $fp = $sp (stable reference for locals)
    shl    $r2, $r4, 2           # n * 4 bytes (n is in $r4)
    addiu  $r2, $r2, 7           # round up for alignment
    addiu  $r3, $zero, -8        # alignment mask (0xfffffff8)
    and    $r2, $r2, $r3         # align size to 8 bytes
    subu   $sp, $sp, $r2         # dynamic alloca: subtract from $sp at runtime
    # ... function body accesses locals via $fp offsets ...
    move   $sp, $fp              # epilogue: restore $sp from $fp
    ld     $fp, 4($sp)           # restore saved $fp
    addiu  $sp, $sp, 8
    ret    $lr
    nop
```

Dynamic `alloca` forces the use of a frame pointer. Since `$sp` now moves at runtime, fixed-offset local variable addresses can no longer be expressed relative to `$sp`. The `hasFP` method in `Cpu0FrameLowering` returns `true` when the function has variable-size stack allocations, so the prologue saves `$sp` into `$fp` before any dynamic allocation.

The Cpu0-specific mechanism is `DynAllocFI` in `Cpu0MachineFunction`, a frame index that identifies the dynamic allocation slot. `Cpu0RegisterInfo::eliminateFrameIndex` checks `isDynAllocFI()` to ensure the dynalloc object is always addressed relative to `$sp` (not `$fp`), and skips the normal `StackSize` offset adjustment that would be wrong for a slot whose position is fixed at `$sp`-relative zero:

```cpp
// From Cpu0RegisterInfo.cpp
if (Cpu0FI->isOutArgFI(FrameIndex) || Cpu0FI->isDynAllocFI(FrameIndex) ||
    (FrameIndex >= MinCSFI && FrameIndex <= MaxCSFI))
  FrameReg = Cpu0::SP;   // always $sp for these special slots
else
  FrameReg = getFrameRegister(MF);  // $fp when hasFP(), else $sp
```

Note: `Cpu0ISD::DynAlloc` is defined in the `Cpu0ISD` enum but is never emitted by the current implementation — it is vestigial from an earlier design where dynamic allocation was handled via a custom SDNode rather than `Expand`.

---

## The DAG Combiner Hook

The backend can influence the DAG combiner's behavior through `PerformDAGCombine`:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::PerformDAGCombine(SDNode *N,
                                              DAGCombinerInfo &DCI) const {
  SelectionDAG &DAG = DCI.DAG;
  unsigned Opc = N->getOpcode();

  switch (Opc) {
  default: break;
  case ISD::SDIVREM:
  case ISD::UDIVREM:
    return performDivRemCombine(N, DAG, DCI, Subtarget);
  }

  return SDValue();
}
```

The `setTargetDAGCombine` calls in the constructor register which opcodes the backend wants to intercept:

```cpp
setTargetDAGCombine(ISD::SDIVREM);
setTargetDAGCombine(ISD::UDIVREM);
```

This is the mechanism that enables the DivRem optimization described earlier. When the generic combiner encounters a `SDIVREM` or `UDIVREM` node, it calls `PerformDAGCombine`, which replaces the node with Cpu0-specific DivRem nodes that map to the hardware's combined quotient-and-remainder instructions.

---

## Putting It All Together

These internals form a coherent system. Here is how they interact during compilation of a single function:

1. **Type legalization** runs first, using the `setOperationAction` rules to promote `i1` to `i32`, expand `SIGN_EXTEND_INREG` into shift pairs, and convert standalone division into `SDIVREM`.

2. **DAG combining** fires the `PerformDAGCombine` hook, replacing `SDIVREM` with `Cpu0ISD::DivRem`.

3. **Custom lowering** (`LowerOperation`) handles `GlobalAddress` by calling `lowerGlobalAddress`, which selects the appropriate addressing mode and creates `Cpu0ISD::Hi`/`Lo`/`Wrapper` nodes.

4. **Large immediate materialization** is invoked by the frame lowering code (via `Cpu0AnalyzeImmediate::Analyze`) whenever a stack offset or constant doesn't fit in 16 bits.

5. **Instruction selection** matches the DAG nodes (both generic and custom) to machine instructions using the TableGen-generated matcher.

6. **MC emission** uses the registered MC components to encode instructions, resolve fixups, and write the ELF object file.

7. **Per-function metadata** (`Cpu0FunctionInfo`) carries state from argument lowering through frame layout to prologue/epilogue emission.

Every piece depends on every other piece. The addressing modes need the MC expression system. The type legalization rules determine which DAG nodes the instruction selector sees. The scheduling model influences instruction ordering. And the per-function metadata ties it all together across passes.

---

## Summary

This post covered the six foundational subsystems of the Cpu0 backend:

- **15 custom SDNodes** that form the backend's DAG vocabulary
- **Type legalization** rules that bridge the gap between LLVM IR types and 32-bit hardware
- **`Cpu0AnalyzeImmediate`**, a DP algorithm that finds optimal instruction sequences for arbitrary 32-bit constants
- **`Cpu0FunctionInfo`**, the per-function state that tracks everything from varargs to GP spill slots
- **MC component registration**, the factory system that lets LLVM tools instantiate the right objects for Cpu0
- **Instruction scheduling itineraries** that model ALU and IMULDIV latencies

These are the pieces you don't see in the tutorial but must understand to extend the backend. If you've followed this series from Post 1, you now have a complete mental model of how an LLVM backend works -- from the first TableGen definition to the last ELF byte.

## Further Reading

- [LLVM Code Generator](https://llvm.org/docs/CodeGenerator.html) — Legalization phases, SDNode taxonomy, scheduling
- [Extending LLVM](https://llvm.org/docs/ExtendingLLVM.html) — Adding new SDNodes, intrinsics, and operations
- [LLVM Programmer's Manual](https://llvm.org/docs/ProgrammersManual.html) — Data structures, APIs, and idioms used throughout
- [Writing an LLVM Backend](https://llvm.org/docs/WritingAnLLVMBackend.html) — Complete backend authoring guide

---

*Previous: [Post 8 — Global Variables, Relocations, and Position-Independent Code](08-globals-relocations.md)*
