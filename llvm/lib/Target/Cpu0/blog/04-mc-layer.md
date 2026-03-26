# The MC Layer: From Abstract Instructions to Real Bytes

*Part 4 of "Building an LLVM Backend From Scratch" — tracing the path from `MachineInstr` through `MCInst` to binary bytes in an ELF file.*

---

## Two Worlds, One Layer

LLVM has a remarkable architectural feature that many compiler engineers never think about: the same infrastructure that turns compiler output into object files also powers the standalone assembler. The **MC layer** (Machine Code layer) is the shared foundation. It represents instructions as `MCInst` objects --- lightweight, target-independent containers that know nothing about register allocation, stack frames, or control flow.

This dual-use design means that the MC layer sits at a critical junction:

```
Compiler path:     MachineInstr  →  MCInstLower  →  MCInst  →  MCCodeEmitter  →  bytes
                                                       ↑
Assembler path:    .s text  →  AsmParser  →   MCInst  ─┘
```

Both paths converge on `MCInst`. From there, the same code emitter, the same fixup resolution, and the same ELF writer handle everything. One encoding table, two entry points.

In this post, we'll trace how a `MachineInstr` becomes a sequence of bytes in an ELF object file, examining every transformation along the way.

---

## MCInst Lowering: The Bridge from CodeGen to MC

```
                                         ┌─────────────────┐
                                    ┌───▶│  .s text output │  (llc -S / assembly printing)
                                    │    │  (InstPrinter)  │
┌─────────────┐   MCInstLower   ┌───┴──┐ └─────────────────┘
│MachineInstr │ ──────────────▶ │MCInst│
└─────────────┘                 └───┬──┘
  (CodeGen world)                   │    MCCodeEmitter
  knows frames,                     └──────────────────▶ bytes ──▶ MCObjectWriter ──▶ .o file
  virtual regs,                                          (binary)                     (ELF)
  MBB structure
```

The transition from the code generator world to the MC world happens in `Cpu0MCInstLower.cpp`. Its central method, `Lower`, converts a `MachineInstr` (which knows about stack frames, virtual registers, and machine-level metadata) into an `MCInst` (which knows only opcodes, register numbers, and immediates):

```cpp
// From Cpu0MCInstLower.cpp
void Cpu0MCInstLower::Lower(const MachineInstr *MI, MCInst &OutMI) const {
  if (lowerLongBranch(MI, OutMI)) {
    return;
  }

  OutMI.setOpcode(MI->getOpcode());

  for (const MachineOperand &MO : MI->operands()) {
    MCOperand MCOp = LowerOperand(MO);
    if (MCOp.isValid())
      OutMI.addOperand(MCOp);
  }
}
```

For most instructions, this is a mechanical translation: copy the opcode, then convert each operand. But the operand conversion is where the interesting work happens:

```cpp
MCOperand Cpu0MCInstLower::LowerOperand(const MachineOperand &MO,
                                        int64_t offset) const {
  switch (MO.getType()) {
  case MachineOperand::MO_Register:
    if (MO.isImplicit()) break;
    return MCOperand::createReg(MO.getReg());
  case MachineOperand::MO_Immediate:
    return MCOperand::createImm(MO.getImm() + offset);
  case MachineOperand::MO_GlobalAddress:
  case MachineOperand::MO_ExternalSymbol:
  case MachineOperand::MO_JumpTableIndex:
  case MachineOperand::MO_BlockAddress:
  case MachineOperand::MO_MachineBasicBlock:
    return LowerSymbolOperand(MO, MOTy, offset);
  case MachineOperand::MO_RegisterMask:
    break;
  }
  return MCOperand();
}
```

Registers and immediates translate directly. But symbolic operands --- global addresses, external symbols, jump table references --- need special handling. They become `MCExpr` expressions wrapped in `MCOperand`s. This is where target-specific relocations enter the picture.

### Symbol Operand Lowering

The `LowerSymbolOperand` method converts `MachineOperand` target flags into `Cpu0MCExpr` expression kinds:

```cpp
MCOperand Cpu0MCInstLower::LowerSymbolOperand(const MachineOperand &MO,
                                              MachineOperandType MOTy,
                                              unsigned Offset) const {
  Cpu0MCExpr::Cpu0ExprKind TargetKind = Cpu0MCExpr::CEK_None;

  switch (MO.getTargetFlags()) {
  case Cpu0II::MO_GPREL:     TargetKind = Cpu0MCExpr::CEK_GPREL;     break;
  case Cpu0II::MO_GOT_CALL:  TargetKind = Cpu0MCExpr::CEK_GOT_CALL;  break;
  case Cpu0II::MO_GOT:       TargetKind = Cpu0MCExpr::CEK_GOT;       break;
  case Cpu0II::MO_ABS_HI:    TargetKind = Cpu0MCExpr::CEK_ABS_HI;    break;
  case Cpu0II::MO_ABS_LO:    TargetKind = Cpu0MCExpr::CEK_ABS_LO;    break;
  case Cpu0II::MO_GOT_HI16:  TargetKind = Cpu0MCExpr::CEK_GOT_HI16;  break;
  case Cpu0II::MO_GOT_LO16:  TargetKind = Cpu0MCExpr::CEK_GOT_LO16;  break;
  case Cpu0II::MO_TLSGD:     TargetKind = Cpu0MCExpr::CEK_TLSGD;     break;
  // ... and more for TLS models
  }

  // Create the MCSymbol, wrap it in an MCExpr, wrap that in a Cpu0MCExpr
  const MCExpr *Expr = MCSymbolRefExpr::create(Symbol, Kind, *Ctx);
  if (TargetKind != Cpu0MCExpr::CEK_None) {
    Expr = Cpu0MCExpr::create(TargetKind, Expr, *Ctx);
  }
  return MCOperand::createExpr(Expr);
}
```

