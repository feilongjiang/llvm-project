; NOTE: Tests for Ch3.2 — Cpu0 bitwise logic instructions.
; Volatile loads prevent constant folding.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Bitwise AND — generates and.
; CHECK-LABEL: test_and:
; CHECK:       and     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_and() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = and i32 %av, %bv
  ret i32 %res
}

; Test 2: Bitwise OR — generates or.
; CHECK-LABEL: test_or:
; CHECK:       or      $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_or() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = or i32 %av, %bv
  ret i32 %res
}

; Test 3: Bitwise XOR — generates xor.
; CHECK-LABEL: test_xor:
; CHECK:       xor     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_xor() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %res = xor i32 %av, %bv
  ret i32 %res
}

; Test 4: Bitwise NOT / complement — generates nor with $zero.
; The pattern `xor x, -1` lowers to `nor x, $zero`.
; CHECK-LABEL: test_not:
; CHECK:       nor     $r{{[0-9]+}}, $r{{[0-9]+}}, $zero
; CHECK:       ret     $lr
define i32 @test_not() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = xor i32 %av, -1
  ret i32 %res
}

; Test 5: Logical NOT (boolean) — icmp eq to zero generates xor + sltiu.
; With setBooleanContents(ZeroOrOneBooleanContent), sltiu already produces 0/1
; so the andi mask is optimized away.
; CHECK-LABEL: test_logical_not:
; CHECK:       sltiu   $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_logical_not() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %cmp = icmp eq i32 %av, 0
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 6: AND with 16-bit immediate — generates andi.
; CHECK-LABEL: test_andi:
; CHECK:       andi    $r{{[0-9]+}}, $r{{[0-9]+}}, 15
; CHECK:       ret     $lr
define i32 @test_andi() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 255, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = and i32 %av, 15
  ret i32 %res
}

; Test 7: XOR with 16-bit immediate — generates xori.
; CHECK-LABEL: test_xori:
; CHECK:       xori    $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_xori() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = xor i32 %av, 1
  ret i32 %res
}
