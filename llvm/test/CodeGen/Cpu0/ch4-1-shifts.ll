; NOTE: Tests for Ch3.1 — Cpu0 shift instructions (constant and variable).
; Volatile loads prevent constant folding of the value being shifted.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Logical left shift by constant — generates shl.
; CHECK-LABEL: test_shl_const:
; CHECK:       shl     $r{{[0-9]+}}, $r{{[0-9]+}}, 2
; CHECK:       ret     $lr
define i32 @test_shl_const() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = shl i32 %av, 2
  ret i32 %res
}

; Test 2: Logical right shift by constant — generates shr.
; CHECK-LABEL: test_lshr_const:
; CHECK:       shr     $r{{[0-9]+}}, $r{{[0-9]+}}, 2
; CHECK:       ret     $lr
define i32 @test_lshr_const() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 20, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = lshr i32 %av, 2
  ret i32 %res
}

; Test 3: Arithmetic right shift by constant — generates sra.
; CHECK-LABEL: test_ashr_const:
; CHECK:       sra     $r{{[0-9]+}}, $r{{[0-9]+}}, 2
; CHECK:       ret     $lr
define i32 @test_ashr_const() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 -20, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = ashr i32 %av, 2
  ret i32 %res
}

; Test 4: Logical left shift by variable — generates shlv.
; CHECK-LABEL: test_shl_var:
; CHECK:       shlv    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_shl_var() nounwind {
entry:
  %a = alloca i32, align 4
  %n = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 2, i32* %n, align 4
  %av = load volatile i32, i32* %a, align 4
  %nv = load volatile i32, i32* %n, align 4
  %res = shl i32 %av, %nv
  ret i32 %res
}

; Test 5: Logical right shift by variable — generates shrv.
; CHECK-LABEL: test_lshr_var:
; CHECK:       shrv    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_lshr_var() nounwind {
entry:
  %a = alloca i32, align 4
  %n = alloca i32, align 4
  store volatile i32 20, i32* %a, align 4
  store volatile i32 2, i32* %n, align 4
  %av = load volatile i32, i32* %a, align 4
  %nv = load volatile i32, i32* %n, align 4
  %res = lshr i32 %av, %nv
  ret i32 %res
}

; Test 6: Arithmetic right shift by variable — generates srav.
; CHECK-LABEL: test_ashr_var:
; CHECK:       srav    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_ashr_var() nounwind {
entry:
  %a = alloca i32, align 4
  %n = alloca i32, align 4
  store volatile i32 -20, i32* %a, align 4
  store volatile i32 2, i32* %n, align 4
  %av = load volatile i32, i32* %a, align 4
  %nv = load volatile i32, i32* %n, align 4
  %res = ashr i32 %av, %nv
  ret i32 %res
}
