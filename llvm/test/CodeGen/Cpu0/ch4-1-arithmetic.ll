; NOTE: Tests for Ch3.1 — Cpu0 arithmetic instructions: add, sub, mul.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Integer addition — generates addu.
; Volatile loads prevent constant folding.
; CHECK-LABEL: test_add:
; CHECK:       addu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_add() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = add i32 %av, %bv
  ret i32 %res
}

; Test 2: Integer subtraction — generates subu.
; CHECK-LABEL: test_sub:
; CHECK:       subu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_sub() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = sub i32 %av, %bv
  ret i32 %res
}

; Test 3: Integer multiplication — generates mul.
; CHECK-LABEL: test_mul:
; CHECK:       mul     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_mul() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = mul i32 %av, %bv
  ret i32 %res
}

; Test 4: Small positive immediate — generates addiu with zero register.
; CHECK-LABEL: test_small_imm:
; CHECK:       addiu   $r{{[0-9]+}}, $zero, 42
; CHECK:       ret     $lr
define i32 @test_small_imm() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 42, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  ret i32 %av
}

; Test 5: Large immediate (> 16-bit) — generates lui + ori.
; 131073 = 0x20001: hi=2, lo=1
; CHECK-LABEL: test_large_imm:
; CHECK:       lui     $r{{[0-9]+}}, 2
; CHECK:       ori     $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_large_imm() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 131073, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  ret i32 %av
}
