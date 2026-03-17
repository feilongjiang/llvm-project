; NOTE: Tests for Ch12 — Cpu0 little-endian atomic operations.
;
; Covers sub-word (i8/i16) atomics on cpu0el to verify correct shift
; calculation without the big-endian XOR byte-swap.
;
; RUN: llc -march=cpu0el -mcpu=cpu032II -relocation-model=pic -filetype=asm < %s \
; RUN:   | FileCheck %s

; --- atomicrmw add i8 (little-endian) ---
; Little-endian uses shl directly without xori byte-swap.
define i8 @atomic_add_i8_le(i8* %ptr, i8 %val) nounwind {
; CHECK-LABEL: atomic_add_i8_le:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: andi {{.*}}, 3
; CHECK-NOT: xori
; CHECK: shl
; CHECK: ori {{.*}}, 255
; CHECK: nor
; CHECK: ll
; CHECK: addu
; CHECK: sc
  %old = atomicrmw add i8* %ptr, i8 %val monotonic
  ret i8 %old
}

; --- atomicrmw add i16 (little-endian) ---
define i16 @atomic_add_i16_le(i16* %ptr, i16 %val) nounwind {
; CHECK-LABEL: atomic_add_i16_le:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: andi {{.*}}, 3
; CHECK-NOT: xori
; CHECK: shl
; CHECK: ori {{.*}}, 65535
; CHECK: nor
; CHECK: ll
; CHECK: sc
  %old = atomicrmw add i16* %ptr, i16 %val monotonic
  ret i16 %old
}

; --- cmpxchg i8 (little-endian) ---
define i8 @atomic_cmpxchg_i8_le(i8* %ptr, i8 %cmp, i8 %new) nounwind {
; CHECK-LABEL: atomic_cmpxchg_i8_le:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: andi {{.*}}, 3
; CHECK-NOT: xori
; CHECK: shl
; CHECK: nor
; CHECK: ll
; CHECK: bne
  %val = cmpxchg i8* %ptr, i8 %cmp, i8 %new monotonic monotonic
  %loaded = extractvalue { i8, i1 } %val, 0
  ret i8 %loaded
}

; --- atomicrmw nand i32 (little-endian, 32-bit) ---
; Verify NOR is used for NOT on little-endian too.
define i32 @atomic_nand_i32_le(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_nand_i32_le:
; CHECK: ll
; CHECK: and
; CHECK: nor
; CHECK: sc
  %old = atomicrmw nand i32* %ptr, i32 %val monotonic
  ret i32 %old
}
