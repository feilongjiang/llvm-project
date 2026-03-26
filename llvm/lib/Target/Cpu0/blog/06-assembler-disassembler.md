# Round-Tripping: Building an Assembler and Disassembler

*Part 6 of "Building an LLVM Backend From Scratch" — using the Cpu0 architecture as a case study to explore LLVM's backend architecture.*

---

## The Round-Trip Property

```
                    ┌─────────────┐
              ┌────▶│  .s source  │
              │     └──────┬──────┘
   should     │            │ AsmParser
   match! ◀──▶│            ▼
              │     ┌──────────────┐
              │     │    MCInst    │
              │     └──────┬───┬──┘
              │  Inst-     │   │ MCCodeEmitter
              │  Printer   │   ▼
              │            │  ┌────────────┐
              │            │  │ .o binary  │
              │            │  └─────┬──────┘
              │            │        │ Disassembler
              │            │        ▼
              │            │  ┌──────────────┐
              │            │  │    MCInst    │
              │            │  └──────┬───────┘
              │            │         │ InstPrinter
              │     ┌──────▼─────────▼──┐
              └─────│    .s output      │
                    └───────────────────┘
encode → decode = identity (the round-trip property)
```

A backend isn't truly complete until its tools are symmetric. If you can compile C to assembly, you should be able to **assemble** that assembly into an object file, and then **disassemble** the object file back to assembly -- and get something equivalent to what you started with.

This property -- assemble then disassemble recovering the original -- is the **round-trip property**. It is both a correctness guarantee and a debugging superpower. If the round trip produces different assembly, something in the encoding or decoding pipeline is wrong. Every instruction in the ISA can be tested with a single round-trip test: feed assembly to `llvm-mc`, pipe the binary to `llvm-objdump`, and verify the output matches.

In this post, we dissect the four LLVM components that make the round trip work -- the **assembly printer**, the **assembly parser**, the **binary encoder**, and the **table-driven disassembler** -- all of which are driven from the same `.td` definitions. We also look at directives, pseudo-instruction expansion, and a comment-character gotcha that cost us an hour of debugging.

---

## TableGen as Single Source of Truth

```
              Cpu0InstrInfo.td
           ┌──────────────────┐
           │ Inst{} bit fields│
           │ (encoding)       │
           │ AsmString        │
           │ ("addu $ra,$rb") │
           └────────┬─────────┘
                    │ TableGen compiler
        ┌───────────┼───────────┬───────────┐
        ▼           ▼           ▼           ▼
  CodeEmitter  Disassembler  AsmMatcher  InstPrinter
     .inc       Tables.inc      .inc        .inc
  ───────────  ────────────  ──────────  ───────────
  Binary enc.  Decode tables  Asm parse  Text print
  getBinary    getInstruction MatchAndEmit printInst
  CodeForInstr (bytes→MCInst) Instruction (MCInst→txt)

  One .td definition → four generated consumers
```

Before diving into the individual components, it's worth understanding the key insight behind LLVM's MC layer: **one TableGen definition drives four consumers**. When we write an instruction like this in `Cpu0InstrInfo.td`:

```tablegen
def ADDiu : FL<0x09, (outs GPROut:$ra), (ins CPURegs:$rb, simm16:$imm16),
               "addiu\t$ra, $rb, $imm16",
               [(set GPROut:$ra, (add CPURegs:$rb, immSExt16:$imm16))],
               IIAlu>;
```

That single definition produces:

1. **Code emitter** (`Cpu0GenMCCodeEmitter.inc`) -- knows that `ADDiu` has opcode `0x09`, Format L, with `ra` at bits 23-20, `rb` at bits 19-16, and `imm16` at bits 15-0. Encodes an `MCInst` to binary bytes.

2. **Disassembler tables** (`Cpu0GenDisassemblerTables.inc`) -- reverses the bit-field mapping. Given 32 bits of binary, looks up the opcode byte, determines the format, and extracts the register and immediate fields.

