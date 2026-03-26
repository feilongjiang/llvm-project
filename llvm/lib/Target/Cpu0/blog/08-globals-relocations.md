# Global Variables, Relocations, and Position-Independent Code

*Part 8 of "Building an LLVM Backend From Scratch" — how global variables get their addresses at compile time, link time, and run time.*

---

## Why Globals Are Harder Than Locals

Local variables live on the stack. The compiler knows their offset from the stack pointer at compile time, so accessing them is a single `ld $reg, offset($sp)` instruction. (`$fp` is only used as a frame pointer when the function has variable-sized stack allocations; otherwise `$sp` is used directly.) Problem solved.

Global variables are different. Their addresses are not known at compile time -- they depend on where the linker places sections, and in shared libraries, on where the dynamic linker maps them into the process address space at load time. A backend must generate code that works across three scenarios:

1. **Static linking** -- The linker resolves all addresses before execution.
2. **PIC with local symbols** -- The symbol is defined in the same compilation unit; the GOT entry plus a low-offset adjustment gives the address.
3. **PIC with external symbols** -- The symbol might be defined in another shared library; the GOT entry alone holds the final address.
4. **PIC with large GOT** -- The GOT itself is too large for a 16-bit offset, requiring a two-instruction GOT-relative calculation.

Each scenario requires a different instruction sequence, different relocations, and different assumptions about what the linker will do. This post traces how the Cpu0 backend handles all four.

---

## The Four Addressing Modes

```
Non-PIC (static)          PIC Small GOT              PIC Large GOT              GP-Relative (.sdata)
────────────────          ─────────────              ─────────────              ────────────────────
lui  $r2, %hi(sym)        ld   $r2, %got(sym)($gp)   lui  $r2, %got_hi(sym)     ori  $r2, $gp,
ori  $r2, $r2, %lo(sym)   # single GOT load          addu $r2, $r2, $gp               %gp_rel(sym)
                                                     ld   $r2, %got_lo(sym)($r2) ld  $r2, 0($r2)

Relocations:              Relocations:               Relocations:               Relocations:
  R_CPU0_HI16               R_CPU0_GOT16               R_CPU0_GOT_HI16            R_CPU0_GPREL16
  R_CPU0_LO16                                          R_CPU0_GOT_LO16

-relocation-model=static  PIC, small GOT             PIC, large GOT             Globals <= 8 bytes
```

The decision tree lives in `Cpu0ISelLowering.cpp`, in the `lowerGlobalAddress` method and four template helpers defined in the header. Let's walk through each one.

### 1. Non-PIC: `getAddrNonPIC` -- The Simple Case

When compiling with `-relocation-model=static`, we know the linker will assign absolute addresses. We split the 32-bit address into two 16-bit halves using `%hi` and `%lo`:

```cpp
// From Cpu0ISelLowering.h
template <class NodeTy>
SDValue getAddrNonPIC(NodeTy *N, EVT Ty, SelectionDAG &DAG) const {
  SDLoc DL(N);
  SDValue Hi = getTargetNode(N, Ty, DAG, Cpu0II::MO_ABS_HI);
  SDValue Lo = getTargetNode(N, Ty, DAG, Cpu0II::MO_ABS_LO);
  return DAG.getNode(ISD::ADD, DL, Ty, DAG.getNode(Cpu0ISD::Hi, DL, Ty, Hi),
                     DAG.getNode(Cpu0ISD::Lo, DL, Ty, Lo));
}
```

This generates the DAG pattern `(add (Cpu0ISD::Hi %hi(sym)), (Cpu0ISD::Lo %lo(sym)))`, which becomes two instructions:

```asm
lui     $r2, %hi(g)
ori     $r2, $r2, %lo(g)
```

The `lui` loads the upper 16 bits into a register (shifted left by 16), and `ori` fills in the lower 16 bits. The linker patches both with `R_CPU0_HI16` and `R_CPU0_LO16` relocations. After linking, the two instructions together produce the full 32-bit absolute address.

### 2. PIC Local: `getAddrLocal` -- GOT + Low Offset

For position-independent code referencing a symbol defined in the same compilation unit (internal linkage or local non-function symbols), the compiler knows the offset between the GOT entry and the symbol. The GOT holds a page-aligned base, and `%lo` provides the within-page offset:

```cpp
// From Cpu0ISelLowering.h
template <class NodeTy>
SDValue getAddrLocal(NodeTy *N, EVT Ty, SelectionDAG &DAG) const {
  SDLoc DL(N);
  unsigned GOTFlag = Cpu0II::MO_GOT;
  SDValue GOT = DAG.getNode(Cpu0ISD::Wrapper, DL, Ty, getGlobalReg(DAG, Ty),
                            getTargetNode(N, Ty, DAG, GOTFlag));
  SDValue Load =
      DAG.getLoad(Ty, DL, DAG.getEntryNode(), GOT,
                  MachinePointerInfo::getGOT(DAG.getMachineFunction()));
  unsigned LoFlag = Cpu0II::MO_ABS_LO;
  SDValue Lo =
      DAG.getNode(Cpu0ISD::Lo, DL, Ty, getTargetNode(N, Ty, DAG, LoFlag));
  return DAG.getNode(ISD::ADD, DL, Ty, Load, Lo);
}
```

