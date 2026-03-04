; NOTE: Tests for Ch2 — Cpu0 prologue/epilogue code generation.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Basic function with a local variable — simple frame setup/teardown.
; CHECK-LABEL: test_simple_frame:
; CHECK:       .frame  ${{fp|sp}},{{[0-9]+}},$lr
; CHECK:       addiu   $sp, $sp, -{{[0-9]+}}
; CHECK:       addiu   $sp, $sp, {{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_simple_frame() nounwind {
entry:
  %b = alloca i32, align 4
  store i32 0, i32* %b, align 4
  %0 = load i32, i32* %b, align 4
  ret i32 %0
}

; Test 2: Return constant zero — minimal frame.
; CHECK-LABEL: test_return_zero:
; CHECK:       addiu   $r2, $zero, 0
; CHECK:       ret     $lr
define i32 @test_return_zero() nounwind {
entry:
  %b = alloca i32, align 4
  store i32 0, i32* %b, align 4
  %0 = load i32, i32* %b, align 4
  ret i32 %0
}

; Test 3: Large frame — stack adjustment requires lui+addiu+addu sequence.
; CHECK-LABEL: test_large_frame:
; CHECK:       lui     $r{{[0-9]+}}, {{[0-9]+}}
; CHECK:       addiu   $r{{[0-9]+}}, $r{{[0-9]+}}, {{-?[0-9]+}}
; CHECK:       addu    $sp, $sp, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_large_frame() nounwind {
entry:
  %arr = alloca [100000 x i32], align 4
  ret i32 0
}