3. **Assembly matcher** (`Cpu0GenAsmMatcher.inc`) -- parses the mnemonic `"addiu"` and matches it against the operand signature `(GPROut, CPURegs, simm16)` to produce an `MCInst`.

4. **Assembly printer** (`Cpu0GenAsmWriter.inc`) -- formats an `MCInst` back to the string `"addiu\t$ra, $rb, $imm16"` using the `printOperand` callbacks.

The instruction format class defines the bit-level encoding. Here is how Cpu0's three formats lay out the `Inst{}` bits:

```tablegen
// Format A: 3-register operations
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

// Format L: load/store/immediate
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

// Format J: jump
class FJ<bits<8> op, dag outs, dag ins, string asmStr,
         list<dag> pattern, InstrItinClass itin>
  : Cpu0Inst<outs, ins, asmStr, pattern, itin, FrmJ> {
  bits<24> addr;
  let Inst{23-0} = addr;
}
```

These `Inst{}` assignments are the blueprint. TableGen reads them to generate both the encoder (field-to-bit packing) and the decoder (bit-to-field extraction). The `.td` file is the **single source of truth** -- change the bit assignment in one place, and all four consumers update on the next build.

---

## The Table-Driven Disassembler

The disassembler's job is to take a sequence of bytes and produce an `MCInst`. In LLVM, this is overwhelmingly table-driven: the auto-generated `Cpu0GenDisassemblerTables.inc` file contains a decoder table (`DecoderTableCpu032`) that maps opcode bytes to instruction definitions and field extraction functions.

Our disassembler class is remarkably small -- about 250 lines of hand-written C++. The heavy lifting is in `getInstruction()`:

```cpp
DecodeStatus Cpu0Disassembler::getInstruction(MCInst &Instr, uint64_t &Size,
                                              ArrayRef<uint8_t> Bytes,
                                              uint64_t Address,
                                              raw_ostream &CStream) const {
  uint32_t Insn;
  DecodeStatus Result;
  Result = readInstruction32(Bytes, Address, Size, Insn, IsBigEndian);
  if (Result == MCDisassembler::Fail)
    return MCDisassembler::Fail;

  // Calling the auto-generated decoder function.
  Result =
      decodeInstruction(DecoderTableCpu032, Instr, Insn, Address, this, STI);
  if (Result != MCDisassembler::Fail) {
    Size = 4;
    return Result;
  }
  return MCDisassembler::Fail;
}
```

Two things happen here. First, `readInstruction32()` reads 4 bytes from the input and assembles them into a 32-bit integer, respecting endianness:

```cpp
static DecodeStatus readInstruction32(ArrayRef<uint8_t> Bytes, uint64_t Address,
                                      uint64_t &Size, uint32_t &Insn,
                                      bool IsBigEndian) {
  if (Bytes.size() < 4) {
    Size = 0;
    return MCDisassembler::Fail;
  }
  if (IsBigEndian) {
    Insn =
        (Bytes[3] << 0) | (Bytes[2] << 8) | (Bytes[1] << 16) | (Bytes[0] << 24);
  } else {
    Insn =
        (Bytes[0] << 0) | (Bytes[1] << 8) | (Bytes[2] << 16) | (Bytes[3] << 24);
  }
  return MCDisassembler::Success;
}
```

Second, `decodeInstruction()` is entirely auto-generated. It's a table-driven state machine that walks the decoder table to match the instruction word. If it finds a match, it calls **decode functions** to populate the `MCInst` operands.

### Custom Decode Functions

The auto-generated decoder can extract bit fields, but it cannot interpret their meaning without target-specific helpers. The disassembler provides custom decoders for:

**Register decoding** -- The 4-bit register field is an index into a register table:

```cpp
static const unsigned CPURegsTable[] = {
    Cpu0::ZERO, Cpu0::AT, Cpu0::V0, Cpu0::V1, Cpu0::A0, Cpu0::A1,
    Cpu0::T9,   Cpu0::T0, Cpu0::T1, Cpu0::S0, Cpu0::S1, Cpu0::GP,
    Cpu0::FP,   Cpu0::SP, Cpu0::LR, Cpu0::SW};

static DecodeStatus DecodeCPURegsRegisterClass(MCInst &Inst, unsigned RegNo,
                                               uint64_t Address,
                                               const void *Decoder) {
  if (RegNo > 15)
    return MCDisassembler::Fail;
  Inst.addOperand(MCOperand::createReg(CPURegsTable[RegNo]));
  return MCDisassembler::Success;
}
```

**Memory operand decoding** -- Load/store instructions pack base register and offset into a single field:

```cpp
static DecodeStatus DecodeMem(MCInst &Inst, unsigned Insn, uint64_t Address,
                              const void *Decoder) {
  int Offset = SignExtend32<16>(Insn & 0xffff);
  int Reg = (int)fieldFromInstruction(Insn, 20, 4);
  int Base = (int)fieldFromInstruction(Insn, 16, 4);

  Inst.addOperand(MCOperand::createReg(CPURegsTable[Reg]));
  if (Inst.getOpcode() == Cpu0::SC) {
    Inst.addOperand(MCOperand::createReg(CPURegsTable[Reg]));
  }
  Inst.addOperand(MCOperand::createReg(CPURegsTable[Base]));
  Inst.addOperand(MCOperand::createImm(Offset));
  return MCDisassembler::Success;
}
```

Note the special case for `SC` (store-conditional): it needs two register operands because SC returns a success/fail result in the same register it stores.

**Branch target decoding** -- Branch instructions encode PC-relative offsets that need sign extension:

```cpp
static DecodeStatus DecodeBranch24Target(MCInst &Inst, unsigned Insn,
                                         uint64_t Address,
                                         const void *Decoder) {
  int BranchOffset = fieldFromInstruction(Insn, 0, 24);
  if (BranchOffset > 0x8fffff)
    BranchOffset = -1 * (0x1000000 - BranchOffset);
  Inst.addOperand(MCOperand::createReg(Cpu0::SW));
  Inst.addOperand(MCOperand::createImm(BranchOffset));
  return MCDisassembler::Success;
}
```

**JR/RET disambiguation** -- Perhaps the most interesting decoder is `DecodeJumpFR`, which distinguishes between `JR` (jump register) and `RET` (return) by checking whether the register is `$lr`:

```cpp
static DecodeStatus DecodeJumpFR(MCInst &Inst, unsigned Insn, uint64_t Address,
                                 const void *Decoder) {
  int Reg_a = (int)fieldFromInstruction(Insn, 20, 4);
  Inst.addOperand(MCOperand::createReg(CPURegsTable[Reg_a]));
  if (CPURegsTable[Reg_a] == Cpu0::LR)
    Inst.setOpcode(Cpu0::RET);
  else
    Inst.setOpcode(Cpu0::JR);
  return MCDisassembler::Success;
}
```

In the binary encoding, `RET` and `JR` have the same opcode. The disassembler uses a semantic heuristic: if you're jumping to `$lr`, it's a return. This is important because the assembly printer formats them differently (`ret $lr` vs `jr $t9`), and assembly-level tools need to understand the programmer's intent.

### Registering Both Endianness Variants

Cpu0 has two registered targets -- big-endian and little-endian -- and each gets its own disassembler factory:

```cpp
extern "C" void LLVMInitializeCpu0Disassembler() {
  TargetRegistry::RegisterMCDisassembler(getTheCpu0Target(),
                                         createCpu0Disassembler);
  TargetRegistry::RegisterMCDisassembler(getTheCpu0elTarget(),
                                         createCpu0elDisassembler);
}
```

The big-endian factory passes `bigEndian = true`, the little-endian factory passes `false`. The `readInstruction32()` function uses this flag to assemble bytes in the right order.

### The Decoder Table Structure

The `Cpu0GenDisassemblerTables.inc` file contains `DecoderTableCpu032` — a byte array encoding a decision tree. Each entry in the array is a "decoder opcode" followed by arguments. The machine starts at index 0 and walks the tree:

- `OPC_ExtractField 24, 8` — extract bits 24..31 (the opcode byte)
- `OPC_FilterValue 0x11, ...` — if opcode == 0x11, follow this branch (that's `addu`)
- `OPC_CheckField 12, 12, 0, ...` — verify that bits 12..23 (shamt field) are zero
- `OPC_TryDecodeOpcode 7, DecodeCPURegsRegisterClass` — decode the `ra` field (bits 20..23) as a CPU register
- `OPC_MorphNodeTo ...` — emit the `ADDu` instruction

The key insight: **the opcode byte drives the first level of dispatch**. Since Cpu0 uses 8-bit opcodes (bits 31-24), the decoder first extracts those 8 bits, then jumps to a subtable for that opcode. This is more efficient than checking every possible opcode sequentially.

Custom decode functions (like `DecodeMem`, `DecodeBranch24Target`) are wired into the table via `OPC_TryDecodeOpcode` entries. The table tells the decoder "use this function for operand N," and the function handles non-trivial field extraction.

---

## The Assembly Parser

The assembly parser reverses the printer: it takes text like `addiu $2, $3, 10` and produces an `MCInst`. The parser lives in `AsmParser/Cpu0AsmParser.cpp` and weighs in at about 1,000 lines.

### The Cpu0Operand Class

Before discussing parsing, it's worth understanding the `Cpu0Operand` class. Every parsed token becomes a `Cpu0Operand` — a discriminated union that can be a register, immediate, memory reference, or expression:

```cpp
// From Cpu0AsmParser.cpp
class Cpu0Operand : public MCParsedAsmOperand {
  enum KindTy { k_Immediate, k_Memory, k_Register, k_Token } Kind;

  struct MemOp {
    unsigned Base;    // Base register number
    const MCExpr *Off; // Offset expression
  };
  union {
    unsigned RegNum;   // For k_Register
    const MCExpr *Imm; // For k_Immediate
    MemOp Mem;         // For k_Memory
    StringRef Tok;     // For k_Token (mnemonic, .set keyword, etc.)
  };

public:
  bool isReg()    const override { return Kind == k_Register; }
  bool isImm()    const override { return Kind == k_Immediate; }
  bool isMem()    const override { return Kind == k_Memory; }
  bool isToken()  const override { return Kind == k_Token; }
};
```

The generated `MatchInstructionImpl()` checks operand kinds via these `isX()` predicates before deciding which instruction pattern matches. A memory operand (`k_Memory`) only matches instructions with memory addressing; an immediate (`k_Immediate`) only matches instructions with immediate fields.

### Architecture of the Parser

The parser is structured around four `override` methods that LLVM's framework calls:

| Method | Responsibility |
|--------|---------------|
| `ParseInstruction()` | Tokenize a line into mnemonic + operands |
| `MatchAndEmitInstruction()` | Match tokens to an instruction, emit to streamer |
| `ParseRegister()` | Parse a single register reference |
| `ParseDirective()` | Handle assembler directives (`.set`, `.ent`, etc.) |

### Operand Parsing

The `ParseOperand()` method handles the different syntactic forms Cpu0 assembly uses. The leading token determines the parse strategy:

- **`$` (dollar sign)**: Parse a register. Try `matchRegisterName()` first (handles names like `sp`, `fp`, `zero`, and aliases like `r2`, `r3`), then `matchRegisterByNumber()` (handles `$0` through `$15`):

```cpp
int Cpu0AsmParser::matchRegisterName(StringRef Name) {
  int CC;
  CC = StringSwitch<unsigned>(Name)
           .Case("zero", Cpu0::ZERO)
           .Case("at", Cpu0::AT)
           .Case("v0", Cpu0::V0)
           .Case("v1", Cpu0::V1)
           .Case("a0", Cpu0::A0)
           .Case("a1", Cpu0::A1)
           // ...
           .Case("sp", Cpu0::SP)
           .Case("lr", Cpu0::LR)
           // AsmName aliases (used by inline asm operand expansion)
           .Case("r1", Cpu0::AT)
           .Case("r2", Cpu0::V0)
           .Case("r3", Cpu0::V1)
           // ...
           .Default(-1);
  // ...
}
```

The `rN` aliases (r1, r2, etc.) are important for inline assembly support. Without them, code using `__asm__("addu $r2, $r3, $r2")` would fail to assemble.

- **`%` (percent sign)**: Parse a relocation expression like `%hi(symbol)` or `%lo(symbol)`. The parser dispatches through `evaluateRelocExpr()`, which maps strings to `Cpu0MCExpr` kinds:

```cpp
const MCExpr *Cpu0AsmParser::evaluateRelocExpr(const MCExpr *Expr,
                                               StringRef RelocStr) {
  Cpu0MCExpr::Cpu0ExprKind Kind =
      StringSwitch<Cpu0MCExpr::Cpu0ExprKind>(RelocStr)
          .Case("hi", Cpu0MCExpr::CEK_ABS_HI)
          .Case("lo", Cpu0MCExpr::CEK_ABS_LO)
          .Case("got", Cpu0MCExpr::CEK_GOT)
          .Case("tlsgd", Cpu0MCExpr::CEK_TLSGD)
          .Case("tp_hi", Cpu0MCExpr::CEK_TP_HI)
          .Case("tp_lo", Cpu0MCExpr::CEK_TP_LO)
          .Case("gottprel", Cpu0MCExpr::CEK_GOTTPREL)
          // ... 16 relocation types total
          .Default(Cpu0MCExpr::CEK_None);
  return Cpu0MCExpr::create(Kind, Expr, getContext());
}
```

- **Integer/identifier**: Parse an immediate value or a memory operand. If an integer is followed by `(`, it's a memory operand like `16($sp)`. The parser handles this in `parseMemOperand()`.

### MatchAndEmitInstruction: Where Matching Happens

After parsing operands, `MatchAndEmitInstruction()` calls the auto-generated `MatchInstructionImpl()` to find the instruction encoding:

```cpp
bool Cpu0AsmParser::MatchAndEmitInstruction(SMLoc IDLoc, unsigned &Opcode,
                                            OperandVector &Operands,
                                            MCStreamer &Out,
                                            uint64_t &ErrorInfo,
                                            bool MatchingInlineAsm) {
  MCInst Inst;
  unsigned MatchResult =
      MatchInstructionImpl(Operands, Inst, ErrorInfo, MatchingInlineAsm);
  switch (MatchResult) {
  case Match_Success: {
    if (needsExpansion(Inst)) {
      SmallVector<MCInst, 4> Instructions;
      expandInstruction(Inst, IDLoc, Instructions);
      for (unsigned i = 0; i < Instructions.size(); i++) {
        Out.emitInstruction(Instructions[i], getSTI());
      }
    } else {
      Inst.setLoc(IDLoc);
      Out.emitInstruction(Inst, getSTI());
    }
    return false;
  }
  case Match_MnemonicFail:
    return Error(IDLoc, "invalid instruction");
  // ... other error cases
  }
}
```

The critical detail: before emitting, the parser checks `needsExpansion()`. Some pseudo-instructions need to be expanded into multiple real instructions.

### Pseudo-Instruction Expansion

The parser handles three pseudo-instructions that don't correspond to real hardware instructions:

- **`li` (load immediate)** -- expands to 1 or 2 instructions depending on the value:
  - `0 <= val <= 65535`: `ori $rd, $zero, val`
  - `-32768 <= val < 0`: `addiu $rd, $zero, val`
  - Anything else: `lui $rd, hi16(val)` followed by `ori $rd, $rd, lo16(val)`

```cpp
void Cpu0AsmParser::expandLoadImm(MCInst &Inst, SMLoc IDLoc,
                                  SmallVectorImpl<MCInst> &Instructions) {
  int ImmValue = ImmOp.getImm();
  if (0 <= ImmValue && ImmValue <= 65535) {
    // li d,j => ori d,$zero,j
    tmpInst.setOpcode(Cpu0::ORi);
    tmpInst.addOperand(MCOperand::createReg(RegOp.getReg()));
    tmpInst.addOperand(MCOperand::createReg(Cpu0::ZERO));
    tmpInst.addOperand(MCOperand::createImm(ImmValue));
    Instructions.push_back(tmpInst);
  } else if (ImmValue < 0 && ImmValue >= -32768) {
    // li d,j => addiu d,$zero,j
    tmpInst.setOpcode(Cpu0::ADDiu);
    // ...
  } else {
    // li d,j => lui d,hi16(j)
    //           ori d,d,lo16(j)
    tmpInst.setOpcode(Cpu0::LUi);
    tmpInst.addOperand(MCOperand::createImm((ImmValue & 0xffff0000) >> 16));
    Instructions.push_back(tmpInst);
    tmpInst.clear();
    tmpInst.setOpcode(Cpu0::ORi);
    tmpInst.addOperand(MCOperand::createImm(ImmValue & 0xffff));
    Instructions.push_back(tmpInst);
  }
}
```

- **`la` (load address)** -- similar expansion, but can also handle a base register: `la $rd, offset($rs)`.
- **`LoadAddr32Reg`** -- the register-relative form with a possible 3-instruction expansion: `lui` + `ori` + `add`.

This is an important design pattern: the compiler never needs `li` or `la` because it generates real instructions directly. But human-written assembly uses these pseudo-instructions constantly, so the assembler must handle them.

---

## The Assembly Printer (MCInst to Text)

The printer is the simplest of the four components. `Cpu0InstPrinter.cpp` is under 100 lines, and most of the work is auto-generated in `Cpu0GenAsmWriter.inc`.

The printer delegates to auto-generated `printInstruction()` for the standard case, and provides a few callbacks for operand formatting:

```cpp
void Cpu0InstPrinter::printInst(const MCInst *MI, uint64_t Address,
                                StringRef Annot, const MCSubtargetInfo &STI,
                                raw_ostream &O) {
  if (!printAliasInstr(MI, Address, STI, O)) {
    printInstruction(MI, Address, STI, O);
  }
  printAnnotation(O, Annot);
}
```

`printAliasInstr()` handles instruction aliases (like printing `ret $lr` instead of `jr $lr`). If no alias applies, `printInstruction()` takes over.

The memory operand printer formats the MIPS-style `offset(base)` syntax:

```cpp
void Cpu0InstPrinter::printMemOperand(const MCInst *MI, unsigned OpNo,
                                      const MCSubtargetInfo &STI,
                                      raw_ostream &O) {
  printOperand(MI, OpNo + 1, STI, O);  // offset
  O << "(";
  printOperand(MI, OpNo, STI, O);      // base register
  O << ")";
}
```

Register names are lowercased with a `$` prefix:

```cpp
void Cpu0InstPrinter::printRegName(raw_ostream &OS, unsigned RegNo) const {
  OS << '$' << StringRef(getRegisterName(RegNo)).lower();
}
```

---

## Assembler Directives

Assembly files aren't just instructions -- they contain directives that control the assembler's behavior. Cpu0's parser handles these in `ParseDirective()`:

```cpp
bool Cpu0AsmParser::ParseDirective(AsmToken DirectiveID) {
  if (DirectiveID.getString() == ".ent") {
    Parser.Lex();  // ignore this directive for now
    return false;
  }
  if (DirectiveID.getString() == ".end") {
    Parser.Lex();
    return false;
  }
  if (DirectiveID.getString() == ".frame") {
    Parser.eatToEndOfStatement();
    return false;
  }
  if (DirectiveID.getString() == ".set") {
    return parseDirectiveSet();
  }
  if (DirectiveID.getString() == ".fmask") {
    Parser.eatToEndOfStatement();
    return false;
  }
  // ...
}
```

Most directives are consumed but ignored (`.ent`, `.end`, `.frame`, `.mask`, `.fmask`). These are emitted by the compiler for debugging/profiling tools, and the assembler needs to accept them without error, but they don't affect code generation.

The `.set` directive is different -- it controls assembler behavior at the source level:

| Directive | Effect |
|-----------|--------|
| `.set noreorder` | Disables instruction reordering |
| `.set reorder` | Re-enables reordering |
| `.set nomacro` | Disables pseudo-instruction expansion (requires `noreorder` first) |
| `.set macro` | Re-enables macro expansion |

```cpp
bool Cpu0AsmParser::parseSetNoMacroDirective() {
  // ...
  if (Options.isReorder()) {
    reportParseError("`noreorder' must be set before `nomacro'");
    return false;
  }
  Options.setNomacro();
  // ...
}
```

The constraint that `.set noreorder` must precede `.set nomacro` mirrors MIPS assembler behavior -- macro expansion may insert instructions (like NOP in delay slots), so disabling macros without disabling reordering would leave gaps.

---

## Registering the Parser in TableGen

The assembler parser and writer are registered in `Cpu0.td`, the top-level target description:

```tablegen
def Cpu0AsmParser : AsmParser {
  let ShouldEmitMatchRegisterName = 0;
}