This produces three instructions:

```asm
ld      $r2, %got(g)($gp)       # Load GOT entry (page base)
ori     $r2, $r2, %lo(g)        # Add low 16-bit offset
ld      $r2, 0($r2)             # Dereference to get the value
```

The `Cpu0ISD::Wrapper` node combines the global pointer register (`$gp`) with the GOT offset into an address suitable for loading. The `%got` relocation tells the linker to fill in the GOT slot, and `%lo` gives the intra-page offset.

### 3. PIC Global: `getAddrGlobal` -- Pure GOT Lookup

For external symbols (defined in another shared library), the dynamic linker fills in the GOT entry with the symbol's absolute address at load time. No `%lo` adjustment is needed -- the GOT entry already points directly at the symbol:

```cpp
// From Cpu0ISelLowering.h
template <class NodeTy>
SDValue getAddrGlobal(NodeTy *N, EVT Ty, SelectionDAG &DAG, unsigned Flag,
                      SDValue Chain,
                      const MachinePointerInfo &PtrInfo) const {
  SDLoc DL(N);
  SDValue Tgt = DAG.getNode(Cpu0ISD::Wrapper, DL, Ty, getGlobalReg(DAG, Ty),
                            getTargetNode(N, Ty, DAG, Flag));
  return DAG.getLoad(Ty, DL, Chain, Tgt, PtrInfo);
}
```

This produces a single load:

```asm
ld      $r2, %got(g)($gp)       # GOT entry holds the absolute address
```

### 4. PIC Large GOT: `getAddrGlobalLargeGOT` -- When 16 Bits Aren't Enough

If the GOT grows beyond 64 KB (possible in very large programs), a 16-bit offset from `$gp` cannot reach every entry. The large-GOT mode uses a `%got_hi`/`%got_lo` pair:

```cpp
// From Cpu0ISelLowering.h
template <class NodeTy>
SDValue getAddrGlobalLargeGOT(NodeTy *N, EVT Ty, SelectionDAG &DAG,
                              unsigned HiFlag, unsigned LoFlag, SDValue Chain,
                              const MachinePointerInfo &PtrInfo) const {
  SDLoc DL(N);
  SDValue Hi =
      DAG.getNode(Cpu0ISD::Hi, DL, Ty, getTargetNode(N, Ty, DAG, HiFlag));
  Hi = DAG.getNode(ISD::ADD, DL, Ty, Hi, getGlobalReg(DAG, Ty));
  SDValue Wrapper = DAG.getNode(Cpu0ISD::Wrapper, DL, Ty, Hi,
                                getTargetNode(N, Ty, DAG, LoFlag));
  return DAG.getLoad(Ty, DL, Chain, Wrapper, PtrInfo);
}
```

This produces:

```asm
lui     $r2, %got_hi(g)         # Upper 16 bits of GOT offset
addu    $r2, $r2, $gp           # Add global pointer
ld      $r2, %got_lo(g)($r2)    # Load from GOT using lower 16 bits
```

The full 32-bit GOT offset is reconstructed from `%got_hi` and `%got_lo`, allowing the GOT to span up to 4 GB.

---

## The Decision Logic: `lowerGlobalAddress`

