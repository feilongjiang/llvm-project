; NOTE: Tests for Ch6 — Cpu0 global variable addressing modes.
;
; Full 8-case matrix: relocation-model × cpu0-use-small-section × linkage
;
;   reloc    small  linkage    path
;   ------   -----  --------   ----
;   static   no     external   %hi/%lo              (STATIC)
;   static   yes    external   %gp_rel              (SMALL)
;   static   no     internal   %hi/%lo    (same)    (STATIC-INTERNAL)
;   static   yes    internal   %gp_rel    (same)    (SMALL-INTERNAL)
;   pic      no     external   %got_hi/%got_lo      (PIC-LARGE)
;   pic      yes    external   %got                 (PIC-SMALL)
;   pic      no     internal   %got + %lo           (PIC-LOCAL)
;   pic      yes    internal   %got + %lo (same)    (PIC-LOCAL-SMALL)

; ---- 1. static, large section, external linkage ----
; RUN: llc -march=cpu0   -relocation-model=static < %s | FileCheck %s -check-prefix=STATIC
; RUN: llc -march=cpu0el -relocation-model=static < %s | FileCheck %s -check-prefix=STATIC

; STATIC-LABEL: test_global:
; STATIC:       lui  $r{{[0-9]+}}, %hi(gI)
; STATIC:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gI)
; STATIC:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; STATIC:       ret  $lr

; ---- 2. static, small section, external linkage ----
; RUN: llc -march=cpu0   -relocation-model=static -cpu0-use-small-section < %s | FileCheck %s -check-prefix=SMALL
; RUN: llc -march=cpu0el -relocation-model=static -cpu0-use-small-section < %s | FileCheck %s -check-prefix=SMALL

; SMALL-LABEL: test_global:
; SMALL:       ori  $r{{[0-9]+}}, $gp, %gp_rel(gI)
; SMALL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; SMALL:       ret  $lr

; ---- 3. static, large section, internal linkage — same %hi/%lo path ----
; RUN: llc -march=cpu0   -relocation-model=static < %s | FileCheck %s -check-prefix=STATIC-INTERNAL
; RUN: llc -march=cpu0el -relocation-model=static < %s | FileCheck %s -check-prefix=STATIC-INTERNAL

; STATIC-INTERNAL-LABEL: test_static_global:
; STATIC-INTERNAL:       lui  $r{{[0-9]+}}, %hi(gStatic)
; STATIC-INTERNAL:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gStatic)
; STATIC-INTERNAL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; STATIC-INTERNAL:       ret  $lr

; ---- 4. static, small section, internal linkage — same %gp_rel path ----
; RUN: llc -march=cpu0   -relocation-model=static -cpu0-use-small-section < %s | FileCheck %s -check-prefix=SMALL-INTERNAL
; RUN: llc -march=cpu0el -relocation-model=static -cpu0-use-small-section < %s | FileCheck %s -check-prefix=SMALL-INTERNAL

; SMALL-INTERNAL-LABEL: test_static_global:
; SMALL-INTERNAL:       ori  $r{{[0-9]+}}, $gp, %gp_rel(gStatic)
; SMALL-INTERNAL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; SMALL-INTERNAL:       ret  $lr

; ---- 5. PIC, large GOT, external linkage ----
; RUN: llc -march=cpu0   -relocation-model=pic < %s | FileCheck %s -check-prefix=PIC-LARGE
; RUN: llc -march=cpu0el -relocation-model=pic < %s | FileCheck %s -check-prefix=PIC-LARGE

; PIC-LARGE-LABEL: test_global:
; PIC-LARGE:       cpload $t9
; PIC-LARGE:       lui  $r{{[0-9]+}}, %got_hi(gI)
; PIC-LARGE:       addu $r{{[0-9]+}}, $r{{[0-9]+}}, $gp
; PIC-LARGE:       ld   $r{{[0-9]+}}, %got_lo(gI)($r{{[0-9]+}})
; PIC-LARGE:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; PIC-LARGE:       ret  $lr

