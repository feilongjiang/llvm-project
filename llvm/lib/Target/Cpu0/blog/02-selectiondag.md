# From IR to Machine Instructions: How SelectionDAG Actually Works

*Part 2 of "Building an LLVM Backend From Scratch" — dissecting LLVM's instruction selection framework through the Cpu0 backend.*

---

## The Heart of the Backend

If Post 1 was the anatomy lesson, this post is the cardiology. **SelectionDAG instruction selection** is where LLVM IR becomes machine instructions. It's the most complex subsystem in any backend, and the one that most developers find confusing.

We'll make it concrete by tracing real code through every stage, showing the actual debug output from our Cpu0 backend, and explaining the three mechanisms that make it work: TableGen patterns, custom lowering, and complex patterns.

---

## A Simple Example: Tracing `add` Through the DAG

Let's start with the simplest possible function and trace it through every stage:

```llvm
define i32 @add(i32 %a, i32 %b) {
  %c = add i32 %a, %b
  ret i32 %c
}
```

Running `llc -march=cpu0 -relocation-model=pic -debug` reveals the DAG at each stage. Understanding what happens at each stage is the key to debugging instruction selection problems.

### Stage 1: Initial SelectionDAG

LLVM first builds a target-independent DAG from the IR:

```
Initial selection DAG: %bb.0 'add:'
SelectionDAG has 9 nodes:
  t0: ch = EntryToken
      t2: i32,ch = CopyFromReg t0, Register:i32 %0
      t4: i32,ch = CopyFromReg t0, Register:i32 %1
    t5: i32 = add t2, t4
  t7: ch,glue = CopyToReg t0, Register:i32 $v0, t5
  t8: ch = Cpu0ISD::Ret t7, Register:i32 $v0, t7:1
```

Reading this: `t2` and `t4` copy function arguments from virtual registers. `t5` is the generic `add` node. `t7` copies the result to `$v0` (the return register). `t8` is the custom `Cpu0ISD::Ret` node — more on custom nodes later.

Notice that `Cpu0ISD::Ret` already appears in the *initial* DAG. This is because `Cpu0ISelLowering::LowerReturn()` is called during DAG construction to lower the `ret` IR instruction into a target-specific return node.

### Stage 2: Type Legalization

Before instruction selection, the **type legalizer** transforms the DAG so every value has a type the target can handle. Cpu0 only supports `i32` natively, so:

- `i1` comparison results → **promoted** to `i32` (Cpu0 has no 1-bit ALU)
- `i8`/`i16` loaded values → **sign/zero-extended** to `i32`
- `SIGN_EXTEND_INREG` on sub-word types → **expanded** to `shl`/`sra` pairs
- `i64` operations → **not supported** (no 64-bit hardware)

For our `add(a, b)` example, both arguments are already `i32`, so type legalization is a no-op. The DAG is unchanged after this stage.

### Stage 3: DAG Combining (Round 1)

LLVM's DAG combiner runs algebraic simplifications. For our simple `add`, there's nothing to simplify, but for more complex expressions you'd see things like:

- `(add x, 0)` → `x` (identity elimination)
- `(mul x, 2)` → `(shl x, 1)` (strength reduction)
- `(and (shr x, 24), 0xff)` → `(zextload i8)` (combined load-and-shift)

These transforms happen in `DAGCombiner.cpp` in LLVM core — your backend doesn't implement them, but it benefits from them. The combiner runs twice: once before operation legalization (when it has access to the full IR semantics) and once after (when it only sees legal operations).

### Stage 4: Operation Legalization

The **operation legalizer** ensures every operation is valid for the target. This is where `setOperationAction` decisions take effect. For `add(a, b)`:

- `ISD::ADD` on `i32` is `Legal` — passes through unchanged
- The `ISD::RETURNADDR` (implicit in the ret) is `Custom` — `lowerRETURNADDR()` is called
- Any `ISD::BRCOND` or `ISD::GlobalAddress` nodes would be dispatched to `LowerOperation()` here

After this stage, the DAG contains only Legal operations — no Custom or Expand nodes remain.

### Stage 5: Pattern Matching (Instruction Selection)

Now LLVM's generated matcher walks each node and tries to find a matching instruction pattern. Here's the debug output for the `add` node:

```
ISEL: Starting selection on root node: t5: i32 = add t2, t4
ISEL: Starting pattern match
  Initial Opcode index to 1409
  Match failed at index 1413
  Continuing at 1502
  Match failed at index 1504
  Continuing at 1598
  Match failed at index 1604
  Continuing at 1620
  Morphed node: t5: i32 = ADDu t2, t4
ISEL: Match complete!
```

The matcher tried several patterns (at indices 1409, 1502, 1598, 1604) before finding a match at 1620 — the `ADDu` instruction. The generic `add` node was **morphed** into a machine-specific `ADDu` node.