The four addressing modes are selected by `lowerGlobalAddress`, which inspects the relocation model, linkage, and symbol size:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::lowerGlobalAddress(SDValue Op,
                                               SelectionDAG &DAG) const {
  SDLoc DL(Op);
  const Cpu0TargetObjectFile *TLOF = static_cast<const Cpu0TargetObjectFile *>(
      getTargetMachine().getObjFileLowering());
  EVT Ty = Op.getValueType();
  GlobalAddressSDNode *N = cast<GlobalAddressSDNode>(Op);
  const GlobalValue *GV = N->getGlobal();

  if (!isPositionIndependent()) {
    // %gp_rel relocation
    const GlobalObject *GO = GV->getAliaseeObject();
    if (GO && TLOF->IsGlobalInSmallSection(GO, getTargetMachine())) {
      SDValue GA =
          DAG.getTargetGlobalAddress(GV, DL, MVT::i32, 0, Cpu0II::MO_GPREL);
      SDValue GPRelNode =
          DAG.getNode(Cpu0ISD::GPRel, DL, DAG.getVTList(MVT::i32), GA);
      SDValue GPReg = DAG.getRegister(Cpu0::GP, MVT::i32);
      return DAG.getNode(ISD::ADD, DL, MVT::i32, GPReg, GPRelNode);
    }

    // %hi/%lo relocation
    return getAddrNonPIC(N, Ty, DAG);
  }

  if (GV->hasInternalLinkage() ||
      (GV->hasLocalLinkage() && !isa<Function>(GV))) {
    return getAddrLocal(N, Ty, DAG);
  }

  const GlobalObject *GO = GV->getAliaseeObject();
  if (GO && !TLOF->IsGlobalInSmallSection(GO, getTargetMachine())) {
    return getAddrGlobalLargeGOT(
        N, Ty, DAG, Cpu0II::MO_GOT_HI16, Cpu0II::MO_GOT_LO16,
        DAG.getEntryNode(),
        MachinePointerInfo::getGOT(DAG.getMachineFunction()));
  }

  return getAddrGlobal(N, Ty, DAG, Cpu0II::MO_GOT, DAG.getEntryNode(),
                       MachinePointerInfo::getGOT(DAG.getMachineFunction()));
}
```

Notice the extra case in the non-PIC path: if the global fits in the **small data section**, the backend uses `%gp_rel` -- reducing the three-instruction `%hi/%lo`+`ld` sequence to a two-instruction `ori`+`ld` pair. This is a MIPS-derived optimization that Cpu0 inherits.

The decision tree in summary:

| Condition | Mode | Relocations |
|-----------|------|-------------|
| Static + small data | `%gp_rel` | `R_CPU0_GPREL16` |
| Static + normal | `%hi/%lo` | `R_CPU0_HI16` + `R_CPU0_LO16` |
| PIC + internal/local | GOT + `%lo` | `R_CPU0_GOT16` + `R_CPU0_LO16` |
| PIC + external + large | `%got_hi/%got_lo` | `R_CPU0_GOT_HI16` + `R_CPU0_GOT_LO16` |
| PIC + external + small | GOT only | `R_CPU0_GOT16` |

---

## The `%hi`/`%lo` Relocation Pair

The most fundamental relocation pattern is the `%hi`/`%lo` pair. Because Cpu0 instructions have 16-bit immediate fields, loading a 32-bit address requires two instructions. But there is a subtlety: `%hi` does not simply extract bits 31-16. It accounts for sign extension.

If bit 15 of the address is set (i.e., the low 16 bits look like a negative number), the `addiu` instruction that loads `%lo` will sign-extend its 16-bit immediate to 32 bits when adding it to the high half. This effectively subtracts 65536 from the intended value unless `%hi` compensates. The compensation is: when bit 15 of the address is set, add 1 to the upper 16 bits.

For example, for address `0xDEADBEEF`:
- `%lo(0xDEADBEEF)` = `0xBEEF` — but as a signed 16-bit value, this is `-16657`
- `%hi(0xDEADBEEF)` would naively be `0xDEAD`, but since bit 15 of `0xBEEF` is set (it's `0xB...`), `%hi` must be `0xDEAD + 1 = 0xDEAE`
- Final: `0xDEAE0000 + (-16657) = 0xDEAE0000 - 0x4111 = 0xDEADBEEF` ✓

This is standard MIPS behavior, and the linker handles it automatically when processing `R_CPU0_HI16`/`R_CPU0_LO16` relocation pairs.

### The Linker Pairing Requirement

The linker must see the HI16 and LO16 relocations as a **pair** referencing the **same symbol**. The pairing mechanism works like this:

1. When the linker encounters an `R_CPU0_HI16` relocation, it scans forward for the corresponding `R_CPU0_LO16` relocation on the same symbol.
2. The linker evaluates the symbol's final value `V`.
3. For the LO16 entry: compute `lo16 = V & 0xffff`.
4. For the HI16 entry: compute `hi16 = (V >> 16) + (lo16 & 0x8000 ? 1 : 0)`.
5. Patch the instruction bytes.

This is why `needsRelocateWithSymbol` in `Cpu0ELFObjectWriter.cpp` returns `true` for both relocations:

```cpp
// From Cpu0ELFObjectWriter.cpp
bool Cpu0ELFObjectWriter::needsRelocateWithSymbol(const MCSymbol &Sym,
                                                  unsigned Type) const {
  switch (Type) {
  case ELF::R_CPU0_HI16:
  case ELF::R_CPU0_LO16:
  case ELF::R_CPU0_32:
    return true;   // Must use symbol-relative relocation (enables HI/LO pairing)
  case ELF::R_CPU0_GPREL16:
    return false;  // Section-relative is fine for GP-relative
  default:
    return true;
  }
}
```

If HI16/LO16 relocations referenced sections instead of symbols, the linker couldn't match them as a pair for the same symbol — it would be unable to apply the sign-extension compensation correctly. The "must use symbol" requirement is a direct consequence of the two-instruction address materialization pattern.

### What Happens Without the Pair

If a backend incorrectly uses only HI16 (forgetting LO16), the linker patches only the upper 16 bits, leaving the lower 16 bits as zeros. The resulting address is wrong by up to 65535. This kind of bug produces code that *sometimes* works (when the low 16 bits are zero, or nearly zero) but fails for most symbols — a classic category of intermittent linker bug.

---

## Small-Data Sections: `.sdata` and `.sbss`

```
Global variable
      │
      ▼
