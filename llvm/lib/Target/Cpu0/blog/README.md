# Building an LLVM Backend From Scratch

A 9-part blog series using the **Cpu0** architecture as a case study to explore LLVM's backend architecture. Based on a complete implementation: 16 commits, 12,260 lines of code, 72 files, verified on a Verilog RTL simulator.

**Target**: LLVM 15.0.7 | **Architecture**: 32-bit RISC, 16 GPRs, 2 ISA variants, 2 endianness targets

---

## The Series

### [1. The Anatomy of an LLVM Backend](01-anatomy.md)
What 72 files and 12,000 lines actually do. The Cpu0 ISA, LLVM's backend pipeline, the SE subclass pattern, and how TableGen drives everything.

### [2. From IR to Machine Instructions: How SelectionDAG Actually Works](02-selectiondag.md)
Tracing `add(a, b)` through every DAG stage. TableGen patterns, custom lowering with `setOperationAction`, complex patterns like `SelectAddr`, and debugging tips.

### [3. Stack Frames, Calling Conventions, and the ABI](03-calling-conventions.md)
Prologue/epilogue emission, the O32 calling convention in TableGen, `LowerCall` and `LowerFormalArguments`, varargs, and PIC vs static call sequences.

### [4. The MC Layer: From Abstract Instructions to Real Bytes](04-mc-layer.md)
The dual-use MC abstraction. MCInst lowering, the code emitter with endianness handling, fixups and relocations, ELF object file anatomy, and the MCExpr system.

### [5. Control Flow, Branches, and the Passes That Clean Up After You](05-control-flow.md)
CMP vs SLT comparison strategies, conditional moves, jump tables, and the three pre-emit cleanup passes: useless jump removal, delay slot filling, and long branch expansion.

### [6. Round-Tripping: Building an Assembler and Disassembler](06-assembler-disassembler.md)
The round-trip property. Table-driven disassembly, the AsmParser, operand parsing, assembly directives, and TableGen as a single source of truth for four consumers.

### [7. Closing the Loop: C++ Features, Atomics, and Verifying on a Verilog CPU](07-closing-the-loop.md)
Exception handling, four TLS models, LL/SC atomic loops, sub-word atomics with byte masking. War stories: the NOR-not-XOR bug and the SetCC_I encoding bug. Verilog RTL verification across 4 configurations.

### [8. Global Variables, Relocations, and Position-Independent Code](08-globals-relocations.md)
Four global addressing modes, the 17 relocation types, `%hi`/`%lo` linker pairing, small-data sections (`.sdata`/`.sbss`), and GP-relative optimization.

### [9. Under the Hood: Custom SDNodes, Type Legalization, and Backend Internals](09-internals.md)
The 15 custom `Cpu0ISD` nodes, type legalization for a 32-bit-only target, the `Cpu0AnalyzeImmediate` DP algorithm, per-function metadata, MC component registration, and scheduling itineraries.

---

## Quick Stats

| Metric | Value |
|--------|-------|
| Total backend code | 12,260 lines across 72 files |
| TableGen definitions | 11 `.td` files (1,583 lines) |
| C++ implementation | 61 files (10,677 lines) |
| Lit regression tests | 17 test files |
| Relocation types | 17 |
| Custom SDNodes | 15 |
| ISA variants | 2 (Cpu032I / Cpu032II) |
| Endianness targets | 2 (big / little) |
| Verilog test programs | 23 |
| Blog series word count | ~26,000 words |

## LLVM Reference Documentation

- [Writing an LLVM Backend](https://llvm.org/docs/WritingAnLLVMBackend.html)
- [The LLVM Target-Independent Code Generator](https://llvm.org/docs/CodeGenerator.html)
- [TableGen Overview](https://llvm.org/docs/TableGen/)
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html)
- [Exception Handling in LLVM](https://llvm.org/docs/ExceptionHandling.html)
- [LLVM Atomics](https://llvm.org/docs/Atomics.html)
- [LLVM Testing Guide](https://llvm.org/docs/TestingGuide.html)