The index numbers refer to positions in the generated match table in `Cpu0GenDAGISel.inc`. This table is a decision tree encoded as an array of opcodes. Each entry is one of: `OPC_CheckOpcode` (filter by node type), `OPC_CheckType` (filter by value type), `OPC_MorphNodeTo` (emit instruction). The failures at 1413, 1504, 1604 are for more specific patterns (e.g., add-with-carry, add-immediate) that don't match; falling through to 1620 reaches the generic register-register add.

### Stage 6: Scheduling and MachineInstr Emission

After selection, the DAG is linearized into a sequence of `MachineInstr` objects. LLVM's scheduler reorders instructions to minimize pipeline stalls based on the itinerary data in `Cpu0Schedule.td`. For `add(a, b)`, there's only one instruction, so scheduling is trivial.

For a more complex function, the scheduler would try to interleave independent instructions. For example, if a load has a 3-cycle latency (as specified in `Cpu0Schedule.td`), the scheduler would try to place 2 independent instructions between the load and its first use. The Cpu0 itinerary defines this for `IILoad`.

### The Final Assembly

After scheduling, virtual registers get physical register assignments from the register allocator, then the `AsmPrinter` converts `MachineInstr` to `MCInst` via `Cpu0MCInstLower`, and finally `Cpu0InstPrinter` renders the text:

```asm
addu	$r2, $r4, $r5
ret	$lr
nop
```

Arguments in `$r4` (A0) and `$r5` (A1), result in `$r2` (V0). Clean and simple.

```
Stage 1: Initial DAG          Stage 2: Legalized            Stage 3: Selected             Stage 4: MachineInstr

   CopyFromReg(a)                CopyFromReg(a:i32)            CopyFromReg(%0:i32)          %0 = COPY $a0
        │                             │                              │                      %1 = COPY $a1
   CopyFromReg(b)                CopyFromReg(b:i32)            CopyFromReg(%1:i32)          %2 = ADDu %0, %1
        │         \                   │          \                   │          \           $v0 = COPY %2
    ISD::ADD       ──────▶        ISD::ADD        ──────▶        ADDu            ──────▶
        │                             │                              │
   CopyToReg(ret)              CopyToReg(ret:i32)            CopyToReg($v0)
```

---

## Mechanism 1: TableGen Patterns

The most common way to define instruction selection is through **TableGen patterns**. You declare an instruction and embed its matching pattern:

```tablegen
// From Cpu0InstrInfo.td

class ArithLogicR<bits<8> op, string instrAsm, SDNode opNode,
                  InstrItinClass itin, RegisterClass RC, bit isComm = 0>
  : FA<op, (outs GPROut:$ra), (ins RC:$rb, RC:$rc),
       !strconcat(instrAsm, "\t$ra, $rb, $rc"),
       [(set GPROut:$ra, (opNode RC:$rb, RC:$rc))], itin> {
  let shamt = 0;
  let isCommutable = isComm;
  let isReMaterializable = 1;
}
```

This declares a Format A instruction class where:
- `op` is the 8-bit opcode
- The pattern `[(set GPROut:$ra, (opNode RC:$rb, RC:$rc))]` says: "match any DAG node of type `opNode` with two register operands, and produce a register result"

The actual instruction is then one line:

```tablegen
def ADDu  : ArithLogicR<0x11, "addu", add, IIAlu, CPURegs, 1>;
```

This says: opcode `0x11`, assembly mnemonic `addu`, matches the `add` SDNode, uses the ALU itinerary, and is commutable (meaning `add a, b = add b, a`, which helps the register allocator).

During the build, TableGen processes this definition and generates matching code in `Cpu0GenDAGISel.inc`. The generated code is a table-driven matcher that the `SelectCode()` method uses to walk the DAG. This is why the debug output shows index numbers (1409, 1502, etc.) — those are positions in the generated match table.

### More Arithmetic Instructions

The same multiclass pattern gives us the entire ALU:

```tablegen
def ADDu  : ArithLogicR<0x11, "addu", add, IIAlu, CPURegs, 1>;
def SUBu  : ArithLogicR<0x12, "subu", sub, IIAlu, CPURegs>;
def MUL   : ArithLogicR<0x17, "mul",  mul, IIImul, CPURegs, 1>;
def AND   : ArithLogicR<0x18, "and",  and, IIAlu, CPURegs, 1>;
def OR    : ArithLogicR<0x19, "or",   or,  IIAlu, CPURegs, 1>;
def XOR   : ArithLogicR<0x1A, "xor",  xor, IIAlu, CPURegs, 1>;
```

Each definition: one line, one instruction. The pattern matching, encoding, assembly printing, and disassembly decoding are all generated automatically from this single definition.

```
Cpu0InstrInfo.td                    TableGen compiler           Cpu0GenDAGISel.inc (generated)
─────────────────                   ─────────────────           ──────────────────────────────
def ADDu : ArithLogicR<
  0x11, "addu", add, IIAlu>;             ══════▶             case ISD::ADD: {
                                                                if (N.getVT() == MVT::i32) {
def : Pat<(add CPURegs:$ra,                                       SDValue N0 = N.getOperand(0);
              CPURegs:$rb),                                       SDValue N1 = N.getOperand(1);
         (ADDu CPURegs:$ra,                                       return Select_ADDu(N0, N1);
               CPURegs:$rb)>;                                   }
                                                              }
```