This is a critical translation: the code generator knows about `MO_GOT_CALL` (a target flag integer). The MC layer needs a `Cpu0MCExpr::CEK_GOT_CALL` expression that can be printed as `%call16(symbol)` in assembly text and resolved to a `fixup_Cpu0_CALL16` fixup during encoding.

### Long Branch Lowering

One special case deserves attention: long branch pseudo-instructions. The `Cpu0BranchExpansion` pass (discussed in [Post 5](05-control-flow.md)) generates `LONG_BRANCH_LUi` and `LONG_BRANCH_ADDiu` pseudos that carry two basic block operands. These can't be lowered by the generic path --- they need to compute the difference between two labels:

```cpp
void Cpu0MCInstLower::lowerLongBranchLUi(const MachineInstr *MI,
                                         MCInst &OutMI) const {
  OutMI.setOpcode(Cpu0::LUi);
  OutMI.addOperand(LowerOperand(MI->getOperand(0)));

  // Create %hi($tgt-$baltgt).
  OutMI.addOperand(createSub(MI->getOperand(1).getMBB(),
                             MI->getOperand(2).getMBB(),
                             Cpu0MCExpr::CEK_ABS_HI));
}
```

The `createSub` method builds an `MCExpr` of the form `%hi(label1 - label2)`. This expression can only be created at the MC layer, because `MachineBasicBlock` symbols don't exist until the AsmPrinter creates them. This is why the branch expansion pass emits pseudo-instructions rather than real ones --- the actual encoding is deferred to lowering time.

---

## The `.cpload` Expansion

Another notable lowering is `.cpload $t9`, which initializes the global pointer for PIC functions. `Cpu0MCInstLower::LowerCPLOAD` expands it into three real instructions:

```cpp
void Cpu0MCInstLower::LowerCPLOAD(SmallVector<MCInst, 4> &MCInsts) {
  MCOperand GPReg = MCOperand::createReg(Cpu0::GP);
  MCOperand T9Reg = MCOperand::createReg(Cpu0::T9);
  const MCSymbol *Sym = Ctx->getOrCreateSymbol("_gp_disp");

  MCSym = Cpu0MCExpr::create(Sym, Cpu0MCExpr::CEK_ABS_HI, *Ctx);
  MCOperand SymHi = MCOperand::createExpr(MCSym);
  MCSym = Cpu0MCExpr::create(Sym, Cpu0MCExpr::CEK_ABS_LO, *Ctx);
  MCOperand SymLo = MCOperand::createExpr(MCSym);

  MCInsts.resize(3);
  CreateMCInst(MCInsts[0], Cpu0::LUi, GPReg, SymHi);
  CreateMCInst(MCInsts[1], Cpu0::ORi, GPReg, GPReg, SymLo);
  CreateMCInst(MCInsts[2], Cpu0::ADD, GPReg, GPReg, T9Reg);
}
```

This produces: `lui $gp, %hi(_gp_disp)` / `ori $gp, $gp, %lo(_gp_disp)` / `add $gp, $gp, $t9`. The `_gp_disp` symbol is the offset from the function's start to the global pointer value --- the linker resolves it.

---

## The Code Emitter: Turning MCInst into Bytes

Once we have an `MCInst`, the code emitter encodes it into binary. The process is driven by `Cpu0MCCodeEmitter::encodeInstruction`:

```cpp
// From Cpu0MCCodeEmitter.cpp
void Cpu0MCCodeEmitter::encodeInstruction(const MCInst &MI, raw_ostream &OS,
                                          SmallVectorImpl<MCFixup> &Fixups,
                                          const MCSubtargetInfo &STI) const {
  uint32_t Binary = getBinaryCodeForInstr(MI, Fixups, STI);

  // Check for unimplemented opcodes.
  unsigned Opcode = MI.getOpcode();
  if ((Opcode != Cpu0::NOP) && (Opcode != Cpu0::SHL) && !Binary) {
    llvm_unreachable("unimplemented opcode in encodeInstruction()");
  }

  // Pseudo instructions don't get encoded
  const MCInstrDesc &Desc = MCII.get(MI.getOpcode());
  uint64_t TSFlags = Desc.TSFlags;
  if ((TSFlags & Cpu0II::FormMask) == Cpu0II::Pseudo) {
    llvm_unreachable("Pseudo opcode found in encodeInstruction()");
  }

  int Size = 4;  // All Cpu0 instructions are 4 bytes
  EmitInstruction(Binary, Size, OS);
}
```

The key call is `getBinaryCodeForInstr` --- a **TableGen-generated** function that reads the `Inst{31-0}` bit assignments from the `.td` files and encodes all fields. It returns a 32-bit integer representing the instruction encoding.

But that 32-bit integer needs to be written as bytes --- and which byte goes first depends on endianness:

```cpp
void Cpu0MCCodeEmitter::EmitInstruction(uint64_t Val, unsigned Size,
                                        raw_ostream &OS) const {
  for (unsigned i = 0; i < Size; ++i) {
    unsigned Shift = IsLittleEndian ? i * 8 : (Size - 1 - i) * 8;
    EmitByte((Val >> Shift) & 0xff, OS);
  }
}
```