┌──────────────────┐
│ size <= 8 bytes? ├──────────────────────────────────┐
└────────┬─────────┘                                  │
    Yes  │                                        No  │
         ▼                                            ▼
  .sdata / .sbss section                     .data / .bss section
  ─────────────────────                      ─────────────────────
  ori $r, $gp, %gp_rel(sym)                  ld $r, %got(sym)($gp)
  ld  $r, 0($r)                              # R_CPU0_GOT16
  # R_CPU0_GPREL16                           # Then load from address
  # Two instructions, no GOT lookup          # Two+ instructions

  Fast: direct GP offset.                    Slower: GOT lookup.

Threshold: 8 bytes (default). Override with -G <n> flag.
```

Small global variables get special treatment. Instead of the three-instruction `%hi/%lo`+`ld` sequence, they can be accessed in two instructions -- `ori $r, $gp, %gp_rel(g)` to compute the address, then `ld $r, 0($r)` to load -- using a single 16-bit GP-relative offset. The tradeoff: the total size of all small data must fit within the 16-bit signed offset range (approximately +/- 32 KB from `$gp`).

The logic lives in `Cpu0TargetObjectFile.cpp`:

```cpp
// From Cpu0TargetObjectFile.cpp
static cl::opt<unsigned> SSThreshold(
    "cpu0-ssection-threshold", cl::init(8),
    cl::desc("Small data and bss section threshold size (default=8)"),
    cl::Hidden);

void Cpu0TargetObjectFile::Initialize(MCContext &Ctx, const TargetMachine &TM) {
  TargetLoweringObjectFileELF::Initialize(Ctx, TM);
  InitializeELF(TM.Options.UseInitArray);

  SmallDataSection = getContext().getELFSection(
      ".sdata", ELF::SHT_PROGBITS, ELF::SHF_WRITE | ELF::SHF_ALLOC);

  SmallBSSSection = getContext().getELFSection(".sbss", ELF::SHT_NOBITS,
                                               ELF::SHF_WRITE | ELF::SHF_ALLOC);
}
```

The threshold defaults to 8 bytes. Any global whose `getTypeAllocSize` is between 1 and 8 bytes goes into `.sdata` (initialized) or `.sbss` (uninitialized). The classification cascades through three checks:

```cpp
static bool IsInSmallSection(uint64_t Size) {
  return Size > 0 && Size <= SSThreshold;
}
```

The section selection logic routes BSS globals to `.sbss`, data and read-only globals to `.sdata`:

```cpp
MCSection *Cpu0TargetObjectFile::SelectSectionForGlobal(
    const GlobalObject *GO, SectionKind Kind, const TargetMachine &TM) const {
  if (Kind.isBSS() && IsGlobalInSmallSection(GO, TM, Kind))
    return SmallBSSSection;
  if (Kind.isData() && IsGlobalInSmallSection(GO, TM, Kind))
    return SmallDataSection;
  if (Kind.isReadOnly() && IsGlobalInSmallSection(GO, TM, Kind))
    return SmallDataSection;

  return TargetLoweringObjectFileELF::SelectSectionForGlobal(GO, Kind, TM);
}
```

The subtarget must also have `useSmallSection()` enabled for this optimization to kick in. When it does, the generated code for accessing a small global looks like:

```asm
ori     $r2, $gp, %gp_rel(g)    # compute address: $gp + GP-relative offset
ld      $r2, 0($r2)             # load value; no %hi/%lo pair needed
```

This saves one instruction per access compared to the three-instruction static sequence (`lui`/`ori`/`ld`) -- a significant win in tight loops.

---

## The 17 Relocation Types: A Complete Catalog

```
Category         Relocation types
────────────────────────────────────────────────────────────────────────
Absolute         HI16, LO16, 32
PC-Relative      PC16, PC24
GOT              GOT16, CALL16, GOT_HI16, GOT_LO16
GP-Relative      GPREL16
TLS              TLSGD, TLSLDM, GOTTPREL, TP_HI16, TP_LO16,
                 DTPREL_HI16, DTPREL_LO16