---

## Under the Hood: What TableGen Actually Generates

When you write `def ADDu : ArithLogicR<0x11, "addu", add, IIAlu, CPURegs, 1>`, TableGen produces a function in `Cpu0GenDAGISel.inc` that `SelectCode()` calls. The generated code is a giant state machine encoded as a byte array. Here's a simplified view of what the match for `add` looks like:

```cpp
// From Cpu0GenDAGISel.inc (auto-generated, simplified for clarity)
// OPCODE_TABLE: decision tree for SelectCode()

// At index 1409: try to match add with shift
//   OPC_SwitchOpcode: is this ISD::ADD?
//   OPC_CheckChild1Type: is operand 0 i32?
//   OPC_CheckChild2Type: is operand 1 i32?
//   OPC_CheckComplexPat: try SelectAddr? (for fused load-add)
//   → fail, continue

// At index 1620: match basic register-register add
//   OPC_SwitchOpcode: ISD::ADD
//   OPC_CheckType: MVT::i32
//   OPC_RecordNode: record matched node
//   OPC_RecordChild0: record operand 0 as "rb"
//   OPC_RecordChild1: record operand 1 as "rc"
//   OPC_MorphNodeTo1: emit ADDu node, result type i32
```

The opcodes (`OPC_SwitchOpcode`, `OPC_CheckType`, `OPC_RecordChild`) are defined in `SelectionDAGISel.cpp` and form a bytecode interpreter. The `OPC_MorphNodeTo1` instruction causes the current DAG node to be transformed into a machine node with the given opcode.

Entries appear from most-specific to least-specific. The matcher tries the specific patterns first (add-with-immediate, add-as-part-of-load-address, add-with-shift) and falls through to the generic register-register add last. That's why the debug output shows several "Match failed" messages before finally matching.

The generated function has a constant prefix:

```cpp
SDNode *Cpu0DAGToDAGISel::SelectCode(SDNode *N) {
#define TARGET_VAL(X) X, X >> 8
  static const unsigned char MatcherTable[] = {
    /* 0 */ OPC_SwitchOpcode /*195 cases*/, ...
    /* 1409 */ OPC_CheckOpcode, TARGET_VAL(ISD::ADD), ...
    /* 1620 */ OPC_MorphNodeTo1, TARGET_VAL(Cpu0::ADDu), ...
    ...
  };
  return SelectCodeCommon(N, MatcherTable, sizeof(MatcherTable));
}
```

`SelectCodeCommon` is defined in LLVM core (`SelectionDAGISel.cpp`) and executes the table. Your backend never writes a loop over opcodes — the entire instruction selection logic is expressed declaratively in `.td` files and executed by this interpreter.

One important implication: **the order of pattern definitions matters.** If two patterns can match the same node, the first one wins. This is why immediate-form patterns (like `addiu $r, $r, imm`) typically appear before register-form patterns (`addu $r, $r, $r`) in the TableGen file — the immediate form is more specific and should be tried first.

---

## BRCOND Lowering: ISA Variant Dispatch

`ISD::BRCOND` is marked `Custom`, but the `lowerBRCOND` implementation is deliberately minimal:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::lowerBRCOND(SDValue Op, SelectionDAG &DAG) const {
  return Op;
}
```

It does nothing — it returns the node unchanged. The reason `BRCOND` is `Custom` at all is to prevent the legalizer from trying to expand or otherwise transform it; returning `Op` passes it through to the **TableGen pattern matcher**, which is where the actual CMP-vs-SLT dispatch happens.

The CMP-vs-SLT design is expressed entirely in `Cpu0InstrInfo.td` through two pattern multiclasses gated by subtarget predicates:

```tablegen
// Cpu032I path: CMP sets $sw, then Jxx tests $sw
multiclass BrcondPatsCmp<...> {
  def : Pat<(brcond (i32 (seteq RC:$lhs, RC:$rhs)), bb:$dst),
            (JEQOp (CMPOp RC:$lhs, RC:$rhs), bb:$dst)>;
  def : Pat<(brcond (i32 (setlt RC:$lhs, RC:$rhs)), bb:$dst),
            (JLTOp (CMPOp RC:$lhs, RC:$rhs), bb:$dst)>;
  // ... JNE, JGT, JLE, JGE variants
}

// Cpu032II path: SLT writes 0/1 to a GPR, BEQ/BNE tests it
multiclass BrcondPatsSlt<...> {
  def : Pat<(brcond (i32 (seteq RC:$lhs, RC:$rhs)), bb:$dst),
            (BEQOp RC:$lhs, RC:$rhs, bb:$dst)>;
  def : Pat<(brcond (i32 (setlt RC:$lhs, RC:$rhs)), bb:$dst),
            (BNE (SLTOp RC:$lhs, RC:$rhs), ZERO, bb:$dst)>;
  // ... seteq/setne/setlt/setgt/setle/setge variants
}