This is elegantly simple: for big-endian, bytes are emitted most-significant first (`(Size - 1 - i) * 8` gives shifts of 24, 16, 8, 0). For little-endian, least-significant first (`i * 8` gives 0, 8, 16, 24). The `IsLittleEndian` flag was set in the constructor based on which target was registered:

```cpp
MCCodeEmitter *createCpu0MCCodeEmitterEB(const MCInstrInfo &MCII,
                                         MCContext &Ctx) {
  return new Cpu0MCCodeEmitter(MCII, Ctx, false);  // big-endian
}

MCCodeEmitter *createCpu0MCCodeEmitterEL(const MCInstrInfo &MCII,
                                         MCContext &Ctx) {
  return new Cpu0MCCodeEmitter(MCII, Ctx, true);   // little-endian
}
```

### Operand Encoding Callbacks

For operands that aren't simple register or immediate fields, the code emitter calls target-specific methods. The most important is `getMemEncoding`, which encodes memory operands (base register + offset) into the instruction word:

```cpp
unsigned Cpu0MCCodeEmitter::getMemEncoding(const MCInst &MI, unsigned OpNo,
                                           SmallVectorImpl<MCFixup> &Fixups,
                                           const MCSubtargetInfo &STI) const {
  // Base register is encoded in bits 20-16, offset in bits 15-0.
  assert(MI.getOperand(OpNo).isReg());
  unsigned RegBits = getMachineOpValue(MI, MI.getOperand(OpNo), Fixups, STI)
                     << 16;
  unsigned OffBits =
      getMachineOpValue(MI, MI.getOperand(OpNo + 1), Fixups, STI);
  return (OffBits & 0xffff) | RegBits;
}
```

Branch target operands have their own callbacks that create fixups for the linker:

```cpp
unsigned Cpu0MCCodeEmitter::getBranch16TargetOpValue(
    const MCInst &MI, unsigned OpNo,
    SmallVectorImpl<MCFixup> &Fixups, const MCSubtargetInfo &STI) const {
  const MCOperand &MO = MI.getOperand(OpNo);
  if (MO.isImm()) return MO.getImm();

  const MCExpr *Expr = MO.getExpr();
  Fixups.push_back(
      MCFixup::create(0, Expr, MCFixupKind(Cpu0::fixup_Cpu0_PC16)));
  return 0;
}
```

When the branch target is a label expression (not yet resolved), the encoder emits 0 for the offset field and records a fixup. The assembler backend will resolve the fixup later.

---

## Fixups and Relocations: The Three-Phase Process

```
Phase 1: Emit                Phase 2: Resolve             Phase 3: Relocate
─────────────────            ────────────────             ─────────────────
Encode instruction.          Assembler resolves           Remaining fixups
Unknown address              same-section local           become ELF relocation
replaced with zero.          labels and offsets.          entries for linker.
Fixup record stored:
  type, offset, symbol  ──▶  Local fixups patched  ──▶   R_CPU0_HI16
                             Cross-section unknown         R_CPU0_LO16
                             symbols remain.               R_CPU0_CALL16
                                                           ...linker patches at
Example:                                                   link time.
  lui $r2, %hi(global_var)
  └─▶ placeholder in .text
      + fixup record
      → R_CPU0_HI16 reloc
```

Getting from an unresolved symbol to a final address is a three-phase process:

### Phase 1: Fixup Creation (Code Emitter)

During encoding, any operand that references a symbol creates a **fixup** --- a record saying "this instruction needs patching at this offset with this kind of relocation." The `getExprOpValue` method maps `Cpu0MCExpr` kinds to fixup kinds:

```cpp
unsigned Cpu0MCCodeEmitter::getExprOpValue(const MCExpr *Expr,
                                           SmallVectorImpl<MCFixup> &Fixups,
                                           const MCSubtargetInfo &STI) const {
  if (Kind == MCExpr::Target) {
    const Cpu0MCExpr *Cpu0Expr = cast<Cpu0MCExpr>(Expr);
    Cpu0::Fixups FixupKind = Cpu0::Fixups(0);
    switch (Cpu0Expr->getKind()) {
    case Cpu0MCExpr::CEK_GPREL:    FixupKind = Cpu0::fixup_Cpu0_GPREL16; break;
    case Cpu0MCExpr::CEK_GOT_CALL: FixupKind = Cpu0::fixup_Cpu0_CALL16;  break;
    case Cpu0MCExpr::CEK_GOT:      FixupKind = Cpu0::fixup_Cpu0_GOT;     break;
    case Cpu0MCExpr::CEK_ABS_HI:   FixupKind = Cpu0::fixup_Cpu0_HI16;   break;
    case Cpu0MCExpr::CEK_ABS_LO:   FixupKind = Cpu0::fixup_Cpu0_LO16;   break;
    // ... 12 more kinds for GOT, TLS, etc.
    }
    Fixups.push_back(MCFixup::create(0, Expr, MCFixupKind(FixupKind)));
    return 0;
  }
}
```

### Phase 2: Fixup Resolution (Asm Backend)

The decision of whether to resolve a fixup at assembly time is made by LLVM's generic `MCAssembler::layout()`. It calls `evaluateFixup()` on each fixup: if the target symbol is in the same section and its address is known, `applyFixup()` is called to patch the instruction bytes directly. If not, the fixup becomes an ELF relocation (Phase 3).