Total: 17 types. Defined in Cpu0FixupKinds.h.
Mapped to ELF R_CPU0_* in Cpu0ELFObjectWriter.cpp.
```

Every addressing mode ultimately becomes a **fixup** in the assembler, which the object writer converts to an ELF relocation. Cpu0 defines 17 target-specific fixup types in `Cpu0FixupKinds.h`, each mapping to a specific ELF relocation type:

| Fixup Kind | ELF Relocation | Bits | PC-Rel? | Purpose |
|------------|---------------|------|---------|---------|
| `fixup_Cpu0_32` | `R_CPU0_32` | 32 | No | Absolute 32-bit address |
| `fixup_Cpu0_HI16` | `R_CPU0_HI16` | 16 | No | Upper 16 bits of absolute address |
| `fixup_Cpu0_LO16` | `R_CPU0_LO16` | 16 | No | Lower 16 bits of absolute address |
| `fixup_Cpu0_GPREL16` | `R_CPU0_GPREL16` | 16 | No | Offset from `$gp` (small data) |
| `fixup_Cpu0_GOT` | `R_CPU0_GOT16` | 16 | No | GOT entry offset from `$gp` |
| `fixup_Cpu0_PC16` | `R_CPU0_PC16` | 16 | Yes | PC-relative branch (e.g., `beq`) |
| `fixup_Cpu0_PC24` | `R_CPU0_PC24` | 24 | Yes* | PC-relative jump (e.g., `jsub`) |
| `fixup_Cpu0_CALL16` | `R_CPU0_CALL16` | 16 | No | Function call via GOT |
| `fixup_Cpu0_GOT_HI16` | `R_CPU0_GOT_HI16` | 16 | No | Upper 16 bits of large GOT offset |
| `fixup_Cpu0_GOT_LO16` | `R_CPU0_GOT_LO16` | 16 | No | Lower 16 bits of large GOT offset |
| `fixup_Cpu0_TLSGD` | `R_CPU0_TLS_GD` | 16 | No | General Dynamic TLS |
| `fixup_Cpu0_GOTTPREL` | `R_CPU0_TLS_GOTTPREL` | 16 | No | Initial Exec TLS (GOT offset to TP) |
| `fixup_Cpu0_TP_HI` | `R_CPU0_TLS_TPREL_HI16` | 16 | No | Local Exec TLS upper 16 bits |
| `fixup_Cpu0_TP_LO` | `R_CPU0_TLS_TPREL_LO16` | 16 | No | Local Exec TLS lower 16 bits |
| `fixup_Cpu0_TLSLDM` | `R_CPU0_TLS_LDM` | 16 | No | Local Dynamic TLS |
| `fixup_Cpu0_DTP_HI` | `R_CPU0_TLS_DTPREL_HI16` | 16 | No | DTP offset upper 16 bits |
| `fixup_Cpu0_DTP_LO` | `R_CPU0_TLS_DTPREL_LO16` | 16 | No | DTP offset lower 16 bits |

*`fixup_Cpu0_PC24` has conditional behavior: when an LLD-compatible linker is available, it uses only `FKF_IsPCRel`; otherwise, it also sets `FKF_Constant` to indicate the fixup value should be treated as constant by the assembler relaxation logic.

The mapping from fixup to ELF relocation is a straightforward `switch` in `Cpu0ELFObjectWriter::getRelocType`:

```cpp
// From Cpu0ELFObjectWriter.cpp
switch (Kind) {
default:
  llvm_unreachable("invalid fixup kind!");
case FK_Data_4:
  Type = ELF::R_CPU0_32;
  break;
case Cpu0::fixup_Cpu0_HI16:
  Type = ELF::R_CPU0_HI16;
  break;
case Cpu0::fixup_Cpu0_LO16:
  Type = ELF::R_CPU0_LO16;
  break;
// ... (15 more cases)
}
```

Notice two generic fixup kinds also appear: `FK_Data_4` (a 4-byte absolute data reference, used for `.word` directives) and `FK_GPRel_4` (a 4-byte GP-relative offset, mapping to `R_CPU0_GPREL32`).

---

## The MCExpr System: Target Expressions

Between the DAG lowering (which uses `MO_ABS_HI`, `MO_GOT`, etc.) and the final ELF relocation, there is an intermediate representation: **MC target expressions** (`Cpu0MCExpr`). These represent relocation modifiers in the assembly syntax: `%hi(sym)`, `%lo(sym)`, `%got(sym)`, `%gp_rel(sym)`, and so on.

The `Cpu0MCExpr` class defines 18 expression kinds:

```cpp
// From Cpu0MCExpr.h
enum Cpu0ExprKind {
  CEK_None,
  CEK_ABS_HI,        // %hi(sym)
  CEK_ABS_LO,        // %lo(sym)
  CEK_CALL_HI16,     // %call_hi(sym)
  CEK_CALL_LO16,     // %call_lo(sym)
  CEK_DTP_HI,        // %dtp_hi(sym)
  CEK_DTP_LO,        // %dtp_lo(sym)
  CEK_GOT,           // %got(sym)
  CEK_GOTTPREL,      // %gottprel(sym)
  CEK_GOT_CALL,      // %call16(sym)
  CEK_GOT_DISP,      // %got_disp(sym)
  CEK_GOT_HI16,      // %got_hi(sym)
  CEK_GOT_LO16,      // %got_lo(sym)
  CEK_GPREL,         // %gp_rel(sym)
  CEK_TLSGD,         // %tlsgd(sym)
  CEK_TLSLDM,        // %tlsldm(sym)
  CEK_TP_HI,         // %tp_hi(sym)
  CEK_TP_LO,         // %tp_lo(sym)
  CEK_Special,
};
```

### The Three-Layer Translation

The path from DAG to ELF relocation has three distinct layers:

1. **DAG lowering** -- `Cpu0ISelLowering` attaches `MO_` flags (from `Cpu0BaseInfo.h`) to `TargetGlobalAddress` nodes.
2. **MC lowering** -- `Cpu0MCInstLower` translates `MO_` flags into `Cpu0MCExpr` expression kinds (`CEK_`).
3. **Object writing** -- The assembler creates fixups from `Cpu0MCExpr` kinds, and `Cpu0ELFObjectWriter` maps fixups to ELF relocation types.

The `MO_` to `CEK_` mapping in `Cpu0MCInstLower.cpp` is a direct switch:

```
MO_GPREL      -> CEK_GPREL      -> fixup_Cpu0_GPREL16   -> R_CPU0_GPREL16
MO_GOT_CALL   -> CEK_GOT_CALL   -> fixup_Cpu0_CALL16    -> R_CPU0_CALL16
MO_GOT        -> CEK_GOT        -> fixup_Cpu0_GOT       -> R_CPU0_GOT16
MO_ABS_HI     -> CEK_ABS_HI     -> fixup_Cpu0_HI16      -> R_CPU0_HI16
MO_ABS_LO     -> CEK_ABS_LO     -> fixup_Cpu0_LO16      -> R_CPU0_LO16
MO_GOT_HI16   -> CEK_GOT_HI16   -> fixup_Cpu0_GOT_HI16  -> R_CPU0_GOT_HI16
MO_GOT_LO16   -> CEK_GOT_LO16   -> fixup_Cpu0_GOT_LO16  -> R_CPU0_GOT_LO16
```

The `printImpl` method of `Cpu0MCExpr` turns each kind into its assembly syntax:

```cpp
// From Cpu0MCExpr.cpp
switch (Kind) {
case CEK_ABS_HI:   OS << "%hi";       break;
case CEK_ABS_LO:   OS << "%lo";       break;
case CEK_GOT:      OS << "%got";      break;
case CEK_GOT_CALL: OS << "%call16";   break;
case CEK_GPREL:    OS << "%gp_rel";   break;
case CEK_GOT_HI16: OS << "%got_hi";   break;
case CEK_GOT_LO16: OS << "%got_lo";   break;
// ...
}
OS << '(';
Expr->print(OS, MAI, true);
OS << ')';
```

This is how the assembly output gets expressions like `%hi(g)` and `%got(g)` -- the MCExpr system formats them.

### The `%gp_rel` Special Case

The `%gp_rel` expression has unique handling. It uses a triple-nested `Cpu0MCExpr` structure, created by the `createGpOff` helper:

```cpp
// From Cpu0MCExpr.cpp
const Cpu0MCExpr *Cpu0MCExpr::createGpOff(Cpu0MCExpr::Cpu0ExprKind Kind,
                                          const MCExpr *Expr, MCContext &Ctx) {
  return create(Kind, create(CEK_None, create(CEK_GPREL, Expr, Ctx), Ctx), Ctx);
}
```

The `isGpOff` method peels back these layers to detect the pattern:

```cpp
bool Cpu0MCExpr::isGpOff(Cpu0ExprKind &Kind) const {
  if (const Cpu0MCExpr *S1 = dyn_cast<const Cpu0MCExpr>(getSubExpr())) {
    if (const Cpu0MCExpr *S2 = dyn_cast<const Cpu0MCExpr>(S1->getSubExpr())) {
      if (S1->getKind() == CEK_None && S2->getKind() == CEK_GPREL) {
        Kind = getKind();
        return true;
      }
    }
  }
  return false;
}
```

This nesting allows the outer expression to carry additional kind information (e.g., whether this is a HI or LO variant of the GP-relative offset) while the inner layers identify it as GP-relative.

---

## Initializing $gp: The `.cpload` Mechanism

In PIC mode, every load through the GOT is relative to `$gp`, the global pointer register. But where does `$gp` get its value in the first place?

When the dynamic linker loads a shared library, it writes the GOT's absolute address somewhere the program can find it. For MIPS/Cpu0 O32, the mechanism works through the `$t9` convention: when a function is called via a GOT entry, `$t9` holds the callee's own address. The function then uses this self-referential position to compute `$gp`.

The `.cpload $t9` pseudo-instruction expands to a 3-instruction sequence that computes `$gp` using the fact that `_gp_disp` is a linker-defined symbol whose value equals the offset from the function's start to the GOT:

```asm
# .cpload $t9 expands to:
lui   $gp, %hi(_gp_disp)     # load upper half of (GOT - start)
ori   $gp, $gp, %lo(_gp_disp) # add lower half
addu  $gp, $gp, $t9          # $gp = (GOT - start) + start = GOT address
```

The linker resolves `_gp_disp` to the GOT's offset from the current function's start address. Since `$t9` holds the function's runtime address, adding them gives the GOT's absolute address.

`Cpu0MCInstLower::LowerCPLOAD` generates these three `MCInst` objects from the single `.cpload` pseudo:

```cpp
void Cpu0MCInstLower::LowerCPLOAD(SmallVector<MCInst, 4> &MCInsts) {
  MCOperand GPReg = MCOperand::createReg(Cpu0::GP);
  MCOperand T9Reg = MCOperand::createReg(Cpu0::T9);
  const MCSymbol *Sym = Ctx->getOrCreateSymbol("_gp_disp");

  // Cpu0MCExpr wraps each half with the appropriate relocation kind
  MCSym = Cpu0MCExpr::create(Sym, Cpu0MCExpr::CEK_ABS_HI, *Ctx);
  MCOperand SymHi = MCOperand::createExpr(MCSym);
  MCSym = Cpu0MCExpr::create(Sym, Cpu0MCExpr::CEK_ABS_LO, *Ctx);
  MCOperand SymLo = MCOperand::createExpr(MCSym);

  MCInsts.resize(3);
  CreateMCInst(MCInsts[0], Cpu0::LUi,  GPReg, SymHi);
  CreateMCInst(MCInsts[1], Cpu0::ORi,  GPReg, GPReg, SymLo);
  CreateMCInst(MCInsts[2], Cpu0::ADD,  GPReg, GPReg, T9Reg);
}
```

The `R_CPU0_HI16` and `R_CPU0_LO16` relocations emitted for `_gp_disp` are special: the linker recognizes `_gp_disp` by name and uses it as an anchor for the GOT-relative computation. This is different from normal HI16/LO16 pairs that target data symbols.

After `.cpload`, `$gp` holds the GOT address and remains constant throughout the function body. The `EmitGPRestore` pass (covered in Post 3) restores `$gp` after any indirect call, since `$gp` is a call-clobbered register under the O32 ABI.

---

## `%call16` vs `%got`: Two GOT Entry Types

Not all GOT entries are the same. Cpu0 uses different relocation types for data access vs. function calls:

- **`R_CPU0_GOT16`** (via `%got`) — used to load the address of a data symbol. The GOT entry holds the symbol's absolute address.
- **`R_CPU0_CALL16`** (via `%call16`) — used for function calls via indirect register (`jalr $t9`). The GOT entry also holds the symbol's address, but the relocation type signals that a PLT (Procedure Linkage Table) entry may be used instead.

The reason for the distinction: shared libraries use **lazy binding** for function calls. The first time `bar()` is called, the PLT stub doesn't jump directly to `bar` — it calls the dynamic linker to resolve the symbol, patches the GOT entry, and then jumps to `bar`. On subsequent calls, the patched GOT entry points directly to `bar`, bypassing the PLT.

This lazy-binding optimization only makes sense for functions (PLT stubs don't exist for data). By emitting `R_CPU0_CALL16` for function calls, the backend tells the linker "this GOT entry might need a PLT stub," while `R_CPU0_GOT16` for data says "this must be the actual address."

In `lowerGlobalAddress`, function calls take the `getAddrGlobal` path with `Cpu0II::MO_GOT_CALL`:

```cpp
// For function call targets in PIC mode:
Callee = getAddrGlobal(G, Ty, DAG, Cpu0II::MO_GOT_CALL,
                       DAG.getEntryNode(),
                       MachinePointerInfo::getGOT(DAG.getMachineFunction()));