def Cpu0AsmParserVariant : AsmParserVariant {
  int Variant = 0;
  string RegisterPrefix = "$";
}

def Cpu0AsmWriter : AsmWriter {
  int PassSubtarget = 1;
}

def Cpu0 : Target {
  let InstructionSet = Cpu0InstrInfo;
  let AssemblyWriters = [Cpu0AsmWriter];
  let AssemblyParsers = [Cpu0AsmParser];
  let AssemblyParserVariants = [Cpu0AsmParserVariant];
}
```

`ShouldEmitMatchRegisterName = 0` tells TableGen not to generate a register-matching function -- we provide our own `matchRegisterName()` that handles both canonical names (`sp`, `fp`) and `rN` aliases.

`RegisterPrefix = "$"` tells the generated matcher that register names start with `$`. `PassSubtarget = 1` on the writer means the `printOperand()` callbacks receive the `MCSubtargetInfo`, enabling subtarget-dependent printing if needed.

---

## The Round-Trip Test

Our test file `ch11-assembler.s` exercises the full round trip: feed assembly to `llvm-mc`, produce an object file, then disassemble it with `llvm-objdump`:

```asm
# RUN: llvm-mc -triple cpu0 -filetype=obj %s -o %t.o
# RUN: llvm-objdump -d %t.o | FileCheck %s
# RUN: llvm-mc -triple cpu0el -filetype=obj %s -o %t.el.o
# RUN: llvm-objdump -d %t.el.o | FileCheck %s
```

The same assembly is tested on both `cpu0` (big-endian) and `cpu0el` (little-endian), and both must produce the same disassembly. Here's a representative sample:

```asm
# Test ignored directives (.ent, .end, .frame, .mask, .fmask)
  .ent main
  .frame $sp, 8, $lr
  .mask 0x00000000, 0
  .fmask 0x00000000, 0
  .set noreorder
  .set nomacro