The Cpu0 implementation of `applyFixup()` in `Cpu0AsmBackend.cpp` works in three steps:

1. **`adjustFixupValue()`** computes the value to embed. For `fixup_Cpu0_PC16`/`fixup_Cpu0_PC24` it subtracts 4 (the PC already advanced past the instruction); for `fixup_Cpu0_HI16` it extracts bits 31:16; for `fixup_Cpu0_LO16` it passes the low 16 bits as-is.
2. The adjusted value is OR-masked into the current instruction bytes, respecting endianness (big-endian vs little-endian byte order is handled by reversing the byte index).
3. The patched bytes are written back to the fragment data.

One important Cpu0-specific flag: `fixup_Cpu0_PC24` (used by `jsub`/`jmp`) is tagged `FKF_IsPCRel | FKF_Constant` when not using `lld`. The `FKF_Constant` flag tells the assembler to **always** apply this fixup at assembly time and never emit it as an ELF relocation — `jsub` targets are always resolved within the object file. When `lld` is selected (`-has-lld`), the flag drops `FKF_Constant`, allowing the linker to handle long-range `jsub` relocations.

### Phase 3: Relocation Emission (ELF Object Writer)

For fixups that can't be resolved at assembly time --- cross-section references, external symbols, GOT entries --- the fixup becomes an ELF **relocation**. The `Cpu0ELFObjectWriter::getRelocType` method maps internal fixup kinds to ELF relocation types:

```cpp
// From Cpu0ELFObjectWriter.cpp
unsigned Cpu0ELFObjectWriter::getRelocType(MCContext &Ctx,
                                           const MCValue &Target,
                                           const MCFixup &Fixup,
                                           bool IsPCRel) const {
  unsigned Kind = (unsigned)Fixup.getKind();
  switch (Kind) {
  case FK_Data_4:               return ELF::R_CPU0_32;
  case Cpu0::fixup_Cpu0_GPREL16: return ELF::R_CPU0_GPREL16;
  case Cpu0::fixup_Cpu0_CALL16:  return ELF::R_CPU0_CALL16;
  case Cpu0::fixup_Cpu0_GOT:     return ELF::R_CPU0_GOT16;
  case Cpu0::fixup_Cpu0_HI16:    return ELF::R_CPU0_HI16;
  case Cpu0::fixup_Cpu0_LO16:    return ELF::R_CPU0_LO16;
  case Cpu0::fixup_Cpu0_PC16:    return ELF::R_CPU0_PC16;
  case Cpu0::fixup_Cpu0_PC24:    return ELF::R_CPU0_PC24;
  // ... TLS relocations
  }
}
```

Cpu0 defines 17 fixup kinds in `Cpu0FixupKinds.h`, covering:

| Category | Fixup Kinds | ELF Relocations |
|----------|------------|----------------|
| Absolute | `fixup_Cpu0_32`, `HI16`, `LO16` | `R_CPU0_32`, `R_CPU0_HI16`, `R_CPU0_LO16` |
| PC-relative | `PC16`, `PC24` | `R_CPU0_PC16`, `R_CPU0_PC24` |
| GOT | `GOT`, `CALL16`, `GOT_HI16`, `GOT_LO16` | `R_CPU0_GOT16`, `R_CPU0_CALL16`, etc. |
| GP-relative | `GPREL16` | `R_CPU0_GPREL16` |
| TLS | `TLSGD`, `GOTTPREL`, `TP_HI`, `TP_LO`, `TLSLDM`, `DTP_HI`, `DTP_LO` | Various `R_CPU0_TLS_*` |

The `needsRelocateWithSymbol` method tells the linker whether a relocation must point to the original symbol or can be relaxed to a section-relative reference:

```cpp
bool Cpu0ELFObjectWriter::needsRelocateWithSymbol(const MCSymbol &Sym,
                                                  unsigned Type) const {
  switch (Type) {
  case ELF::R_CPU0_HI16:
  case ELF::R_CPU0_LO16:
  case ELF::R_CPU0_32:
    return true;   // Must relocate with symbol (for HI/LO pairing)
  case ELF::R_CPU0_GPREL16:
    return false;  // Section-relative is fine
  default:
    return true;
  }
}
```

HI16/LO16 relocations must keep the symbol because the static linker pairs them --- it matches `R_CPU0_HI16` and `R_CPU0_LO16` relocations against the same symbol to compute the full 32-bit address.

---

## ELF Anatomy: What's Actually in the Object File

Let's look at what `Cpu0TargetObjectFile.cpp` produces. A Cpu0 object file has the standard ELF sections plus a few Cpu0-specific ones:

```
ELF Header
  e_machine:    EM_CPU0 (custom)
  e_flags:      ABI version, endianness flag

Section Headers:
  .text         SHT_PROGBITS  SHF_ALLOC+EXEC   — machine code
  .data         SHT_PROGBITS  SHF_ALLOC+WRITE  — initialized globals
  .rodata       SHT_PROGBITS  SHF_ALLOC        — read-only data (string literals, etc.)
  .bss          SHT_NOBITS    SHF_ALLOC+WRITE  — uninitialized globals (takes no file space)
  .sdata        SHT_PROGBITS  SHF_ALLOC+WRITE  — small data (≤8 bytes, GP-relative)
  .sbss         SHT_NOBITS    SHF_ALLOC+WRITE  — small BSS (≤8 bytes, uninitialized)
  .rel.text     SHT_REL                        — relocations against .text
  .symtab       SHT_SYMTAB                     — symbol table
  .strtab       SHT_STRTAB                     — string table for symbols
  .shstrtab     SHT_STRTAB                     — string table for section names
```