let Predicates = [HasCmp] in
  defm : BrcondPatsCmp<CPURegs, JEQ, JNE, JLT, JGT, JLE, JGE, CMP, CMPu, ZERO>;
let Predicates = [HasSlt] in
  defm : BrcondPatsSlt<CPURegs, BEQ, BNE, SLT, SLTu, SLTi, SLTiu, ZERO>;
```

The key insight: in Cpu032I (`HasCmp`), a conditional like `if (a < b)` compiles to `CMP $sw, $a, $b` followed by `JLT target` — the branch reads the implicit status register `$sw`. In Cpu032II (`HasSlt`), it compiles to `SLT $t, $a, $b` followed by `BNE $t, $zero, target` — the branch reads an ordinary GPR.

In terms of DAG nodes:
- **Cpu032I path**: `brcond(setlt(a,b), dst)` → `JLT(CMP(a,b), dst)` — two machine instructions
- **Cpu032II path**: `brcond(setlt(a,b), dst)` → `BNE(SLT(a,b), ZERO, dst)` — two machine instructions

The `Requires<[HasCmp]>` and `Requires<[HasSlt]>` predicates gate which set of patterns fires during instruction selection. Both ISA variants' patterns live in the same `.td` file, but only the active variant's patterns are visible to the matcher.

We'll examine this in full detail in [Post 5: Control Flow](05-control-flow.md), where the CMP vs SLT branch sequence is shown side by side.

---

## Mechanism 2: Custom Lowering

TableGen patterns handle the common case — when an IR operation maps directly to a machine instruction. But many operations require custom C++ logic. That's where `setOperationAction` comes in.

```
ISD opcode arrives at legalizer
          │
          ▼
    ┌─────────┐    Yes   ┌─────────────────────────────────┐
    │ Legal?  │─────────▶│ Emit directly (e.g. add → ADDu) │
    └─────────┘          └─────────────────────────────────┘
          │ No
          ▼
    ┌─────────┐    Yes   ┌─────────────────────────────────┐
    │ Custom? │─────────▶│ Call LowerOperation()           │
    └─────────┘          │ (e.g. GlobalAddress → Hi/Lo)    │
          │ No           └─────────────────────────────────┘
          ▼
    ┌─────────┐    Yes   ┌─────────────────────────────────┐
    │ Expand? │─────────▶│ LLVM breaks into simpler ops    │
    └─────────┘          │ (e.g. SDIVREM → SDIV + SREM)    │
          │ No           └─────────────────────────────────┘
          ▼
    ┌───────────────────────────────────┐
    │ Promote to wider type             │
    │ (e.g. i1 setcc → promoted to i32) │
    └───────────────────────────────────┘
```

### The setOperationAction Decision Tree

In `Cpu0ISelLowering.cpp`, the constructor declares how each ISD opcode should be handled:

```cpp
// From Cpu0ISelLowering.cpp — the constructor

// These operations need custom C++ lowering
setOperationAction(ISD::GlobalAddress,    MVT::i32, Custom);
setOperationAction(ISD::GlobalTLSAddress, MVT::i32, Custom);
setOperationAction(ISD::BlockAddress,     MVT::i32, Custom);
setOperationAction(ISD::JumpTable,        MVT::i32, Custom);
setOperationAction(ISD::BRCOND,           MVT::Other, Custom);
setOperationAction(ISD::SELECT,           MVT::i32, Custom);
setOperationAction(ISD::VASTART,          MVT::Other, Custom);
setOperationAction(ISD::EH_RETURN,        MVT::Other, Custom);
setOperationAction(ISD::ADD,              MVT::i32, Custom);
setOperationAction(ISD::ATOMIC_FENCE,     MVT::Other, Custom);

// These operations should be broken into simpler operations by LLVM
setOperationAction(ISD::SDIV, MVT::i32, Expand);
setOperationAction(ISD::SREM, MVT::i32, Expand);
setOperationAction(ISD::UDIV, MVT::i32, Expand);
setOperationAction(ISD::UREM, MVT::i32, Expand);