# --- Basic arithmetic/logic instructions ---

# CHECK: addiu $r2, $zero, 5
  addiu $2, $zero, 5

# CHECK: addu $r2, $r3, $r4
  addu $2, $3, $4

# --- Register by number ---

# CHECK: addiu $zero, $zero, 0
  addiu $0, $0, 0

# --- Register by AsmName (rN aliases used by inline asm) ---

# CHECK: addu $r2, $r3, $r2
  addu $r2, $r3, $r2
```

Notice that the input uses bare register numbers (`$2`, `$3`) while the CHECK patterns expect named registers (`$r2`, `$r3`). This is intentional -- the assembler accepts both forms, but the disassembler always outputs the canonical `rN` names. Both forms are tested to ensure the parser handles the full range of register syntax.

The test also covers pseudo-instruction expansion through the round trip:

```asm
# li small unsigned (0-65535) -> ori
# CHECK: ori $r2, $zero, 0
  li $2, 0

# li negative (-32768 to -1) -> addiu
# CHECK: addiu $r2, $zero, -1
  li $2, -1

# li large (needs lui+ori)
# CHECK: lui $r2, 4660
# CHECK-NEXT: ori $r2, $r2, 22136
  li $2, 0x12345678
```

And relocation expressions:

```asm
# CHECK: lui $r2
  lui $2, %hi(symbol)