You can inspect these sections with `llvm-readelf`. The input IR defines a single `i32` global `g` and a reader function:

```llvm
; eg_global.ll
@g = global i32 42

define i32 @load_g() nounwind {
  %v = load i32, i32* @g
  ret i32 %v
}
```

(`nounwind` suppresses `.eh_frame` generation so the section table stays minimal.)

```bash
# compile IR → Cpu0 object file (static, small-section enabled)
build/bin/llc -march=cpu0 -relocation-model=static -cpu0-use-small-section=true \
  -filetype=obj eg_global.ll -o eg_global.cpu0.o

# inspect section headers
build/bin/llvm-readelf -S eg_global.cpu0.o
```

```
There are 7 section headers, starting at offset 0xd8:

Section Headers:
  [Nr] Name              Type            Address  Off    Size   ES Flg Lk Inf Al
  [ 0]                   NULL            00000000 000000 000000 00      0   0  0
  [ 1] .strtab           STRTAB          00000000 000090 000047 00      0   0  1
  [ 2] .text             PROGBITS        00000000 000034 000010 00  AX  0   0  4
  [ 3] .rel.text         REL             00000000 000088 000008 08   I  6   2  4
  [ 4] .sdata            PROGBITS        00000000 000044 000004 00  WA  0   0  4
  [ 5] .note.GNU-stack   PROGBITS        00000000 000048 000000 00      0   0  1
  [ 6] .symtab           SYMTAB          00000000 000048 000040 10      1   2  4
```

`g` (a 4-byte `i32` global, within the 8-byte small-section threshold) lands in `.sdata` rather than `.data` — enabled by `-cpu0-use-small-section=true`. Without this flag the global goes to `.data` and the access becomes a two-instruction `lui`/`ori` pair. The `.rel.text` section holds exactly one 8-byte REL entry: the `R_CPU0_GPREL16` fixup. The generated code for `load_g` is two instructions: `ori $r2, $gp, %gp_rel(g)` (computes the address of `g` as a GP-relative offset — this is where the relocation sits) followed by `ld $r2, 0($r2)` (loads the value).

`Cpu0TargetObjectFile` (`MCTargetDesc/Cpu0TargetObjectFile.cpp`) controls the section routing: globals whose allocated size falls within the small-section threshold go to `.sdata`/`.sbss` for GP-relative access; everything else falls through to the standard ELF section logic. Post 8 examines this in full detail alongside the GP-relative addressing mode it enables.

### Relocation Sections

For each section that contains relocatable references, the ELF writer creates a `.rel.text` (or `.rela.text`) section. Each relocation entry is an `(offset, symbol, type)` tuple. The input for this example is a PIC function that loads `g` and calls `bar`:

```llvm
; eg_call.ll
@g = global i32 42
declare i32 @bar(i32)

define i32 @foo() nounwind {
  %v = load i32, i32* @g
  %r = call i32 @bar(i32 %v)
  ret i32 %r
}
```

```bash
build/bin/llc -march=cpu0 -relocation-model=pic -cpu0-use-small-section=true \
  -filetype=obj eg_call.ll -o eg_call.cpu0.o
build/bin/llvm-readelf -r eg_call.cpu0.o
```

```
Relocation section '.rel.text' at offset 0xe0 contains 6 entries:
 Offset     Info    Type                Sym. Value  Symbol's Name
00000000  00000305 R_CPU0_HI16            00000000   _gp_disp   ← .cpload upper half
00000004  00000306 R_CPU0_LO16            00000000   _gp_disp   ← .cpload lower half
0000000c  00000305 R_CPU0_HI16            00000000   _gp_disp   ← lui $r2 (gp init)
00000010  00000306 R_CPU0_LO16            00000000   _gp_disp   ← addiu $r2 (gp init)
00000020  00000409 R_CPU0_GOT16           00000000   g          ← %got(g)
00000028  0000050b R_CPU0_CALL16          00000000   bar        ← %call16(bar)
```

The first four entries are `_gp_disp` relocations from the two-phase GP initialisation: the `.cpload $t9` directive expands to a `lui`/`ori`/`addu` triple (entries at `0x00`/`0x04`), and the backend also emits an explicit `lui $r2`/`addiu $r2` pair for the GP base register (entries at `0x0c`/`0x10`). The `R_CPU0_GOT16` entry at `0x20` is the `ld $r2, %got(g)($gp)` load (which comes first in the function body, since `g` is read before `bar` is called), and `R_CPU0_CALL16` at `0x28` is the `ld $t9, %call16(bar)($gp)` instruction.

The linker reads these entries, looks up each symbol, and patches the instruction bytes at the given offsets with the computed values.

---

## The MCExpr System: %hi, %lo, and Friends

```
32-bit address of symbol:  0xABCD1234

  bit 31                 bit 16  bit 15               bit 0
  ┌──────────────────────────────┬─────────────────────────┐
  │    upper 16 bits: 0xABCD     │   lower 16 bits: 0x1234 │
  └──────────────────────────────┴─────────────────────────┘
           │                                  │
           ▼                                  ▼
  lui  $r2, %hi(sym)              ori  $r2, $r2, %lo(sym)
  (loads 0xABCD into              (ORs 0x1234 into
   bits 31:16 of $r2)              bits 15:0 of $r2)

  Note: %hi(sym) adds 1 if bit 15 of %lo(sym) is set
  (compensates for sign extension in ori/addiu)
```