; ---- 6. PIC, small GOT, external linkage ----
; RUN: llc -march=cpu0   -relocation-model=pic -cpu0-use-small-section < %s | FileCheck %s -check-prefix=PIC-SMALL
; RUN: llc -march=cpu0el -relocation-model=pic -cpu0-use-small-section < %s | FileCheck %s -check-prefix=PIC-SMALL

; PIC-SMALL-LABEL: test_global:
; PIC-SMALL:       cpload $t9
; PIC-SMALL:       ld   $r{{[0-9]+}}, %got(gI)($gp)
; PIC-SMALL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; PIC-SMALL:       ret  $lr

; ---- 7. PIC, large GOT, internal linkage — local GOT entry (%got + %lo) ----
; RUN: llc -march=cpu0   -relocation-model=pic < %s | FileCheck %s -check-prefix=PIC-LOCAL
; RUN: llc -march=cpu0el -relocation-model=pic < %s | FileCheck %s -check-prefix=PIC-LOCAL

; PIC-LOCAL-LABEL: test_static_global:
; PIC-LOCAL:       cpload $t9
; PIC-LOCAL:       ld   $r{{[0-9]+}}, %got(gStatic)($gp)
; PIC-LOCAL:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gStatic)
; PIC-LOCAL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; PIC-LOCAL:       ret  $lr

; ---- 8. PIC, small GOT, internal linkage — internal check precedes small-section
;         check in lowerGlobalAddress, so same %got+%lo path as case 7 ----
; RUN: llc -march=cpu0   -relocation-model=pic -cpu0-use-small-section < %s | FileCheck %s -check-prefix=PIC-LOCAL-SMALL
; RUN: llc -march=cpu0el -relocation-model=pic -cpu0-use-small-section < %s | FileCheck %s -check-prefix=PIC-LOCAL-SMALL

; PIC-LOCAL-SMALL-LABEL: test_static_global:
; PIC-LOCAL-SMALL:       cpload $t9
; PIC-LOCAL-SMALL:       ld   $r{{[0-9]+}}, %got(gStatic)($gp)
; PIC-LOCAL-SMALL:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gStatic)
; PIC-LOCAL-SMALL:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; PIC-LOCAL-SMALL:       ret  $lr

@gStart = global i32 3, align 4
@gI     = global i32 100, align 4

; Mirrors ch6_1.c: test_global() loads from gI (external linkage) and returns it.
define i32 @test_global() nounwind {
entry:
  %c = alloca i32, align 4
  store i32 0, i32* %c, align 4
  %val = load i32, i32* @gI, align 4
  store i32 %val, i32* %c, align 4
  %ret = load i32, i32* %c, align 4
  ret i32 %ret
}

@gStatic = internal global i32 42, align 4

; test_static_global() loads from gStatic (internal linkage).
; Used by cases 3, 4, 7, 8.
define i32 @test_static_global() nounwind {
entry:
  %val = load i32, i32* @gStatic, align 4
  ret i32 %val
}

; ---- Two globals loaded and combined (static large section) ----
; RUN: llc -march=cpu0 -relocation-model=static < %s | FileCheck %s -check-prefix=TWO-GLOBALS

; TWO-GLOBALS-LABEL: test_two_globals:
; TWO-GLOBALS:       lui  $r{{[0-9]+}}, %hi(gB)
; TWO-GLOBALS:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gB)
; TWO-GLOBALS:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; TWO-GLOBALS:       lui  $r{{[0-9]+}}, %hi(gA)
; TWO-GLOBALS:       ori  $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gA)
; TWO-GLOBALS:       ld   $r{{[0-9]+}}, 0($r{{[0-9]+}})
; TWO-GLOBALS:       addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; TWO-GLOBALS:       ret  $lr

@gA = global i32 10, align 4
@gB = global i32 20, align 4

define i32 @test_two_globals() nounwind {
entry:
  %a = load i32, i32* @gA, align 4
  %b = load i32, i32* @gB, align 4
  %sum = add i32 %a, %b
  ret i32 %sum
}