# CHECK: ori $r2, $r2
  ori $2, $2, %lo(symbol)
```

---

## Gotcha: Cpu0 Uses `#` as Its Comment Character

This caught us: Cpu0 defines `#` as its comment string in `Cpu0MCAsmInfo.cpp`:

```cpp
Cpu0MCAsmInfo::Cpu0MCAsmInfo(const Triple &TheTriple) {
  // ...
  CommentString = "#";
  // ...
}
```

This means **assembly test files must use `# RUN:` and `# CHECK:`, not `; RUN:` and `; CHECK:`**. If you use `;`, `llvm-mc` will try to parse those lines as instructions and fail with cryptic errors.

This is different from most LLVM backends (ARM, x86, MIPS) where `;` or `//` serve as comment characters. It's especially confusing because `.ll` files (LLVM IR) use `;` for comments, so switching between IR tests and assembly tests requires switching comment syntax.

The rule: `.ll` files use `; RUN:`. Assembly `.s` files for Cpu0 use `# RUN:`.

---

## How the Pieces Connect

Here's the complete data flow for the round trip:

```
Source assembly (.s)
        |
   [Cpu0AsmParser]
        |
     MCInst
        |
   [Cpu0MCCodeEmitter]
        |
  Binary bytes (.o)
        |
   [Cpu0Disassembler]
        |
     MCInst
        |
   [Cpu0InstPrinter]
        |
Disassembled text
```