Target-specific expressions like `%hi(symbol)` and `%lo(symbol)` are represented by the `Cpu0MCExpr` class. Each expression has a kind and a sub-expression:

```cpp
// From Cpu0MCExpr.cpp
void Cpu0MCExpr::printImpl(raw_ostream &OS, const MCAsmInfo *MAI) const {
  switch (Kind) {
  case CEK_ABS_HI:    OS << "%hi";       break;
  case CEK_ABS_LO:    OS << "%lo";       break;
  case CEK_GOT:       OS << "%got";      break;
  case CEK_GOT_CALL:  OS << "%call16";   break;
  case CEK_GPREL:     OS << "%gp_rel";   break;
  case CEK_GOT_HI16:  OS << "%got_hi";   break;
  case CEK_GOT_LO16:  OS << "%got_lo";   break;
  case CEK_TLSGD:     OS << "%tlsgd";    break;
  case CEK_GOTTPREL:  OS << "%gottprel"; break;
  case CEK_TP_HI:     OS << "%tp_hi";    break;
  case CEK_TP_LO:     OS << "%tp_lo";    break;
  // ... and more
  }
  OS << '(';
  Expr->print(OS, MAI, true);
  OS << ')';
}
```

The `printImpl` method produces the assembly syntax you see in `.s` files: `%hi(symbol)`, `%call16(bar)`, `%gp_rel(global)`. When the assembler parses these back, the AsmParser creates the same `Cpu0MCExpr` objects, closing the loop.

The `evaluateAsRelocatableImpl` method simply delegates to the sub-expression:

```cpp
bool Cpu0MCExpr::evaluateAsRelocatableImpl(MCValue &Res,
                                           const MCAsmLayout *Layout,
                                           const MCFixup *Fixup) const {
  return getSubExpr()->evaluateAsRelocatable(Res, Layout, Fixup);
}
```

The actual extraction of the high or low 16 bits happens at link time, not at assembly time. The assembler just records the relocation type; the linker applies the appropriate bit-extraction.

### The Lifetime of a Target Expression

A `Cpu0MCExpr` is created in `Cpu0MCInstLower::LowerSymbolOperand()` and lives until the ELF object writer processes the fixup. Here's the complete lifecycle:

1. **CodeGen → MCInst lowering**: `MO_ABS_HI` target flag → `Cpu0MCExpr::CEK_ABS_HI` wrapped around a `MCSymbolRefExpr`. The expression is attached to the `MCInst` operand.

2. **Code emitter**: When `encodeInstruction()` encounters this operand, it calls `getExprOpValue()`. This method recognizes the `Cpu0MCExpr`, calls `Ctx.createFixup(fixup_Cpu0_HI16, offset, subExpr)`, and returns 0 as the placeholder value.

3. **Asm backend**: After all instructions in a fragment are encoded, `applyFixup()` is called for each fixup. For symbols not yet resolved (external or forward references), the fixup is recorded in the object file as a relocation. For locally-resolved symbols (e.g., within the same section), the value might be applied directly.

4. **ELF writer**: `getRelocType()` translates the fixup kind to an ELF relocation type. `needsRelocateWithSymbol()` determines whether to keep the symbol reference or use a section-relative reference. The result is a `Elf32_Rel` entry in the `.rel.text` section.

5. **Linker**: Reads the `R_CPU0_HI16` relocation, finds the symbol's final address `V`, computes `(V >> 16) & 0xffff` (adjusted for sign extension of the low half), and patches the instruction bytes.

The key insight: **the expression kind determines the fixup kind, which determines the relocation type, which tells the linker what computation to perform.** Every step in this chain must be consistent, or the linker will compute the wrong address.

---

## The AsmTargetStreamer: Target-Specific Assembly Directives

Not every piece of output from the compiler is instructions. Assembly files contain a mix of instructions, data directives, and target-specific pseudo-directives that control the assembler's behavior. For Cpu0, these include:

```asm
.set    noreorder    # Disable assembler delay-slot reordering
.set    nomacro      # Disable assembler macro expansion
.cpload $t9          # Initialize $gp from $t9 (PIC prologue)
.ent    foo          # Mark function entry (for .o MIPS debug info)
.end    foo          # Mark function end
.frame  $sp,0,$lr   # Declare frame layout
.mask   0x00000000,0 # Declare callee-saved register mask
```

These directives are emitted by `Cpu0TargetAsmStreamer` — a subclass of `MCTargetStreamer` that the backend registers alongside the code emitter. The streamer is registered in `LLVMInitializeCpu0TargetMC()`:

```cpp
TargetRegistry::RegisterAsmTargetStreamer(*T, createCpu0AsmTargetStreamer);
```

The target streamer provides methods that the `AsmPrinter` calls at specific points:

```cpp
// From Cpu0TargetStreamer.h
class Cpu0TargetAsmStreamer : public Cpu0TargetStreamer {
public:
  void emitCPLoad(MCSymbol *Symbol);   // emit .cpload
  void emitCPRestore(int Offset);      // emit .cprestore
  void emitFrame(unsigned StackReg, unsigned StackSize, unsigned ReturnReg);
  void emitMask(unsigned CPUBitmask, int CPUTopSavedRegOff);
  // ...
};
```

