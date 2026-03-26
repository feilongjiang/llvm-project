# The Anatomy of an LLVM Backend: What 72 Files and 12,000 Lines Actually Do

*Part 1 of "Building an LLVM Backend From Scratch" — a 9-part series using the Cpu0 architecture as a case study to explore LLVM's backend architecture.*

---

## Why Build a Backend From Scratch?

If you want to understand how LLVM turns intermediate representation (IR) into machine code, you have two options: read an existing backend like ARM or MIPS (50,000+ lines each), or build one from zero.

We chose the second path. Over 16 commits and 12,260 lines of code, we built a complete LLVM backend for **Cpu0** — a 32-bit RISC architecture designed for education. The result compiles C and C++ programs to Cpu0 assembly, object files, and ELF binaries. It has an assembler, a disassembler, exception handling, atomics, and thread-local storage. We even verified it on a Verilog RTL simulator.

This series isn't a step-by-step tutorial. It's an **architecture guide** — each post dissects one major layer of LLVM's backend, using our Cpu0 implementation as the concrete specimen under the microscope. By the end, you'll understand not just *what* each file does, but *why* LLVM is structured this way.

### Why Cpu0 Instead of a Real Architecture?

Real production backends like ARM (300K+ lines) or MIPS (50K+ lines) carry years of hardware errata, subtarget variants, intrinsics, and ABI compatibility shims. When you're trying to understand *how* instruction selection works, you spend most of your time wrestling with MIPS's 40 ISA variants rather than understanding the framework itself.

Cpu0 is a teaching ISA: 3 instruction formats, 16 registers, 47 instruction opcodes. It's complex enough to require every LLVM backend component (SelectionDAG, MC layer, ELF writer, assembler, disassembler), but simple enough that the *shape* of the code is visible without drowning in special cases.

The analogy: if you want to understand how a car engine works, start with a go-kart engine — not a Formula 1 V10 with 14,000 rpm fuel injection. Cpu0 is the go-kart engine. Everything in this series applies directly to production backends; Cpu0 just makes the structure legible.

All code is based on LLVM 15.0.7.

---

## The Cpu0 ISA in 5 Minutes

Cpu0 is a 32-bit RISC architecture with these characteristics:

- **16 general-purpose registers** (ZERO, AT, V0-V1, A0-A1, T9, T0-T1, S0-S1, GP, FP, SP, LR, SW)
- **HI/LO register pair** for multiply/divide results
- **Two coprocessor-0 registers** (PC, EPC) for program counter and exception return
- **3 instruction formats** — all 32 bits wide
- **Two ISA variants**: Cpu032I (CMP-based comparisons) and Cpu032II (SLT-based comparisons)
- **Two endianness targets**: `cpu0` (big-endian) and `cpu0el` (little-endian)
- **Soft float only** — no hardware floating point

### Instruction Formats

Every Cpu0 instruction is 32 bits. The top 8 bits are always the opcode, and the remaining 24 bits are divided differently depending on the format:

```
Format A (3-register):
┌──────────┬──────┬──────┬──────┬────────────┐
│  opcode  │  ra  │  rb  │  rc  │   shamt    │
└──────────┴──────┴──────┴──────┴────────────┘
 31      24 23  20 19  16 15  12 11          0

Format L (load/store/immediate):
┌──────────┬──────┬──────┬───────────────────┐
│  opcode  │  ra  │  rb  │      imm16        │
└──────────┴──────┴──────┴───────────────────┘
 31      24 23  20 19  16 15                 0

Format J (jump):
┌──────────┬──────────────────────────────────┐
│  opcode  │             addr                 │
└──────────┴──────────────────────────────────┘
 31      24 23                                0
```

These three formats map directly to TableGen classes in our backend. Here's how they're defined:

```tablegen
// From Cpu0InstrFormats.td

// Generic Cpu0 Instruction — base class for all formats
class Cpu0Inst<dag outs, dag ins, string asmStr, list<dag> pattern,
                InstrItinClass itin, Format f> : Instruction {
  field bits<32> Inst;      // The 32-bit encoding
  bits<8> Opcode = 0;
  let Inst{31-24} = Opcode; // Top 8 bits are always the opcode

  bits<4> FormBits = Form.Value;
  let TSFlags{3-0} = FormBits; // Pack format ID into TSFlags
}

// Format A: 3-register operations (e.g., addu $ra, $rb, $rc)
class FA<bits<8> op, dag outs, dag ins, string asmStr,
         list<dag> pattern, InstrItinClass itin>
  : Cpu0Inst<outs, ins, asmStr, pattern, itin, FrmA> {
  bits<4>   ra;
  bits<4>   rb;
  bits<4>   rc;
  bits<12>  shamt;
  let Inst{23-20} = ra;
  let Inst{19-16} = rb;
  let Inst{15-12} = rc;
  let Inst{11-0}  = shamt;
}

// Format L: load/store/immediate (e.g., addiu $ra, $rb, imm16)
class FL<bits<8> op, dag outs, dag ins, string asmStr,
         list<dag> pattern, InstrItinClass itin>
  : Cpu0Inst<outs, ins, asmStr, pattern, itin, FrmL> {
  bits<4>   ra;
  bits<4>   rb;
  bits<16>  imm16;
  let Inst{23-20} = ra;
  let Inst{19-16} = rb;
  let Inst{15-0}  = imm16;
}

// Format J: jump (e.g., jmp addr)
class FJ<bits<8> op, dag outs, dag ins, string asmStr,
         list<dag> pattern, InstrItinClass itin>
  : Cpu0Inst<outs, ins, asmStr, pattern, itin, FrmJ> {
  bits<24> addr;
  let Inst{23-0} = addr;
}
```

The `Inst{}` bit assignments are the single most important lines in the backend.

### Pseudo Instructions

Beyond the three hardware formats, the backend defines two additional pseudo formats that never map to real machine instructions:

```tablegen
// Cpu0Pseudo — code-gen-only: expanded during ISel, never emitted
class Cpu0Pseudo<dag outs, dag ins, string asmStr, list<dag> pattern>
  : Cpu0Inst<outs, ins, asmStr, pattern, IIPseudo, Pseudo> {
  let isCodeGenOnly = 1;
  let isPseudo = 1;
}

// Cpu0AsmPseudoInst — assembly-only aliases parsed by the AsmParser
// but require C++ to convert; not handled by TableGen InstAliases
class Cpu0AsmPseudoInst<dag outs, dag ins, string asmstr>
  : Cpu0Inst<outs, ins, asmstr, [], IIPseudo, Pseudo> {
  let isPseudo = 1;
  let Pattern = [];
}

// PseudoSE — concrete pseudo for the SE (Standard Edition) tier
class PseudoSE<dag outs, dag ins, list<dag> pattern,
               InstrItinClass itin = IIPseudo>
  : Cpu0Pseudo<outs, ins, "", pattern> {}
```

`Cpu0Pseudo` instructions exist at the MachineInstr level and are lowered to real instructions during pre-emit passes. `Cpu0AsmPseudoInst` instructions appear only in `.s` assembly files and are converted by the AsmParser before code generation ever sees them. This distinction matters when you see "instructions" in the backend that have no binary encoding — they're pseudos that get expanded away. They drive code generation for **four** different consumers: the binary encoder, the disassembler, the assembly parser, and the instruction printer. One definition, four uses — a theme we'll return to throughout this series.

### The Register File

```tablegen
// From Cpu0RegisterInfo.td

// 16 General Purpose Registers
def ZERO  : Cpu0GPRReg<0,   "zero">;  // Always zero
def AT    : Cpu0GPRReg<1,   "r1">;    // Assembler temporary
def V0    : Cpu0GPRReg<2,   "r2">;    // Return values
def V1    : Cpu0GPRReg<3,   "r3">;
def A0    : Cpu0GPRReg<4,   "r4">;    // Function arguments
def A1    : Cpu0GPRReg<5,   "r5">;
def T9    : Cpu0GPRReg<6,   "t9">;    // PIC call target
def T0    : Cpu0GPRReg<7,   "r7">;    // Temporaries
def T1    : Cpu0GPRReg<8,   "r8">;
def S0    : Cpu0GPRReg<9,   "r9">;    // Callee-saved
def S1    : Cpu0GPRReg<10,  "r10">;
def GP    : Cpu0GPRReg<11,  "gp">;    // Global pointer (PIC)
def FP    : Cpu0GPRReg<12,  "fp">;    // Frame pointer
def SP    : Cpu0GPRReg<13,  "sp">;    // Stack pointer
def LR    : Cpu0GPRReg<14,  "lr">;    // Link register (return addr)
def SW    : Cpu0GPRReg<15,  "sw">;    // Status word

// Multiply/divide result registers
def HI    : Cpu0Reg<0, "ac0">;
def LO    : Cpu0Reg<0, "ac0">;
```