`MCInst` is the pivot point -- it's the common representation that all four components speak. An `MCInst` is just an opcode plus a vector of `MCOperand`s (registers, immediates, or expressions). It carries no semantics -- it's purely syntactic. The encoder knows how to pack it into bits; the decoder knows how to unpack bits into it; the printer knows how to format it as text; the parser knows how to construct it from text.

This design means that adding a new instruction to the backend requires:

1. Add the `.td` definition (format, opcode, operands, asm string)
2. Rebuild (regenerates all four `.inc` files)
3. Add custom decode functions if the instruction has non-trivial operand encoding

Most instructions require only step 1 and 2. Custom decoders are only needed for operands that cannot be extracted by simple bit-field slicing -- memory operands, branch targets with sign extension, and the JR/RET disambiguation we saw earlier.

There's also an important asymmetry between the encoder and decoder paths: the encoder operates on `MCInst` objects that were *constructed* by the compiler (or AsmParser) and are therefore always well-formed. The decoder operates on *arbitrary* bit patterns from a binary file, and must gracefully handle invalid encodings. This is why the disassembler has explicit `Fail` paths (returning `MCDisassembler::Fail`) in its decode tables, while the encoder can use `llvm_unreachable` for impossible cases.

The `MCInst`'s simplicity — just an opcode integer and a list of operands — is deliberate. It has no knowledge of instruction scheduling, register allocation, stack frames, or optimization. It's the lowest-level representation that's still target-specific enough to be encoded, and target-independent enough to be shared across all four tools.

---

## Further Reading

- [MC Design & Implementation](https://blog.llvm.org/2010/04/intro-to-llvm-mc-project.html) -- The original blog post introducing LLVM's MC layer
- [Writing an LLVM Backend](https://llvm.org/docs/WritingAnLLVMBackend.html) -- Assembler and disassembler registration
- [TableGen Programmer's Reference](https://llvm.org/docs/TableGen/ProgRef.html) -- `Inst{}` bit-field syntax
- [LLVM Code Generator](https://llvm.org/docs/CodeGenerator.html) -- MCInst, AsmPrinter, and the MC pipeline

---

*Previous: [Post 5 — Control Flow, Branches, and the Passes That Clean Up After You](05-control-flow.md)*

*Next up: [Post 7 — Closing the Loop: C++ Features, Atomics, and Verifying on a Verilog CPU](07-closing-the-loop.md)*