The key insight is that these methods have a **no-op version** for object file output. When the backend is emitting a `.o` file directly (not via assembly text), the `.cpload`, `.ent`, `.frame` etc. directives don't need to appear in the output — they're assembly conveniences for the human reader and the assembler. The object file streamer simply does nothing when these methods are called.

This dual behavior is why the streamer abstraction exists: the same `AsmPrinter` code can emit either assembly text (with all the directives) or object files (without them), just by swapping the streamer implementation.

---

## Endianness as a Cross-Cutting Concern

Endianness affects every level of the MC layer:

1. **Data layout string**: `"E-m:m-p:32:32..."` for big-endian, `"e-m:m-p:32:32..."` for little-endian (set in `Cpu0TargetMachine.cpp`).
2. **Code emitter**: The `EmitInstruction` method swaps byte order based on `IsLittleEndian`.
3. **Fixup application**: When the asm backend patches instruction bytes with resolved values, it must write them in the correct byte order.
4. **ELF header**: The `e_ident[EI_DATA]` field is set to `ELFDATA2MSB` or `ELFDATA2LSB`.
5. **Disassembler**: When reading bytes back, the disassembler reverses the byte order to recover the 32-bit instruction word.

The clean separation at the code emitter level --- two factory functions, one boolean flag --- keeps endianness from spreading into every file. Most of the backend doesn't need to think about it.

---

## Wiring It All Together: MC Component Registration

All these components — `MCAsmInfo`, `MCInstrInfo`, `MCCodeEmitter`, `MCAsmBackend`, `MCELFObjectWriter` — don't magically find each other. They're connected through LLVM's global target registry. The entry point is `LLVMInitializeCpu0TargetMC()` in `MCTargetDesc/Cpu0MCTargetDesc.cpp`, which runs when the Cpu0 target is loaded:

```cpp
extern "C" LLVM_EXTERNAL_VISIBILITY void LLVMInitializeCpu0TargetMC() {
  for (Target *T : {&theCpu0Target, &theCpu0elTarget}) {
    // ABI info: register prefix, comment syntax, code alignment
    RegisterMCAsmInfoFn X(*T, createCpu0MCAsmInfo);
    // Instruction metadata: opcode names, operand types, implicit regs
    TargetRegistry::RegisterMCInstrInfo(*T, createCpu0MCInstrInfo);
    // Register metadata: register names, aliases, DwarfRegNums
    TargetRegistry::RegisterMCRegInfo(*T, createCpu0MCRegisterInfo);
    // Streamer factory: creates the pipeline from MCInst to output
    TargetRegistry::RegisterELFStreamer(*T, createMCStreamer);
    // Backend: fixup application, instruction relaxation
    TargetRegistry::RegisterMCAsmBackend(*T, createCpu0AsmBackend);
    // Subtarget: CPU features, scheduling model
    TargetRegistry::RegisterMCSubtargetInfo(*T, createCpu0MCSubtargetInfo);
    // Instruction analysis: used by objdump, MCA
    TargetRegistry::RegisterMCInstrAnalysis(*T, createCpu0MCInstrAnalysis);
    // InstPrinter: MCInst → assembly text (shared by compiler and disassembler)
    TargetRegistry::RegisterMCInstPrinter(*T, createCpu0MCInstPrinter);
  }

  // Code emitters are registered separately — they differ by endianness
  TargetRegistry::RegisterMCCodeEmitter(theCpu0Target,   createCpu0MCCodeEmitterEB);
  TargetRegistry::RegisterMCCodeEmitter(theCpu0elTarget, createCpu0MCCodeEmitterEL);
}
```

The structure here reveals something about how LLVM handles the dual-target architecture. Eight components are registered identically for both `theCpu0Target` (big-endian) and `theCpu0elTarget` (little-endian) — because they share the same ABI, instruction set, register file, and assembly syntax. Only the code emitter differs, because only it touches the byte order of instruction encoding.

### What Each Component Does

**`MCAsmInfo`** holds target-specific assembly syntax metadata. For Cpu0, this includes the comment character (`#`), the private label prefix (`$`), whether to use integer register names, and the code alignment requirement (4 bytes for a 32-bit RISC machine). This is what drives the distinction between `# RUN:` (correct for Cpu0 `.s` tests) and `; RUN:` (which would be parsed as an instruction).

**`MCInstrInfo`** contains the instruction descriptor table — generated by TableGen as `Cpu0GenInstrInfo.inc`. Each entry records the opcode name, number of operands, implicit use/def register lists, and flags like `isCall`, `isBranch`, `mayLoad`, `mayStore`. Tools like `llvm-objdump` use this to name opcodes; the scheduler uses the flags to understand data hazards.

**`MCRegInfo`** contains the register descriptor table from `Cpu0GenRegisterInfo.inc`. It provides register names (`$zero`, `$at`, `$v0`, ...), register classes, subregister relationships, and Dwarf register numbers. Dwarf register numbers are how the compiler communicates register assignments to debuggers — `DwarfRegNum<[0]>` on `ZERO` means "DWARF register 0 is the zero register."

**`MCSubtargetInfo`** carries the feature string and scheduling tables from `Cpu0.td` and `Cpu0Schedule.td`. Even standalone tools like `llvm-mc` and `llvm-objdump` need subtarget info to handle feature-dependent decoding.