// Sign extension in register — expanded to shl/sra pair
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i1,  Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i8,  Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i16, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i32, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::Other, Expand);
```

Every ISD opcode can be in one of four states:

| Action | Meaning | Example |
|--------|---------|---------|
| **Legal** | The target handles this natively. No transformation needed. | `ISD::SHL` on `i32` (handled by `SHL` pattern) |
| **Custom** | The target provides a C++ `LowerOperation()` method. | `ISD::GlobalAddress` → `lowerGlobalAddress()` |
| **Expand** | LLVM automatically breaks this into simpler legal operations. | `ISD::SDIV` → expands to `SDIVREM`, DAG-combined to hardware `div` (Cpu0 has no `__divsi3` call) |
| **Promote** | LLVM widens the type to a legal one. | `ISD::SETCC` on `i1` → promoted to `i32` |

An interesting subtlety: `ISD::ADD` is marked `Custom` *and* matched by the `ADDu` pattern. The custom lowering for ADD handles a special case: when the ADD is used with the global pointer (`$gp`) for PIC addressing. For ordinary integer addition, the custom lowering returns an empty `SDValue()`, which tells LLVM to fall through to pattern matching. This is a common idiom: mark an operation `Custom`, handle the special case in `lower*()`, and return an empty `SDValue()` for the general case to let pattern matching handle it.

Here's a concrete example of each action category for Cpu0:

| Operation | Type | Action | Reason |
|-----------|------|--------|--------|
| `ISD::ADD` | `i32` | Custom (fallback to Legal) | Special-case PIC GP construction |
| `ISD::GlobalAddress` | `i32` | Custom | Multi-step Hi/Lo/GOT sequence |
| `ISD::BRCOND` | Other | Custom | Prevent legalizer interference; actual dispatch via TableGen `BrcondPatsCmp`/`BrcondPatsSlt` patterns |
| `ISD::SELECT` | `i32` | Custom | Lower to MOVZ/MOVN conditional moves |
| `ISD::SDIV` | `i32` | Expand | Expands to `SDIVREM`, DAG-combined to `div` + `mflo` |
| `ISD::SREM` | `i32` | Expand | Remainder via same `div` + `mfhi` |
| `ISD::SIGN_EXTEND_INREG` | `i8` | Expand | No sub-word sign-extend; becomes `SHL 24 / SRA 24` |
| `ISD::SETCC` | `i1` | Promote to `i32` | No 1-bit result register |
| `ISD::SHL`, `SRL`, `SRA` | `i32` | Legal | Direct `SHL`/`SRL`/`SRA` instructions |

### The LowerOperation Dispatch

When SelectionDAG encounters a `Custom` operation during legalization, it calls `LowerOperation()`:

```cpp
SDValue Cpu0TargetLowering::LowerOperation(SDValue Op,
                                           SelectionDAG &DAG) const {
  switch (Op.getOpcode()) {
  case ISD::BRCOND:           return lowerBRCOND(Op, DAG);
  case ISD::GlobalAddress:    return lowerGlobalAddress(Op, DAG);
  case ISD::BlockAddress:     return lowerBlockAddress(Op, DAG);
  case ISD::JumpTable:        return lowerJumpTable(Op, DAG);
  case ISD::SELECT:           return lowerSELECT(Op, DAG);
  case ISD::VASTART:          return lowerVASTART(Op, DAG);
  case ISD::FRAMEADDR:        return lowerFRAMEADDR(Op, DAG);
  case ISD::RETURNADDR:       return lowerRETURNADDR(Op, DAG);
  case ISD::EH_RETURN:        return lowerEH_RETURN(Op, DAG);
  case ISD::ADD:              return lowerADD(Op, DAG);
  case ISD::GlobalTLSAddress: return lowerGlobalTLSAddress(Op, DAG);
  case ISD::ATOMIC_FENCE:     return lowerATOMIC_FENCE(Op, DAG);
  }
  return SDValue();
}
```

Each `lower*()` method replaces the generic ISD node with a sequence of target-specific nodes. For example, `lowerGlobalAddress()` replaces `ISD::GlobalAddress` with a sequence of `Cpu0ISD::Hi`, `Cpu0ISD::Lo`, or `Cpu0ISD::Wrapper` nodes depending on the relocation model — we'll explore this in detail in [Post 8: Globals & Relocations](08-globals-relocations.md).

---

## A More Complex Example: Loading a Global Variable

Let's trace a global variable access to see custom lowering in action:

```llvm
@g = external global i32
define i32 @load_global() {
  %v = load i32, i32* @g
  ret i32 %v
}
```

The DAG debug shows what happens:

```
ISEL: Starting pattern match
  Morphed node: t9: i32 = LUi TargetGlobalAddress:i32<i32* @g> [TF=6]
ISEL: Starting pattern match
  Morphed node: t11: i32 = ADDu t9, Register:i32 $gp
ISEL: Starting pattern match
  Morphed node: t14: i32,ch = LD ... t11, TargetGlobalAddress:i32<i32* @g> [TF=7]
ISEL: Starting pattern match
  Morphed node: t4: i32,ch = LD ... t14, TargetConstant:i32<0>
```

Reading bottom-to-top, the instruction sequence is:
1. `LUi %hi(@g)` — load upper 16 bits of GOT offset
2. `ADDu $gp` — add to global pointer to get GOT entry address
3. `LD` from GOT — load the actual address of `@g`
4. `LD` from address — load the value of `@g`

This 4-instruction sequence was produced by `lowerGlobalAddress()`, which chose the "large GOT" addressing mode for PIC code. The `TF=6` and `TF=7` are target flags indicating `%got_hi16` and `%got_lo16` relocation types.

None of this could be expressed as a simple TableGen pattern — it requires C++ logic to examine the relocation model, GOT size, and symbol properties.

---

## Mechanism 3: Complex Patterns

Between simple patterns and full custom lowering, there's a middle ground: **complex patterns**. These are C++ methods that participate in TableGen pattern matching.

The most important one in Cpu0 is `SelectAddr`, which matches memory address operands:

```cpp
// From Cpu0ISelDAGToDAG.cpp