The `CPURegs` register class groups these with allocation hints — return values and arguments first, callee-saved registers last, reserved registers at the boundaries:

```tablegen
def CPURegs : RegisterClass<"Cpu0", [i32], 32, (add
  ZERO, AT,         // Reserved
  V0, V1, A0, A1,   // Return values and arguments
  T9, T0, T1,       // Caller-saved temporaries
  S0, S1,           // Callee-saved
  GP, FP, SP, LR, SW // Reserved / special-purpose
)>;
```

Register ordering in the class definition directly controls register allocator preference. The allocator tries registers earlier in the list first, so caller-saved temporaries (which don't need to be spilled across calls) come before callee-saved ones.

Each register also carries a DWARF register number for debug info:

```tablegen
def ZERO : Cpu0GPRReg<0, "zero">, DwarfRegNum<[0]>;
def AT   : Cpu0GPRReg<1, "r1">,   DwarfRegNum<[1]>;
// ...
def HI   : Cpu0Reg<0, "ac0">,     DwarfRegNum<[18]>;
def LO   : Cpu0Reg<0, "ac0">,     DwarfRegNum<[19]>;
```

```
┌──────┬────────────────────────┐
│ ZERO │ Always zero            │
│ AT   │ Assembler temporary    │
│ V0   │ Return value           │
│ V1   │ Return value           │
│ A0   │ Function argument      │
│ A1   │ Function argument      │
│ T9   │ PIC call target        │
│ T0   │ Caller-saved temporary │
│ T1   │ Caller-saved temporary │
│ S0   │ Callee-saved           │
│ S1   │ Callee-saved           │
│ GP   │ Global pointer (PIC)   │
│ FP   │ Frame pointer          │
│ SP   │ Stack pointer          │
│ LR   │ Link register          │
│ SW   │ Status word            │
├──────┴────────────────────────┤
│ HI/LO    (multiply/divide)    │
└───────────────────────────────┘

```

The `DwarfRegNum` annotation ties each hardware register to a DWARF canonical number used in `.eh_frame` and `.debug_frame` sections. Without these mappings, GDB cannot interpret backtraces through Cpu0 code — they're required for any backend that needs debuggable output.

---

## LLVM's Backend Pipeline

When `llc` compiles LLVM IR to machine code, the data flows through a well-defined pipeline. Understanding this pipeline is essential to understanding where each backend file fits:

```
LLVM IR
  │
  ▼
┌──────────────────────────────┐
│  SelectionDAG Legalization   │  ← Cpu0ISelLowering.cpp
│  & Instruction Selection     │  ← Cpu0ISelDAGToDAG.cpp
│  (ISD nodes → MachineInstrs) │  ← Cpu0InstrInfo.td (patterns)
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  Register Allocation         │  ← Cpu0RegisterInfo.cpp
│  (virtual regs → physical)   │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  Pre-Emit Passes             │  ← Cpu0DelUselessJMP.cpp
│  (cleanup, delay slots,      │  ← Cpu0DelaySlotFiller.cpp
│   branch expansion)          │  ← Cpu0BranchExpansion.cpp
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  AsmPrinter / MCInstLower    │  ← Cpu0AsmPrinter.cpp
│  (MachineInstr → MCInst)     │  ← Cpu0MCInstLower.cpp
└──────────────┬───────────────┘
               │
          ┌────┴─────┐
          ▼          ▼
   ┌───────────┐ ┌──────────────┐
   │ Assembly  │ │ Object File  │
   │ (.s text) │ │ (.o ELF)     │
   │           │ │              │
   │InstPrinter│ │ MCCodeEmitter│ ← Cpu0MCCodeEmitter.cpp
   └───────────┘ │ AsmBackend   │ ← Cpu0AsmBackend.cpp
                 │ ELFWriter    │ ← Cpu0ELFObjectWriter.cpp
                 └──────────────┘
```

Every file in the backend maps to one of these stages. The pipeline is registered in `Cpu0TargetMachine.cpp`, which defines the pass configuration:

```cpp
// From Cpu0TargetMachine.cpp

void Cpu0PassConfig::addIRPasses() {
  TargetPassConfig::addIRPasses();
  addPass(createAtomicExpandPass()); // Expand atomics before ISel
}

bool Cpu0PassConfig::addInstSelector() {
  addPass(createCpu0SEISelDag(getCpu0TargetMachine(), getOptLevel()));
  return false;
}

void Cpu0PassConfig::addPreEmitPass() {
  addPass(createCpu0DelJmpPass(TM));         // Remove useless jumps
  addPass(createCpu0DelaySlotFillerPass(TM)); // Fill delay slots
  addPass(createCpu0BranchExpansionPass(TM)); // Expand long branches
}
```

---

## A Map of 72 Files

The Cpu0 backend consists of 72 files across 5 directories. Here's how they're organized:

```
Cpu0 Backend (72 files)
│
├── TableGen (.td) ─────── Cpu0.td, Cpu0InstrFormats.td, Cpu0InstrInfo.td
│                          Cpu0RegisterInfo.td, Cpu0CallingConv.td, Cpu0Schedule.td
│
├── CodeGen (.h/.cpp) ──── Cpu0ISelLowering (+ SE subclass)
│                          Cpu0ISelDAGToDAG (+ SE subclass)
│                          Cpu0FrameLowering (+ SE subclass)
│                          Cpu0InstrInfo (+ SE subclass)
│                          Cpu0RegisterInfo, Cpu0TargetMachine
│
├── MC Layer ───────────── MCTargetDesc/Cpu0MCCodeEmitter
│                          Cpu0ELFObjectWriter, Cpu0AsmBackend
│                          Cpu0FixupKinds.h, Cpu0MCExpr
│
└── Tooling ────────────── Cpu0AsmParser
                           Disassembler/Cpu0Disassembler
                           InstPrinter/Cpu0InstPrinter
```

### TableGen Definitions (11 `.td` files)

These declarative files define the ISA and drive code generation:

| File | Purpose |
|------|---------|
| `Cpu0.td` | Top-level target: processor definitions, subtarget features (Cpu032I/II), AsmParser/Writer registration |
| `Cpu0InstrFormats.td` | Instruction encoding formats (FA, FL, FJ, Pseudo) |
| `Cpu0InstrInfo.td` | All instruction definitions, patterns, and DAG nodes (~40KB — the largest file) |
| `Cpu0RegisterInfo.td` | Register definitions and register classes |
| `Cpu0CallingConv.td` | Calling conventions (callee-saved regs, return value assignment) |
| `Cpu0Schedule.td` | Instruction scheduling: functional units (ALU, IMULDIV) and latencies |
| `Cpu0CondMov.td` | Conditional move instructions (MOVZ, MOVN) and select-to-condmov patterns |
| `Cpu0Asm.td` / `Cpu0Other.td` | Assembly target variants (controls which register names the AsmParser accepts) |
| `Cpu0RegisterInfoGPROutFor{Asm,Other}.td` | Register output constraints per target variant |

### CodeGen C++ (21 `.cpp` + 19 `.h` in main directory)

| Subsystem | Files | Purpose |
|-----------|-------|---------|
| **ISel / Lowering** | `Cpu0ISelDAGToDAG`, `Cpu0SEISelDAGToDAG`, `Cpu0ISelLowering`, `Cpu0SEISelLowering` | Instruction selection and DAG lowering |
| **Frame / Stack** | `Cpu0FrameLowering`, `Cpu0SEFrameLowering` | Prologue/epilogue, stack management |
| **Instruction Info** | `Cpu0InstrInfo`, `Cpu0SEInstrInfo` | Instruction properties, copy, load/store |
| **Register Info** | `Cpu0RegisterInfo`, `Cpu0SERegisterInfo` | Register classes, frame register |
| **Target Machine** | `Cpu0TargetMachine`, `Cpu0Subtarget` | Pass pipeline, feature flags |
| **AsmPrinter** | `Cpu0AsmPrinter`, `Cpu0MCInstLower` | MachineInstr → MCInst bridge |
| **Custom Passes** | `Cpu0BranchExpansion`, `Cpu0DelaySlotFiller`, `Cpu0DelUselessJMP`, `Cpu0EmitGPRestore` | Pre-emit optimization passes |
| **Utilities** | `Cpu0AnalyzeImmediate`, `Cpu0MachineFunction`, `Cpu0TargetObjectFile` | Large immediates, per-function metadata, ELF sections |

### MC Layer (11 `.cpp` + 9 `.h` in `MCTargetDesc/`)

| File | Purpose |
|------|---------|
| `Cpu0MCTargetDesc.cpp` | Registers all MC components (emitter, backend, printer, etc.) |
| `Cpu0MCCodeEmitter.cpp` | Encodes MCInst → binary bytes (with endian handling) |
| `Cpu0AsmBackend.cpp` | Fixup resolution, relaxation |
| `Cpu0ELFObjectWriter.cpp` | Maps fixups → ELF relocation types |
| `Cpu0FixupKinds.h` | 17 relocation/fixup type definitions |
| `Cpu0MCExpr.cpp` | Target-specific expressions: `%hi()`, `%lo()`, `%gp_rel()` |
| `Cpu0ABIInfo.cpp` | ABI configuration (O32) |
| `Cpu0MCAsmInfo.cpp` | Assembly syntax: comment character (`#`), directives |

### Tooling

| Directory | Key File | Purpose |
|-----------|----------|---------|
| `Disassembler/` | `Cpu0Disassembler.cpp` | Binary → MCInst (table-driven) |
| `InstPrinter/` | `Cpu0InstPrinter.cpp` | MCInst → assembly text |
| `TargetInfo/` | `Cpu0TargetInfo.cpp` | Target registration (`cpu0`, `cpu0el`) |

---

## The SE Subclass Pattern

You'll notice that many classes come in pairs: `Cpu0InstrInfo` and `Cpu0SEInstrInfo`, `Cpu0FrameLowering` and `Cpu0SEFrameLowering`, and so on. The "SE" stands for "Standard Edition" and this pattern is borrowed from the MIPS backend.

The idea: **base classes define the virtual interface, SE subclasses provide the concrete implementation.** The `Cpu0Subtarget` creates the SE objects via static factory methods:

```cpp
// From Cpu0Subtarget.cpp

Cpu0Subtarget::Cpu0Subtarget(const Triple &TT, StringRef CPU, StringRef FS,
                             bool little, const Cpu0TargetMachine &_TM)
    : Cpu0GenSubtargetInfo(TT, CPU, CPU, FS), IsLittle(little),
      TM(_TM), TargetTriple(TT), TSInfo(),
      InstrInfo(
          Cpu0InstrInfo::create(initializeSubtargetDependencies(CPU, FS, TM))),
      FrameLowering(Cpu0FrameLowering::create(*this)),
      TLInfo(Cpu0TargetLowering::create(TM, *this)) {
  // ...
}
```

Each `create()` is a factory method. Let's look at `Cpu0InstrInfo::create()` specifically:

```cpp
// From Cpu0InstrInfo.cpp, lines 35-37
const Cpu0InstrInfo *Cpu0InstrInfo::create(const Cpu0Subtarget &STI) {
  return llvm::createCpu0SEInstrInfo(STI);
}
```

`createCpu0SEInstrInfo()` is defined in `Cpu0SEInstrInfo.cpp` and returns a heap-allocated `Cpu0SEInstrInfo` object. The caller receives a `Cpu0InstrInfo*` (base class pointer) — it never knows the concrete type. The `Cpu0Subtarget` owns the object via `std::unique_ptr<Cpu0InstrInfo>`, and every caller that needs instruction info asks the subtarget for it.

The same pattern repeats for `Cpu0FrameLowering::create()` → `Cpu0SEFrameLowering`, and `Cpu0TargetLowering::create()` → `Cpu0SETargetLowering`. The base classes (`Cpu0InstrInfo`, `Cpu0FrameLowering`, `Cpu0ISelLowering`) define the virtual interface; the SE subclasses provide concrete implementations. If Cpu0 ever gained a "Micro" ISA variant with 16-bit compressed instructions, you'd add a `Cpu0MicroInstrInfo` subclass and change `create()` to return it — without touching the rest of the framework.

In practice, Cpu0 only has one edition, so the SE subclass is always used. But the pattern is worth understanding because it's how all MIPS-family backends in LLVM are structured, and it's a good model for any backend that expects to evolve over time.

---

## Two ISA Variants: CMP vs SLT

Cpu0 has two processor variants that differ in how they handle comparisons:

- **Cpu032I** uses `CMP` instructions that set condition flags, then branches test those flags
- **Cpu032II** uses `SLT` (set-less-than) that writes 0 or 1 to a register, then branches test the register value

These are defined as subtarget features in `Cpu0.td`:

```tablegen
def FeatureCmp  : SubtargetFeature<"cmp", "HasCmp", "true",
                                   "Enable 'cmp' instructions.">;
def FeatureSlt  : SubtargetFeature<"slt", "HasSlt", "true",
                                   "Enable 'slt' instructions.">;

def FeatureCpu032I  : SubtargetFeature<"cpu032I", "Cpu0ArchVersion",
    "Cpu032I", "Cpu032I ISA Support", [FeatureCmp]>;
def FeatureCpu032II : SubtargetFeature<"cpu032II", "Cpu0ArchVersion",
    "Cpu032II", "Cpu032II ISA Support (slt)", [FeatureCmp, FeatureSlt]>;
```

The subtarget initializer in `Cpu0Subtarget.cpp` sets the flags:

```cpp
if (isCpu032I()) {
  HasCmp = true;
  HasSlt = false;
} else if (isCpu032II()) {
  HasCmp = false;
  HasSlt = true;
}
```

Note that `FeatureCpu032II` lists `[FeatureCmp, FeatureSlt]` as dependencies, yet the C++ code immediately sets `HasCmp = false` for Cpu032II. This is because `initializeSubtargetDependencies` runs its explicit C++ assignments *after* `ParseSubtargetFeatures` processes the TableGen feature bits, so the explicit assignments win. The `FeatureCmp` dependency in `FeatureCpu032II` is vestigial — it has no effect at runtime.

These flags gate code generation paths throughout the backend. For example, Cpu032II enables the long-branch expansion pass because SLT-based comparison changes branch encoding constraints:

```cpp
bool enableLongBranchPass() const { return hasCpu032II(); }
```

We'll explore the CMP vs SLT design tradeoff in depth in [Post 5: Control Flow](05-control-flow.md).

---

## Target Registration: Two Endianness Targets

LLVM registers Cpu0 as two separate targets — one for each endianness:

```cpp
// From Cpu0TargetMachine.cpp

extern "C" void LLVMInitializeCpu0Target() {
  RegisterTargetMachine<Cpu0ebTargetMachine> X(getTheCpu0Target());   // Big-endian
  RegisterTargetMachine<Cpu0elTargetMachine> Y(getTheCpu0elTarget()); // Little-endian
}
```

Both inherit from `Cpu0TargetMachine` — the only difference is the `isLittle` flag:

```cpp
Cpu0ebTargetMachine::Cpu0ebTargetMachine(...)
    : Cpu0TargetMachine(T, TT, CPU, FS, Options, RM, CM, OL, JIT, false) {}  // big

Cpu0elTargetMachine::Cpu0elTargetMachine(...)
    : Cpu0TargetMachine(T, TT, CPU, FS, Options, RM, CM, OL, JIT, true) {}   // little
```

The `isLittle` flag feeds into `computeDataLayout()`, which constructs the data layout string that LLVM uses to determine alignment, pointer size, and endianness for the entire compilation:

```cpp
static std::string computeDataLayout(const Triple &TT, StringRef CPU,
                                     const TargetOptions &Options,
                                     bool isLittle) {
  std::string Ret = "";
  if (isLittle)
    Ret += "e";   // little-endian
  else
    Ret += "E";   // big-endian (capital E)

  Ret += "-m:m";           // Mips ELF name mangling
  Ret += "-p:32:32";       // 32-bit pointers, 32-bit aligned
  Ret += "-i8:8:32-i16:16:32-i64:64";  // Sub-word types: min-align:pref-align
  Ret += "-n32-S64";       // Native integer: 32-bit; stack: 64-bit aligned
  return Ret;
}
```

This data layout string propagates through the entire stack: from IR optimization (which queries it for alignment of loads/stores), through the MC code emitter (which swaps bytes based on it), to the disassembler (which reads bytes in the correct order). Endianness isn't a single flag — it's woven into every layer.

---

## TableGen: The Dependency Graph

One of the most confusing things about LLVM backends is the relationship between `.td` files and C++ code. Here's how it works:

1. **You write `.td` files** defining instructions, registers, calling conventions
2. **CMake runs TableGen** during the build, generating `.inc` files from the `.td` definitions
3. **C++ files `#include` the generated `.inc` files** to get auto-generated matching logic, encoding tables, etc.

The key generated files for Cpu0:

| Generated File | Source `.td` | What It Contains |
|----------------|-------------|-----------------|
| `Cpu0GenRegisterInfo.inc` | `Cpu0RegisterInfo.td` | Register numbers, classes, DWARF mappings |
| `Cpu0GenInstrInfo.inc` | `Cpu0InstrInfo.td` | Instruction opcodes, operand info |
| `Cpu0GenDAGISel.inc` | `Cpu0InstrInfo.td` (patterns) | Pattern matching code for instruction selection |
| `Cpu0GenCodeEmitter.inc` | `Cpu0InstrFormats.td` (`Inst{}`) | Binary encoding via `getBinaryCodeForInstr()` |
| `Cpu0GenDisassemblerTables.inc` | `Cpu0InstrFormats.td` (`Inst{}`) | Decoding tables for disassembly |
| `Cpu0GenAsmMatcher.inc` | `Cpu0InstrInfo.td` (`AsmString`) | Assembly text → opcode matching |
| `Cpu0GenAsmWriter.inc` | `Cpu0InstrInfo.td` (`AsmString`) | Opcode → assembly text printing |
| `Cpu0GenSubtargetInfo.inc` | `Cpu0.td` | Feature flags, scheduling info |
| `Cpu0GenCallingConv.inc` | `Cpu0CallingConv.td` | Calling convention logic |

The important insight: **you cannot understand the C++ code without understanding the `.td` files**, because most of the actual logic is generated. When you see a C++ file `#include "Cpu0GenDAGISel.inc"`, that's not boilerplate — that's where the instruction selection matching logic lives.

### How the Generated Files Are Consumed

Each `.inc` file has a specific `#define` gate that controls what it exports:

```cpp
// Cpu0InstrInfo.cpp — brings in instruction opcode enum and descriptor tables
#define GET_INSTRINFO_CTOR_DTOR
#include "Cpu0GenInstrInfo.inc"

// Cpu0ISelDAGToDAG.cpp — brings in the SelectionDAG pattern matching table
// (the result of TableGen compiling all Pat<> and DAG patterns)
#include "Cpu0GenDAGISel.inc"

// Cpu0RegisterInfo.cpp — brings in register class enumerations
#define GET_REGINFO_TARGET_DESC
#include "Cpu0GenRegisterInfo.inc"

// Cpu0MCCodeEmitter.cpp — brings in getBinaryCodeForInstr()
#define ENABLE_INSTR_PREDICATE_VERIFIER
#include "Cpu0GenCodeEmitter.inc"

// Cpu0ISelLowering.cpp — brings in CC_Cpu0, RetCC_Cpu0EABI
#include "Cpu0GenCallingConv.inc"
```

The `#define` gates let one `.inc` file export multiple different things depending on which guard is active — `Cpu0GenInstrInfo.inc` can provide both the constructor boilerplate (`GET_INSTRINFO_CTOR_DTOR`) and the instruction descriptor table (`GET_INSTRINFO_ENUM`) from the same TableGen run. This keeps the build system simple: one TableGen invocation per `.td` file, but multiple C++ consumers of the result.

---

## Building and Experimenting

The backend compiles with the standard LLVM CMake workflow:

```bash
mkdir build && cd build
cmake -G Ninja -DCMAKE_BUILD_TYPE=Debug -DLLVM_TARGETS_TO_BUILD=Cpu0 ../llvm
ninja -j7
```

The `-DLLVM_TARGETS_TO_BUILD=Cpu0` flag builds *only* the Cpu0 target, dramatically speeding up compilation versus building all 20+ LLVM targets.

Once built, three commands cover most experimentation:

```bash
# Compile LLVM IR → Cpu0 assembly (big-endian, PIC)
./bin/llc -march=cpu0 -relocation-model=pic input.ll -o output.s

# Compile for little-endian Cpu032II
./bin/llc -march=cpu0el -mcpu=cpu032II -relocation-model=pic input.ll

# Run all Cpu0 regression tests
./bin/llvm-lit ../llvm/test/CodeGen/Cpu0/
```

The `-march=cpu0` vs `-march=cpu0el` switch selects endianness. The `-mcpu=cpu032I` vs `-mcpu=cpu032II` switch selects the comparison strategy. Each of the 72 files we've catalogued affects one or more of these code paths, and each has a corresponding test in `llvm/test/CodeGen/Cpu0/`.

The test suite uses `FileCheck` patterns:

```llvm
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s
; CHECK: addu $r2, $r4, $r5
```

Every significant instruction, every addressing mode, and every calling convention edge case has at least one `FileCheck` test. This is what makes a backend maintainable — not 12,000 lines of C++, but 12,000 lines plus a comprehensive test suite.

---

## A Simple Example: `add` End-to-End

To ground all of this, let's trace a trivial function through the backend:

```llvm
define i32 @add(i32 %a, i32 %b) {
  %c = add i32 %a, %b
  ret i32 %c
}
```

Running `llc -march=cpu0 -relocation-model=pic` produces:

```asm
	.globl	add
	.type	add,@function
	.ent	add
add:
	.frame	$sp,0,$lr
	.mask 	0x00000000,0
	.set	noreorder
	.set	nomacro
	addu	$r2, $r4, $r5
	ret	$lr
	nop
	.set	macro
	.set	reorder
	.end	add
```

What happened:
1. **SelectionDAG** lowered the IR `add` to an `ISD::ADD` node, then matched it against the TableGen pattern for `ADDu` (Format A instruction)
2. **Register allocation** placed `%a` in `$r4` (A0) and `%b` in `$r5` (A1) per the calling convention, and the result in `$r2` (V0) for the return value
3. **Prologue/epilogue** determined no stack frame was needed (no spills, no locals)
4. **AsmPrinter** emitted the `.ent`, `.frame`, `.mask` directives and lowered `MachineInstr` to `MCInst`
5. **InstPrinter** rendered the `MCInst` as `addu $r2, $r4, $r5`
6. **Delay slot filler** inserted `nop` after `ret $lr` (the branch delay slot)

This simple example already touches 6 of the 8 pipeline stages. Every subsequent post will zoom into one of these stages and show what happens with more complex code.

---

## What's Coming Next

| Post | Topic | Key Question |
|------|-------|-------------|
| **2** | [SelectionDAG](02-selectiondag.md) | How does LLVM turn `ISD::ADD` into `ADDu`? |
| **3** | [Calling Conventions](03-calling-conventions.md) | How do function calls work at the machine level? |
| **4** | [The MC Layer](04-mc-layer.md) | How does `MCInst` become bytes in an ELF file? |
| **5** | [Control Flow](05-control-flow.md) | How do branches work, and why do we need 3 cleanup passes? |
| **6** | [Assembler & Disassembler](06-assembler-disassembler.md) | How does one `.td` file drive four different tools? |
| **7** | [C++ Features & Verilog](07-closing-the-loop.md) | How do atomics and exceptions work? Can we prove correctness? |
| **8** | [Globals & Relocations](08-globals-relocations.md) | How does PIC addressing work? What are the 17 relocation types? |
| **9** | [Backend Internals](09-internals.md) | What are custom SDNodes, type legalization, and the other hidden machinery? |

---

## Further Reading

- [Writing an LLVM Backend](https://llvm.org/docs/WritingAnLLVMBackend.html) — LLVM's official backend writing guide
- [The LLVM Target-Independent Code Generator](https://llvm.org/docs/CodeGenerator.html) — Comprehensive reference on all pipeline stages
- [TableGen Overview](https://llvm.org/docs/TableGen/) — Understanding the `.td` language
- [TableGen Programmer's Reference](https://llvm.org/docs/TableGen/ProgRef.html) — Complete language specification
- [Compiler Writer Information](https://llvm.org/docs/CompilerWriterInfo.html) — Architecture references for backend authors

---

*Next up: [Post 2 — From IR to Machine Instructions: How SelectionDAG Actually Works](02-selectiondag.md)*