**`MCAsmBackend`** handles the second phase of fixup processing — taking the fixup list from the code emitter and either resolving values directly (for same-section references) or passing them to the ELF writer as relocations. It also controls instruction relaxation: if a short branch encoding doesn't reach its target, the backend can widen it.

**`MCInstPrinter`** is shared between two completely different use cases: the compiler uses it (through `AsmPrinter`) to write `.s` assembly output for human inspection, and the disassembler uses it (through `llvm-objdump`) to print decoded instructions. The same `printInst()` function serves both callers — another example of the MC layer's dual-use design paying off.

### The ELF Streamer Factory

The `createMCStreamer` registration is slightly more complex than the others. When emitting an ELF object file (as opposed to assembly text), `createMCStreamer` is called with an `MCObjectWriter` argument. The factory function constructs a full pipeline:

```cpp
// Simplified from Cpu0MCTargetDesc.cpp
static MCStreamer *createMCStreamer(const Triple &TT, MCContext &Context,
                                    std::unique_ptr<MCAsmBackend> &&MAB,
                                    std::unique_ptr<MCObjectWriter> &&OW,
                                    std::unique_ptr<MCCodeEmitter> &&Emitter,
                                    bool RelaxAll) {
  return createELFStreamer(Context, std::move(MAB), std::move(OW),
                           std::move(Emitter), RelaxAll);
}
```

The `MCStreamer` is the top-level object that accepts a stream of `MCInst` objects (and directives like `.section`, `.globl`, `.word`) and routes them to the appropriate output. For ELF object files, it writes to the `MCObjectWriter`. For assembly text, a different streamer (not registered here) writes text directly. The caller — whether `llc`, `llvm-mc`, or the JIT — decides which streamer to create.

This design means that the backend author only needs to implement the encoding logic once. The choice of output format (`.o` vs `.s`) is entirely determined by the caller.

---

## Putting It All Together

Here's the complete journey of a single instruction, `ld $r2, %got(g)($gp)`, from `MachineInstr` to bytes:

```
MachineInstr:  LD %reg:V0, %reg:GP, @g [target-flags: MO_GOT]
     │
     │  Cpu0MCInstLower::Lower
     ▼
MCInst:  LD $V0, $GP, Cpu0MCExpr(%got, MCSymbolRefExpr(g))
     │
     │  Cpu0MCCodeEmitter::encodeInstruction
     ▼
Binary:  getBinaryCodeForInstr → 0x01_B200_0000  (opcode 0x01, ra=V0=2, rb=GP=11)
         getMemEncoding → base reg = 11 (GP), offset = 0 (fixup)
         getExprOpValue → creates fixup_Cpu0_GOT, returns 0
     │
     │  EmitInstruction (big-endian)
     ▼
Bytes:   01 2B 00 00
         ++ fixup: fixup_Cpu0_GOT at offset 0, targeting symbol "g"
     │
     │  Cpu0ELFObjectWriter::getRelocType
     ▼
ELF relocation:  R_CPU0_GOT16 against symbol "g"
```

The fixup replaces the zero offset with the actual GOT entry offset at link time.

---

## Summary

The MC layer is the unifying abstraction between compilation and assembly. Its components form a pipeline:

| Component | File | Role |
|-----------|------|------|
| MCInst Lowering | `Cpu0MCInstLower.cpp` | Bridges CodeGen `MachineInstr` to MC `MCInst` |
| Code Emitter | `Cpu0MCCodeEmitter.cpp` | Encodes `MCInst` to binary, creates fixups |
| Target Expressions | `Cpu0MCExpr.cpp` | Represents `%hi`, `%lo`, `%got`, etc. |
| Fixup Kinds | `Cpu0FixupKinds.h` | Defines 17 relocation types |
| Asm Backend | `Cpu0AsmBackend.cpp` | Resolves fixups, applies relaxation |
| ELF Writer | `Cpu0ELFObjectWriter.cpp` | Maps fixups to ELF relocation types |

The deepest insight from studying the MC layer: **relocations are not an afterthought --- they're first-class citizens that flow through the entire pipeline.** From the moment `Cpu0ISelLowering` attaches a `MO_GOT_CALL` target flag to an operand, through `Cpu0MCInstLower` converting it to a `CEK_GOT_CALL` expression, through the code emitter creating a `fixup_Cpu0_CALL16`, to the ELF writer emitting an `R_CPU0_CALL16` --- the relocation type is preserved and transformed at every boundary. Getting any one of these translations wrong means the linker sees the wrong relocation type, and the program fails at load time.

---

## Further Reading

- [LLVM MC Design Document](https://llvm.org/docs/CodeGenerator.html#the-mc-layer) --- Official description of the MC layer architecture
- [Writing an LLVM Backend: Assembly Printer](https://llvm.org/docs/WritingAnLLVMBackend.html#assembly-printer) --- How AsmPrinter and MCInstLower work together
- [ELF Specification](https://refspecs.linuxfoundation.org/elf/elf.pdf) --- The ELF format that Cpu0 targets
- [LLVM Code Generator](https://llvm.org/docs/CodeGenerator.html) --- Full pipeline including the MC stage

---

*Previous: [Post 3 — Stack Frames, Calling Conventions, and the ABI](03-calling-conventions.md)*

*Next up: [Post 5 — Control Flow, Branches, and the Passes That Clean Up After You](05-control-flow.md)*