bool Cpu0DAGToDAGISel::SelectAddr(SDNode *Parent, SDValue Addr,
                                  SDValue &Base, SDValue &Offset) {
  EVT ValTy = Addr.getValueType();
  SDLoc DL(Addr);

  // Case 1: Frame index — local variable on the stack
  if (FrameIndexSDNode *FIN = dyn_cast<FrameIndexSDNode>(Addr)) {
    Base = CurDAG->getTargetFrameIndex(FIN->getIndex(), ValTy);
    Offset = CurDAG->getTargetConstant(0, DL, ValTy);
    return true;
  }

  // Case 2: Wrapper node — GOT/PIC address
  if (Addr.getOpcode() == Cpu0ISD::Wrapper) {
    Base = Addr.getOperand(0);
    Offset = Addr.getOperand(1);
    return true;
  }

  // Case 3: Base + constant offset (e.g., struct field access)
  if (CurDAG->isBaseWithConstantOffset(Addr)) {
    ConstantSDNode *CN = dyn_cast<ConstantSDNode>(Addr.getOperand(1));
    if (isInt<16>(CN->getSExtValue())) {
      // Offset fits in 16-bit immediate field
      if (FrameIndexSDNode *FIN =
              dyn_cast<FrameIndexSDNode>(Addr.getOperand(0)))
        Base = CurDAG->getTargetFrameIndex(FIN->getIndex(), ValTy);
      else
        Base = Addr.getOperand(0);
      Offset = CurDAG->getTargetConstant(CN->getZExtValue(), DL, ValTy);
      return true;
    }
  }

  // Case 4: Fallback — use the address as base, offset 0
  Base = Addr;
  Offset = CurDAG->getTargetConstant(0, DL, ValTy);
  return true;
}
```

This method is referenced from TableGen via a `ComplexPattern` definition, so that load/store patterns can write:

```tablegen
def addr : ComplexPattern<iPTR, 2, "SelectAddr", [frameindex], [SDNPWantParent]>;

// Then in a load instruction pattern:
def LD : LoadM32<0x01, "ld", load_a>;  // uses addr pattern internally
```

When the matcher encounters a load instruction, it calls `SelectAddr()` to decompose the address into a base register and a 16-bit offset. This bridges the gap between what TableGen can express (structural patterns) and what requires runtime checks (is the offset < 2^16?).

---

## The SE Subclass Split for ISel

As mentioned in Post 1, instruction selection uses the SE subclass pattern. The class hierarchy is:

```
SelectionDAGISel (LLVM core)
  └── Cpu0DAGToDAGISel (abstract base — Cpu0ISelDAGToDAG.h)
        └── Cpu0SEDAGToDAGISel (concrete — Cpu0SEISelDAGToDAG.h)
```

The base class `Cpu0DAGToDAGISel` provides:
- `Select()`: the main dispatch method called for every DAG node
- `SelectAddr()`: complex pattern for memory address decomposition
- `getGlobalBaseReg()`: creates the `$gp` base register node for PIC code
- `#include "Cpu0GenDAGISel.inc"`: the generated `SelectCode()` table-driven matcher

The key design: `trySelect()` is declared as a **pure virtual** in the base:

```cpp
// Cpu0ISelDAGToDAG.h
virtual bool trySelect(SDNode *Node) = 0;
```

And the `Select()` dispatch calls it before falling back to `SelectCode()`:

```cpp
void Cpu0DAGToDAGISel::Select(SDNode *Node) {
  // Already selected (by a previous pass)?
  if (Node->isMachineOpcode()) return;

  // Let the SE subclass try first — handles multiply, add-with-carry
  if (trySelect(Node)) return;

  // Handle GLOBAL_OFFSET_TABLE pseudo (used in PIC prologues)
  unsigned Opcode = Node->getOpcode();
  switch (Opcode) {
  case ISD::GLOBAL_OFFSET_TABLE:
    ReplaceNode(Node, getGlobalBaseReg());
    return;
  }

  // Fall through to generated table-driven matcher
  SelectCode(Node);
}
```

The SE subclass `Cpu0SEDAGToDAGISel::trySelect()` handles operations that require custom C++ matching logic — not just structural pattern matching. Specifically, it implements:

**`selectMULT()`** — Multiply instructions (MUL, MULT, MULTU) produce two output values: the high word in `HI` and the low word in `LO`. TableGen patterns can't express multi-output instructions that write to named registers, so `trySelect()` manually creates a `MachineInstr` node with explicit `HI`/`LO` register results:

```cpp
std::pair<SDNode *, SDNode *> Cpu0SEDAGToDAGISel::selectMULT(
    SDNode *N, unsigned Opc, const SDLoc &DL, EVT Ty, bool HasLo, bool HasHi) {
  SDNode *Mult = CurDAG->getMachineNode(Opc, DL, MVT::Glue, {LHS, RHS});
  SDNode *Lo = nullptr, *Hi = nullptr;
  if (HasLo) Lo = CurDAG->getMachineNode(Cpu0::MFLO, DL, Ty, MVT::Glue,
                                          SDValue(Mult, 0));
  if (HasHi) Hi = CurDAG->getMachineNode(Cpu0::MFHI, DL, Ty, MVT::Glue,
                                          SDValue(Mult, 0));
  return {Lo, Hi};
}
```

**`selectAddESubE()`** — Add/subtract with extended carry (used in 64-bit operations synthesized from two 32-bit instructions).

**`processFunctionAfterISel()`** — Runs after the entire function is selected. For Cpu0 SE, it replaces `$gp_copy` pseudo-registers with real `$gp` moves in function prologues (part of PIC support).

Similarly for lowering, the SE split applies:
- `Cpu0TargetLowering` (base): defines `setOperationAction` calls and `LowerOperation()` dispatch
- `Cpu0SETargetLowering` (concrete): registers the `CPURegs` register class and sets SE-specific type actions in its constructor

This separation means the framework code (in the base class) never changes when adding SE-specific features — you only modify the SE subclass.

---

## Debugging DAG Selection

When something doesn't match, you need to see the DAG. The key debug flags:

```bash
# Full debug output — very verbose, includes all DAG stages
build/bin/llc -march=cpu0 -debug input.ll 2>&1 | less

# View the DAG at specific stages (opens a Graphviz window if available)
build/bin/llc -march=cpu0 -view-isel-dags input.ll          # Before ISel
build/bin/llc -march=cpu0 -view-dag-combine1-dags input.ll  # After combine 1
build/bin/llc -march=cpu0 -view-legalize-types-dags input.ll # After type legalization
build/bin/llc -march=cpu0 -view-sched-dags input.ll          # After scheduling

# Print the DAG at each stage to stderr (no Graphviz needed)
build/bin/llc -march=cpu0 -debug-only=isel input.ll 2>&1 | less
```

### Common Failure Modes

**Pattern not matching**: The most common problem. Check that:
1. The operand types match exactly. An `ISD::ADD` on `i32` and an `ISD::ADD` on `i64` are different — make sure the TableGen pattern specifies the right `ValueType`.
2. The node is in the right legalization state. If you're trying to match a node that's still `Custom`, it will be lowered before matching.
3. All predicates are satisfied. Many patterns have `Requires<[HasSlt]>` or similar guards.

**Operation unexpectedly expanded**: You called `setOperationAction(ISD::FOO, MVT::i32, Expand)` — or forgot to call `Custom`. Check `Cpu0ISelLowering.cpp`'s constructor.

**Multiply result in wrong register**: The `MFLO`/`MFHI` move instructions must immediately follow `MULT`/`MULTU`. The `trySelect()` path in `Cpu0SEDAGToDAGISel` handles this by chaining them with `MVT::Glue`, which prevents the scheduler from inserting anything between them.

**Frame index not resolved**: If you see `fi#N` in the output instead of a register-offset pair, `SelectAddr` isn't being called for the memory operand. Make sure the load/store pattern uses the `addr` `ComplexPattern`.

### Reading the `-debug` Output

The debug output structure is:
```
Initial selection DAG:       ← DAG from IR
Optimized lowered selection DAG:  ← After custom lowering
Type-legalized selection DAG:     ← After type legalization
Legalized selection DAG:          ← After operation legalization
Selected selection DAG:           ← After instruction selection
Scheduled:                        ← Final MachineInstr sequence
```

For each stage, you get the full DAG printed as a tree. When debugging a selection failure, diff the "Legalized" DAG (what goes into instruction selection) with the "Selected" DAG (what came out). If a node is missing from the Selected DAG or is a different opcode, that's where the problem is.

---

## Type Legalization Preview

Before instruction selection runs, LLVM's **type legalizer** ensures that all values have types the target can handle. Cpu0 only natively supports `i32`, so:

- `i1` results (from comparisons) are **promoted** to `i32`
- `i8` and `i16` loads are **extended** to `i32`
- `SIGN_EXTEND_INREG` is **expanded** to a `shl`/`sra` pair (since Cpu0 has no sub-word sign-extend instruction)
- `i64` is **not supported** — no 64-bit operations exist in the ISA

```cpp
// i1 setcc results promoted to i32
AddPromotedToType(ISD::SETCC, MVT::i1, MVT::i32);

// i1 loads promoted
for (MVT VT : MVT::integer_valuetypes()) {
  setLoadExtAction(ISD::EXTLOAD,  VT, MVT::i1, Promote);
  setLoadExtAction(ISD::ZEXTLOAD, VT, MVT::i1, Promote);
  setLoadExtAction(ISD::SEXTLOAD, VT, MVT::i1, Promote);
}

// No sub-word sign extension — expand to shl/sra
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i1,  Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i8,  Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i16, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::i32, Expand);
setOperationAction(ISD::SIGN_EXTEND_INREG, MVT::Other, Expand);
```

