; NOTE: Tests for Ch3.2 — Cpu0 set-on-comparison instructions (cpu032II default).
; The default CPU is cpu032II which uses slt-family instructions.
; With setBooleanContents(ZeroOrOneBooleanContent), slt/sltu/sltiu already
; produce 0/1 results, so no andi mask is needed after comparisons.
; Volatile loads prevent constant folding.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Equal (==) — xor + sltiu.
; CHECK-LABEL: test_eq:
; CHECK:       xor     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       sltiu   $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_eq() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp eq i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 2: Not equal (!=) — xor + sltu.
; CHECK-LABEL: test_ne:
; CHECK:       xor     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       sltu    $r{{[0-9]+}}, $zero, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_ne() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp ne i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 3: Signed less than (<) — slt.
; CHECK-LABEL: test_slt:
; CHECK:       slt     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_slt() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp slt i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 4: Signed less than or equal (<=) — slt (reversed) + xori.
; CHECK-LABEL: test_sle:
; CHECK:       slt     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       xori    $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_sle() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp sle i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 5: Signed greater than (>) — slt (reversed operands).
; CHECK-LABEL: test_sgt:
; CHECK:       slt     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_sgt() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp sgt i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 6: Signed greater than or equal (>=) — slt + xori.
; CHECK-LABEL: test_sge:
; CHECK:       slt     $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       xori    $r{{[0-9]+}}, $r{{[0-9]+}}, 1
; CHECK:       ret     $lr
define i32 @test_sge() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp sge i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}

; Test 7: Unsigned less than (<u) — sltu.
; CHECK-LABEL: test_ult:
; CHECK:       sltu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_ult() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, i32* %a, align 4
  store volatile i32 3, i32* %b, align 4
  %av = load volatile i32, i32* %a, align 4
  %bv = load volatile i32, i32* %b, align 4
  %cmp = icmp ult i32 %av, %bv
  %res = zext i1 %cmp to i32
  ret i32 %res
}