// → emits: ld $t9, %call16(bar)($gp)
// → relocation: R_CPU0_CALL16 against "bar"
```

While data access uses `Cpu0II::MO_GOT`:
```cpp
// For data variable access in PIC mode:
return getAddrGlobal(N, Ty, DAG, Cpu0II::MO_GOT,
                     DAG.getEntryNode(), ...);
// → emits: ld $r2, %got(g)($gp)
// → relocation: R_CPU0_GOT16 against "g"
```

Both produce a `ld` from `$gp + offset` in assembly, but the different relocation type allows the linker and dynamic linker to apply different semantics.

---

## Block Addresses and Jump Tables

Global variables are not the only symbols that need address materialization. Block addresses (for computed goto) and jump tables (for switch statements) use the same infrastructure:

```cpp
// From Cpu0ISelLowering.cpp
SDValue Cpu0TargetLowering::lowerBlockAddress(SDValue Op,
                                              SelectionDAG &DAG) const {
  BlockAddressSDNode *N = cast<BlockAddressSDNode>(Op);
  EVT Ty = Op.getValueType();

  if (!isPositionIndependent())
    return getAddrNonPIC(N, Ty, DAG);

  return getAddrLocal(N, Ty, DAG);
}

SDValue Cpu0TargetLowering::lowerJumpTable(SDValue Op,
                                           SelectionDAG &DAG) const {
  JumpTableSDNode *N = cast<JumpTableSDNode>(Op);
  EVT Ty = Op.getValueType();

  if (!isPositionIndependent())
    return getAddrNonPIC(N, Ty, DAG);

  return getAddrLocal(N, Ty, DAG);
}
```

The template-based design of `getAddrNonPIC` and `getAddrLocal` pays off here -- they accept any node type that `getTargetNode` can handle (`GlobalAddressSDNode`, `BlockAddressSDNode`, `JumpTableSDNode`, `ExternalSymbolSDNode`). The overloaded `getTargetNode` private methods handle the differences:

```cpp
// From Cpu0ISelLowering.h (private section)
SDValue getTargetNode(GlobalAddressSDNode *N, EVT Ty, SelectionDAG &DAG,
                      unsigned Flag) const;
