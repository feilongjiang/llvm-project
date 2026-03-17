; NOTE: Tests for Ch12 — Cpu0 atomic operations (C++ support).
;
; Covers:
;   1. atomicrmw add/sub/and/or/xor/nand/xchg on i32 → ll/sc loop
;   2. atomicrmw add/nand/xchg on i8/i16 → sub-word ll/sc with masking
;   3. cmpxchg i32 → ll/sc pattern
;   4. cmpxchg i8 → sub-word ll/sc with masking
;   5. fence seq_cst/acquire/release → sync instruction
;   6. NAND correctness: verify NOR (not XOR) is used for bitwise NOT
;
; Big-endian tests:
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=pic -filetype=asm < %s \
; RUN:   | FileCheck %s --check-prefixes=CHECK,BE

; --- atomicrmw add i32 ---
define i32 @atomic_add_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_add_i32:
; CHECK: ll
; CHECK: addu
; CHECK: sc
  %old = atomicrmw add i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw sub i32 ---
define i32 @atomic_sub_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_sub_i32:
; CHECK: ll
; CHECK: subu
; CHECK: sc
  %old = atomicrmw sub i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw and i32 ---
define i32 @atomic_and_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_and_i32:
; CHECK: ll
; CHECK: and
; CHECK: sc
  %old = atomicrmw and i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw or i32 ---
define i32 @atomic_or_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_or_i32:
; CHECK: ll
; CHECK: or
; CHECK: sc
  %old = atomicrmw or i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw xor i32 (seq_cst → sync before and after) ---
define i32 @atomic_xor_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_xor_i32:
; CHECK: sync
; CHECK: ll
; CHECK: xor
; CHECK: sc
; CHECK: sync
  %old = atomicrmw xor i32* %ptr, i32 %val seq_cst
  ret i32 %old
}

; --- atomicrmw nand i32 ---
; NAND = ~(oldval & incr). Must use NOR for the NOT, not XOR.
define i32 @atomic_nand_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_nand_i32:
; CHECK: ll
; CHECK: and
; CHECK: nor
; CHECK: sc
  %old = atomicrmw nand i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw xchg i32 ---
define i32 @atomic_swap_i32(i32* %ptr, i32 %val) nounwind {
; CHECK-LABEL: atomic_swap_i32:
; CHECK: ll
; CHECK: sc
  %old = atomicrmw xchg i32* %ptr, i32 %val monotonic
  ret i32 %old
}

; --- atomicrmw add i8 (sub-word with masking) ---
define i8 @atomic_add_i8(i8* %ptr, i8 %val) nounwind {
; CHECK-LABEL: atomic_add_i8:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: andi {{.*}}, 3
; BE:    xori {{.*}}, 3
; CHECK: ori {{.*}}, 255
; CHECK: shlv
; CHECK: nor
; CHECK: ll
; CHECK: addu
; CHECK: sc
  %old = atomicrmw add i8* %ptr, i8 %val monotonic
  ret i8 %old
}

; --- atomicrmw add i16 (sub-word with masking) ---
define i16 @atomic_add_i16(i16* %ptr, i16 %val) nounwind {
; CHECK-LABEL: atomic_add_i16:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: andi {{.*}}, 3
; BE:    xori {{.*}}, 2
; CHECK: ori {{.*}}, 65535
; CHECK: shlv
; CHECK: nor
; CHECK: ll
; CHECK: addu
; CHECK: sc
  %old = atomicrmw add i16* %ptr, i16 %val monotonic
  ret i16 %old
}

; --- atomicrmw nand i8 (sub-word NAND) ---
; Must use NOR for NOT in the sub-word NAND path.
define i8 @atomic_nand_i8(i8* %ptr, i8 %val) nounwind {
; CHECK-LABEL: atomic_nand_i8:
; CHECK: nor
; CHECK: ll
; CHECK: and
; CHECK: nor
; CHECK: and
; CHECK: sc
  %old = atomicrmw nand i8* %ptr, i8 %val monotonic
  ret i8 %old
}

; --- atomicrmw xchg i8 (sub-word swap) ---
define i8 @atomic_swap_i8(i8* %ptr, i8 %val) nounwind {
; CHECK-LABEL: atomic_swap_i8:
; CHECK: nor
; CHECK: ll
; CHECK: sc
  %old = atomicrmw xchg i8* %ptr, i8 %val monotonic
  ret i8 %old
}

; --- cmpxchg i32 ---
define i32 @atomic_cmpxchg_i32(i32* %ptr) nounwind {
; CHECK-LABEL: atomic_cmpxchg_i32:
; CHECK: sync
; CHECK: ll
; CHECK: sc
; CHECK: sync
  %val = cmpxchg i32* %ptr, i32 0, i32 1 acq_rel acquire
  %loaded = extractvalue { i32, i1 } %val, 0
  ret i32 %loaded
}

; --- cmpxchg i8 (sub-word CAS with masking) ---
define i8 @atomic_cmpxchg_i8(i8* %ptr, i8 %cmp, i8 %new) nounwind {
; CHECK-LABEL: atomic_cmpxchg_i8:
; CHECK: addiu {{.*}}, $zero, -4
; CHECK: and
; CHECK: ori {{.*}}, 255
; CHECK: nor
; CHECK: ll
; CHECK: and
; CHECK: sc
  %val = cmpxchg i8* %ptr, i8 %cmp, i8 %new monotonic monotonic
  %loaded = extractvalue { i8, i1 } %val, 0
  ret i8 %loaded
}

; --- fence seq_cst ---
define void @fence_seq_cst() nounwind {
; CHECK-LABEL: fence_seq_cst:
; CHECK: sync
  fence seq_cst
  ret void
}

; --- fence acquire ---
define void @fence_acquire() nounwind {
; CHECK-LABEL: fence_acquire:
; CHECK: sync
  fence acquire
  ret void
}

; --- fence release ---
define void @fence_release() nounwind {
; CHECK-LABEL: fence_release:
; CHECK: sync
  fence release
  ret void
}
