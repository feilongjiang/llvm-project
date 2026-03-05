; NOTE: Tests for Ch3.1 — Cpu0 rotate instructions.
; RUN: llc -march=cpu0 -relocation-model=pic < %s | FileCheck %s

declare i32 @llvm.fshl.i32(i32, i32, i32)
declare i32 @llvm.fshr.i32(i32, i32, i32)

; Test 1: Rotate left by constant — generates rol.
; CHECK-LABEL: test_rol_const:
; CHECK:       rol     $r{{[0-9]+}}, $r{{[0-9]+}}, 30
; CHECK:       ret     $lr
define i32 @test_rol_const() nounwind {
entry:
  %a = alloca i32, align 4
  store i32 8, i32* %a, align 4
  %av = load i32, i32* %a, align 4
  %res = call i32 @llvm.fshl.i32(i32 %av, i32 %av, i32 30)
  ret i32 %res
}

; Test 2: Rotate right by constant — generates ror.
; CHECK-LABEL: test_ror_const:
; CHECK:       ror     $r{{[0-9]+}}, $r{{[0-9]+}}, 30
; CHECK:       ret     $lr
define i32 @test_ror_const() nounwind {
entry:
  %a = alloca i32, align 4
  store i32 8, i32* %a, align 4
  %av = load i32, i32* %a, align 4
  %res = call i32 @llvm.fshr.i32(i32 %av, i32 %av, i32 30)
  ret i32 %res
}

; Test 3: Rotate left by variable — generates rolv.
; Uses volatile loads to prevent constant folding.
; CHECK-LABEL: test_rol_var:
; CHECK:       rolv    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_rol_var() nounwind {
entry:
  %a = alloca i32, align 4
  %n = alloca i32, align 4
  store volatile i32 8, i32* %a, align 4
  store volatile i32 30, i32* %n, align 4
  %av = load volatile i32, i32* %a, align 4
  %nv = load volatile i32, i32* %n, align 4
  %res = call i32 @llvm.fshl.i32(i32 %av, i32 %av, i32 %nv)
  ret i32 %res
}

; Test 4: Rotate right by variable — generates rorv.
; Uses volatile loads to prevent constant folding.
; CHECK-LABEL: test_ror_var:
; CHECK:       rorv    $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CHECK:       ret     $lr
define i32 @test_ror_var() nounwind {
entry:
  %a = alloca i32, align 4
  %n = alloca i32, align 4
  store volatile i32 8, i32* %a, align 4
  store volatile i32 30, i32* %n, align 4
  %av = load volatile i32, i32* %a, align 4
  %nv = load volatile i32, i32* %n, align 4
  %res = call i32 @llvm.fshr.i32(i32 %av, i32 %av, i32 %nv)
  ret i32 %res
}
