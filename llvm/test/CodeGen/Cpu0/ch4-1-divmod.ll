; NOTE: Tests for Ch3.1 — Cpu0 division and modulo via HI/LO registers.
; Volatile loads prevent constant folding, ensuring div/divu instructions are emitted.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Signed division — generates div + mflo.
; CHECK-LABEL: test_sdiv:
; CHECK:       div     $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       mflo    $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_sdiv() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 12, i32* %a, align 4
  store volatile i32 5, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = sdiv i32 %av, %bv
  ret i32 %res
}

; Test 2: Signed remainder — generates div + mfhi.
; CHECK-LABEL: test_srem:
; CHECK:       div     $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       mfhi    $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_srem() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 12, i32* %a, align 4
  store volatile i32 5, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = srem i32 %av, %bv
  ret i32 %res
}

; Test 3: Unsigned division — generates divu + mflo.
; CHECK-LABEL: test_udiv:
; CHECK:       divu    $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       mflo    $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_udiv() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 12, i32* %a, align 4
  store volatile i32 5, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = udiv i32 %av, %bv
  ret i32 %res
}

; Test 4: Unsigned remainder — generates divu + mfhi.
; CHECK-LABEL: test_urem:
; CHECK:       divu    $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       mfhi    $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_urem() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 12, i32* %a, align 4
  store volatile i32 5, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = urem i32 %av, %bv
  ret i32 %res
}
