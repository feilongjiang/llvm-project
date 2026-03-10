; NOTE: Tests for Ch7 — Other data types: local pointers, char/short, bool,
; long long, struct, array, CLZ/CLO.
; Float/double and vector require later chapters (function calls, control flow).
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

; Test 1: Local variable pointer — generates LEA (addiu for address).
; CHECK-LABEL: test_local_pointer:
; CHECK:       addiu   $r{{[0-9]+}}, $sp
; CHECK:       ret     $lr
define i32 @test_local_pointer() nounwind {
entry:
  %b = alloca i32, align 4
  %p = alloca i32*, align 4
  store i32 3, i32* %b, align 4
  store i32* %b, i32** %p, align 4
  %0 = load i32*, i32** %p, align 4
  %1 = load i32, i32* %0, align 4
  ret i32 %1
}

; Test 2: Byte load/store — lb, lbu, sb instructions.
; CHECK-LABEL: test_char:
; CHECK:       sb      $r{{[0-9]+}}
; CHECK:       lb      $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_char() nounwind {
entry:
  %a = alloca i8, align 1
  store volatile i8 65, i8* %a, align 1
  %av = load volatile i8, i8* %a, align 1
  %res = sext i8 %av to i32
  ret i32 %res
}

; Test 3: Unsigned byte — lbu instruction.
; CHECK-LABEL: test_uchar:
; CHECK:       lbu     $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_uchar() nounwind {
entry:
  %a = alloca i8, align 1
  store volatile i8 200, i8* %a, align 1
  %av = load volatile i8, i8* %a, align 1
  %res = zext i8 %av to i32
  ret i32 %res
}

; Test 4: Half-word load/store — lh, sh instructions.
; CHECK-LABEL: test_short:
; CHECK:       sh      $r{{[0-9]+}}
; CHECK:       lh      $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_short() nounwind {
entry:
  %a = alloca i16, align 2
  store volatile i16 1000, i16* %a, align 2
  %av = load volatile i16, i16* %a, align 2
  %res = sext i16 %av to i32
  ret i32 %res
}

; Test 5: Unsigned half-word — lhu instruction.
; CHECK-LABEL: test_ushort:
; CHECK:       lhu     $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_ushort() nounwind {
entry:
  %a = alloca i16, align 2
  store volatile i16 50000, i16* %a, align 2
  %av = load volatile i16, i16* %a, align 2
  %res = zext i16 %av to i32
  ret i32 %res
}

; Test 6: Bool (i1) — stored as byte with sb.
; CHECK-LABEL: test_bool:
; CHECK:       sb      $r{{[0-9]+}}
; CHECK:       ret     $lr
define zeroext i1 @test_bool() nounwind {
entry:
  %retval = alloca i1, align 1
  store i1 1, i1* %retval, align 1
  %0 = load i1, i1* %retval
  ret i1 %0
}

; Test 7: Long long (i64) addition — uses addu + sltu carry chain.
; CHECK-LABEL: test_longlong_add:
; CHECK:       addu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       sltu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i64 @test_longlong_add() nounwind {
entry:
  %a = alloca i64, align 8
  %b = alloca i64, align 8
  store volatile i64 3, i64* %a, align 8
  store volatile i64 2, i64* %b, align 8
  %av = load volatile i64, i64* %a, align 8
  %bv = load volatile i64, i64* %b, align 8
  %res = add i64 %av, %bv
  ret i64 %res
}

; Test 8: Struct field access — correct offset folding (date.day at offset 8).
%struct.Date = type { i32, i32, i32 }
@date = global %struct.Date { i32 2012, i32 10, i32 12 }, align 4
; CHECK-LABEL: test_struct:
; CHECK:       ld      $r{{[0-9]+}}, 8($r{{[0-9]+}})
; CHECK:       ret     $lr
define i32 @test_struct() nounwind {
entry:
  %day = load i32, i32* getelementptr inbounds (%struct.Date, %struct.Date* @date, i32 0, i32 2), align 4
  ret i32 %day
}

; Test 9: Array element access — correct offset folding (a[1] at offset 4).
@a = global [3 x i32] [i32 2012, i32 10, i32 12], align 4
; CHECK-LABEL: test_array:
; CHECK:       ld      $r{{[0-9]+}}, 4($r{{[0-9]+}})
; CHECK:       ret     $lr
define i32 @test_array() nounwind {
entry:
  %0 = load i32, i32* getelementptr inbounds ([3 x i32], [3 x i32]* @a, i32 0, i32 1), align 4
  ret i32 %0
}

; Test 10: i64 subtraction — tests SUBE carry chain.
; CHECK-LABEL: test_longlong_sub:
; CHECK:       subu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       sltu    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i64 @test_longlong_sub() nounwind {
entry:
  %a = alloca i64, align 8
  %b = alloca i64, align 8
  store volatile i64 5, i64* %a, align 8
  store volatile i64 3, i64* %b, align 8
  %av = load volatile i64, i64* %a, align 8
  %bv = load volatile i64, i64* %b, align 8
  %res = sub i64 %av, %bv
  ret i64 %res
}

; Test 11: Count leading zeros — clz instruction.
; CHECK-LABEL: test_clz:
; CHECK:       clz     $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
declare i32 @llvm.ctlz.i32(i32, i1)
define i32 @test_clz() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 255, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %res = call i32 @llvm.ctlz.i32(i32 %av, i1 true)
  ret i32 %res
}

; Test 11: Any-extend i8 load (extloadi8) — should use lbu.
; CHECK-LABEL: test_extload_i8:
; CHECK:       lbu     $r{{[0-9]+}}
; CHECK:       sb      $r{{[0-9]+}}
; CHECK:       ret     $lr
define void @test_extload_i8() nounwind {
entry:
  %src = alloca i8, align 1
  %dst = alloca i8, align 1
  store volatile i8 77, i8* %src, align 1
  %v = load volatile i8, i8* %src, align 1
  store volatile i8 %v, i8* %dst, align 1
  ret void
}

; Test 13: Count leading ones — clo instruction.
; CHECK-LABEL: test_clo:
; CHECK:       clo     $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_clo() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 -1, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  %not = xor i32 %av, -1
  %res = call i32 @llvm.ctlz.i32(i32 %not, i1 true)
  ret i32 %res
}

; Test 14: Count trailing zeros — expanded via clz.
; CHECK-LABEL: test_cttz:
; CHECK:       clz
; CHECK:       ret     $lr
declare i32 @llvm.cttz.i32(i32, i1)
define i32 @test_cttz(i32 %a) nounwind {
entry:
  %res = call i32 @llvm.cttz.i32(i32 %a, i1 true)
  ret i32 %res
}

; Test 15: Population count — expanded to bit manipulation sequence.
; CHECK-LABEL: test_ctpop:
; CHECK:       shr
; CHECK:       mul
; CHECK:       ret     $lr
declare i32 @llvm.ctpop.i32(i32)
define i32 @test_ctpop(i32 %a) nounwind {
entry:
  %res = call i32 @llvm.ctpop.i32(i32 %a)
  ret i32 %res
}