We'll cover type legalization in full detail in [Post 9: Backend Internals](09-internals.md).

---

## A Harder Example: Division

Division is instructive because Cpu0 has hardware divide instructions, yet `ISD::SDIV` is marked `Expand`. Why?

```cpp
setOperationAction(ISD::SDIV, MVT::i32, Expand);
setOperationAction(ISD::SREM, MVT::i32, Expand);
```

The `Expand` here doesn't mean "no hardware divide." It means: expand `SDIV` into `SDIVREM` (which computes both quotient and remainder together). Then the DAG combiner fires the custom combine hook:

```cpp
setTargetDAGCombine(ISD::SDIVREM);
setTargetDAGCombine(ISD::UDIVREM);
```

`PerformDAGCombine` replaces `SDIVREM` with `Cpu0ISD::DivRem`, which maps to the hardware `div` instruction:

```asm
# For: int q = a / b; int r = a % b;
div     $r4, $r5           # HI = a%b, LO = a/b
mflo    $r2                # Get quotient from LO
mfhi    $r3                # Get remainder from HI
```

If only the quotient is needed (only `SDIV`, no `SREM`), the `MFHI` is elided. If only the remainder, the `MFLO` is elided. The single `div` is shared. This is a real performance win over generating separate divide instructions for each, and it's only possible because the `SDIV`/`SREM` expansion into `SDIVREM` plus the custom DAG combine creates the opportunity.

This pattern — `Expand` to `*REM`, then custom combine to hardware — is reusable for any target with combined div/rem instructions (MIPS, PowerPC, x86 `IDIV` all use it).

### DAG Combines: A Fourth Mechanism

The division example quietly introduced a fourth tool: **DAG combines**. `setTargetDAGCombine(ISD::SDIVREM)` registers a hook that fires whenever the DAG combiner visits an `SDIVREM` node. The combiner runs multiple times throughout the pipeline — after each legalization phase and again after instruction selection — to fold constants, eliminate redundant operations, and apply algebraic identities.

`PerformDAGCombine()` in `Cpu0ISelLowering.cpp` handles these callbacks:

```cpp
SDValue Cpu0TargetLowering::PerformDAGCombine(SDNode *N,
                                              DAGCombinerInfo &DCI) const {
  switch (N->getOpcode()) {
  case ISD::SDIVREM:
  case ISD::UDIVREM:
    return performDivRemCombine(N, DCI.DAG, DCI, Subtarget);
  }
  return SDValue();
}
```

`performDivRemCombine` replaces the `SDIVREM` node with `Cpu0ISD::DivRem`, which maps directly to the `div` hardware instruction. The `SELECT` → `MOVZ`/`MOVN` transformation, by contrast, is handled through TableGen patterns in `Cpu0CondMov.td` — a reminder that the same goal (optimizing a conditional operation) can be achieved through different mechanisms depending on when in the pipeline the transformation is most natural.

The distinction between `Custom` lowering and DAG combines is timing: custom lowering runs during operation legalization (before type-legal DAGs are handed to the combiner), while DAG combines run after legalization and repeatedly during optimization. Use combines for algebraic transformations and folding; use custom lowering when an operation needs to be replaced with a completely different node sequence.

## Summary: Four Mechanisms, One Pipeline

| Mechanism | When to use | Example |
|-----------|------------|---------|
| **TableGen patterns** | Direct 1:1 mapping from DAG node to instruction | `add` → `ADDu` |
| **Custom lowering** (`setOperationAction` + `LowerOperation`) | Operation requires target-specific logic or multi-instruction sequence | `GlobalAddress` → Hi/Lo/Wrapper sequence |
| **Complex patterns** (`ComplexPattern` + C++ method) | Operand decomposition that depends on runtime values | `addr` → `SelectAddr()` splits into base+offset |
| **DAG combines** (`setTargetDAGCombine` + `PerformDAGCombine`) | Algebraic folding and pattern merging after legalization | `SDIVREM` → `DivRem` for shared divide |

Most instructions use mechanism 1 (patterns). The backend's complexity comes from the ~12 operations that need mechanism 2 (custom lowering), and the handful that need mechanism 3 (complex patterns). Understanding which mechanism to use for each operation is the core skill of backend development.

---

## Further Reading

- [LLVM Code Generator](https://llvm.org/docs/CodeGenerator.html) — Sections on SelectionDAG, legalization, and instruction selection
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html) — IR instruction semantics
- [Extending LLVM](https://llvm.org/docs/ExtendingLLVM.html) — Adding new instructions and intrinsics
- [TableGen Programmer's Reference](https://llvm.org/docs/TableGen/ProgRef.html) — Pattern syntax

---

*Previous: [Post 1 — The Anatomy of an LLVM Backend: What 72 Files and 12,000 Lines Actually Do](01-anatomy.md)*

*Next up: [Post 3 — Stack Frames, Calling Conventions, and the ABI](03-calling-conventions.md)*