SDValue getTargetNode(ExternalSymbolSDNode *N, EVT Ty, SelectionDAG &DAG,
                      unsigned Flag) const;
SDValue getTargetNode(BlockAddressSDNode *N, EVT Ty, SelectionDAG &DAG,
                      unsigned Flag) const;
SDValue getTargetNode(JumpTableSDNode *N, EVT Ty, SelectionDAG &DAG,
                      unsigned Flag) const;
```

---

## Example: Static vs. PIC Output

To see the difference these addressing modes make, consider this IR:

```llvm
@g = global i32 42
define i32 @load_g() {
  %v = load i32, i32* @g
  ret i32 %v
}
```

With `-relocation-model=static` (non-PIC), the generated assembly uses the `%hi/%lo` pair:

```asm
# llc -march=cpu0 -relocation-model=static load_g.ll -o -
load_g:
  lui     $r2, %hi(g)
  ori     $r2, $r2, %lo(g)
  ld      $r2, 0($r2)
  ret     $lr
  nop
```

With `-relocation-model=pic`, the output uses a GOT-based lookup:

```asm
# llc -march=cpu0 -relocation-model=pic -cpu0-use-small-section=true load_g.ll -o -
load_g:
  .set    noreorder
  .cpload $t9
  .set    nomacro
  lui     $r2, %hi(_gp_disp)       # \
  addiu   $r2, $r2, %lo(_gp_disp)  #  > set up $gp relative to $t9 (function address)
  ld      $r2, %got(g)($gp)        # load g's address from GOT
  ld      $r2, 0($r2)              # load value
  ret     $lr
  nop
