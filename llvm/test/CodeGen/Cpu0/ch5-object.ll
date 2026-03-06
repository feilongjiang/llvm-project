; NOTE: Tests for Ch5 — Cpu0 object file (ELF) generation for both endiannesses.
; Verify that llc can produce object files without errors.
;
; RUN: llc -march=cpu0    -relocation-model=pic -filetype=obj -o %t < %s
; RUN: llc -march=cpu0el  -relocation-model=pic -filetype=obj -o %t < %s
;
; Also verify assembly output for both endiannesses.
; RUN: llc -march=cpu0   -relocation-model=pic < %s | FileCheck %s -check-prefix=CPU0
; RUN: llc -march=cpu0el -relocation-model=pic < %s | FileCheck %s -check-prefix=CPU0EL

; CPU0-LABEL:   test_obj:
; CPU0:         addu
; CPU0:         ret     $lr

; CPU0EL-LABEL: test_obj:
; CPU0EL:       addu
; CPU0EL:       ret     $lr

define i32 @test_obj() nounwind {
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

; Verify load and store instructions are emitted.
; CPU0-LABEL:   test_load_store:
; CPU0:         st      $r{{[0-9]+}}, {{[0-9]+}}($sp)
; CPU0:         ld      $r{{[0-9]+}}, {{[0-9]+}}($sp)
; CPU0:         ret     $lr

; CPU0EL-LABEL: test_load_store:
; CPU0EL:       st      $r{{[0-9]+}}, {{[0-9]+}}($sp)
; CPU0EL:       ld      $r{{[0-9]+}}, {{[0-9]+}}($sp)
; CPU0EL:       ret     $lr

define i32 @test_load_store() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 42, i32* %a, align 4
  %av = load volatile i32, i32* %a, align 4
  ret i32 %av
}