```

The PIC version has a `.cpload $t9` directive that marks the start of global-pointer initialization. The subsequent `lui`/`addiu` pair loads `_gp_disp` (the offset from the current PC to `$gp`) into `$r2`, and together with `$t9` (which holds the function's own address per the ABI) establishes `$gp` for the rest of the function. The `%got(g)($gp)` load then fetches `g`'s address from the GOT rather than encoding it directly.

### Small-Data Optimization in Static Mode

For a small global (≤ 8 bytes), the static-mode output avoids the GOT entirely — a two-instruction GP-relative sequence:

```llvm
; load_g_small.ll
@g = global i32 42    ; i32 = 4 bytes, fits within the 8-byte small-section threshold
define i32 @load_g_small() {
  %v = load i32, i32* @g
  ret i32 %v
}
```

```asm
# llc -march=cpu0 -relocation-model=static -cpu0-use-small-section=true load_g_small.ll -o -
load_g_small:
  # g is a small global (char or int) → placed in .sdata
  ori     $r2, $gp, %gp_rel(g)  # address = $gp + 16-bit GP-relative offset
  ld      $r2, 0($r2)           # load value
  ret     $lr
  nop
```

This requires that `$gp` is initialized to the `.sdata` section base, which the runtime startup code (CRT) does before calling `main`. For a function accessing many small globals, this saves one instruction per access compared to the `%hi/%lo`+`ld` sequence — a meaningful code-size reduction.

The `%gp_rel` relocation (`R_CPU0_GPREL16`) is a signed 16-bit offset from `$gp`. The total accessible small-data window is ±32 KB, controlled by the `-cpu0-ssection-threshold` command-line option. Setting the threshold to 0 disables the optimization entirely; setting it very high aggressively places all globals in `.sdata`, which works only if the combined size is under 32 KB.

---

## Summary

Global variable addressing in Cpu0 touches every layer of the backend:

1. **DAG lowering** (`Cpu0ISelLowering`) selects one of four addressing modes based on relocation model, linkage, and symbol size.
2. **MC lowering** (`Cpu0MCInstLower`) translates MachineOperand flags into target MC expressions.
3. **Assembly printing** (`Cpu0MCExpr::printImpl`) renders the `%hi`, `%lo`, `%got`, and `%gp_rel` syntax.
4. **The assembler** (`Cpu0AsmBackend`) creates fixups with size and PC-relative information.
5. **The ELF writer** (`Cpu0ELFObjectWriter`) maps fixups to the 17 ELF relocation types.
6. **The linker** resolves relocations, filling in absolute addresses, GOT entries, and GP-relative offsets.

The small-data optimization (`%gp_rel` and `.sdata`/`.sbss` sections) is a cross-cutting concern that affects section selection, address lowering, and relocation choice -- a good example of how a single optimization requires coordination across multiple backend layers.

---

## Further Reading

- [Writing an LLVM Backend](https://llvm.org/docs/WritingAnLLVMBackend.html) — Relocation handling, fixups, and ELF writing
- [LLVM Code Generator](https://llvm.org/docs/CodeGenerator.html) — PIC addressing and the MC layer
- [LLVM Language Reference — Global Variables](https://llvm.org/docs/LangRef.html#global-variables) — Global variable semantics in IR
- [ELF Handling for Thread-Local Storage](https://www.akkadia.org/drepper/tls.pdf) — TLS models and relocation sequences
- [System V ABI — Global Offset Table](https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.dynamic.html#global_offset_table) — GOT and PLT structure

---

*Previous: [Post 7 — Closing the Loop: C++ Features, Atomics, and Verifying on a Verilog CPU](07-closing-the-loop.md)*

*Next up: [Post 9 — Under the Hood: Custom SDNodes, Type Legalization, and Backend Internals](09-internals.md)*
