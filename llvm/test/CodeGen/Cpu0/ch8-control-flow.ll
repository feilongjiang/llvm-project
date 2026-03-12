; NOTE: Tests for Ch8 — Cpu0 control flow statements.
;
; Covers:
;   1. Basic conditional branches for cpu032I (CMP + JEQ/JNE/JLT/JGT/JLE/JGE)
;   2. Basic conditional branches for cpu032II (SLT + BEQ/BNE)
;   3. Unconditional branches (JMP)
;   4. Long branch expansion (static): JMP + NOP sequence
;   5. Long branch expansion (PIC): BAL-based long branch sequence
;   6. Unsigned conditional branches (CMPu / SLTu)
;   7. Conditional moves: select(eq/ne) → MOVZ/MOVN + XOR (both ISAs)
;   8. Conditional moves: select(sge/sle) → MOVZ + SLT (cpu032II only)
;   9. select(eq a, 0) → MOVZ $a — zero-compare shortcut (no XOR)
;  10. DelJmp pass: redundant fall-through JMP is eliminated
;
; --- Normal branches ---
; RUN: llc -march=cpu0 -mcpu=cpu032I  -relocation-model=static < %s \
; RUN:   | FileCheck %s -check-prefix=CMP
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=static < %s \
; RUN:   | FileCheck %s -check-prefix=SLT
;
; --- Long branch (static) ---
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=static \
; RUN:   -force-cpu0-long-branch < %s \
; RUN:   | FileCheck %s -check-prefix=LONGSTATIC
;
; --- Long branch (PIC) ---
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=pic \
; RUN:   -force-cpu0-long-branch < %s \
; RUN:   | FileCheck %s -check-prefix=LONGPIC

; ============================================================================
; Test 1: if (a == 0) — equality branch
;   cpu032I:  cmp + jne (inverted: skip if.then when not equal)
;   cpu032II: beq $r, $zero (take branch to if.then when equal)
; ============================================================================

; CMP-LABEL:  test_ifeq:
; CMP:        cmp   $sw,
; CMP:        jne   $sw,

; SLT-LABEL:  test_ifeq:
; SLT:        beq   $r{{[0-9]+}}, $zero,

; LONGSTATIC-LABEL: test_ifeq:
; LONGSTATIC:       beq   $r{{[0-9]+}}, $zero,
; LONGSTATIC:       jmp
; LONGSTATIC-NEXT:  nop

; LONGPIC-LABEL: test_ifeq:
; LONGPIC:       beq   $r{{[0-9]+}}, $zero,
; LONGPIC:       addiu $sp, $sp, -8
; LONGPIC:       st    $lr, 0($sp)
; LONGPIC:       lui   $r1, %hi(
; LONGPIC:       addiu $r1, $r1, %lo(
; LONGPIC:       bal
; LONGPIC:       addu  $r1, $lr, $r1
; LONGPIC:       ld    $lr, 0($sp)
; LONGPIC:       addiu $sp, $sp, 8
; LONGPIC:       jr    $r1
; LONGPIC-NEXT:  nop

define i32 @test_ifeq() nounwind {
entry:
  %a = alloca i32, align 4
  store i32 0, ptr %a, align 4
  %0 = load i32, ptr %a, align 4
  %cmp = icmp eq i32 %0, 0
  br i1 %cmp, label %if.then, label %if.end

if.then:
  %1 = load i32, ptr %a, align 4
  %inc = add i32 %1, 1
  store i32 %inc, ptr %a, align 4
  br label %if.end

if.end:
  %2 = load i32, ptr %a, align 4
  ret i32 %2
}

; ============================================================================
; Test 2: if (a < b) — signed less-than
;   cpu032I:  cmp + jge (inverted)
;   cpu032II: slt + bne (branch if slt result != 0)
;   Long static: slt + bne + jmp + nop (bne skips long branch)
; ============================================================================

; CMP-LABEL:  test_iflt:
; CMP:        cmp   $sw,
; CMP:        jge   $sw,

; SLT-LABEL:  test_iflt:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        bne   $r{{[0-9]+}}, $zero,

; LONGSTATIC-LABEL: test_iflt:
; LONGSTATIC:       slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; LONGSTATIC:       bne   $r{{[0-9]+}}, $zero,
; LONGSTATIC:       jmp
; LONGSTATIC-NEXT:  nop

define i32 @test_iflt() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  %result = alloca i32, align 4
  store volatile i32 2, ptr %a, align 4
  store volatile i32 1, ptr %b, align 4
  store i32 0, ptr %result, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp slt i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  store i32 1, ptr %result, align 4
  br label %if.end

if.end:
  %2 = load i32, ptr %result, align 4
  ret i32 %2
}

; ============================================================================
; Test 3: if (a != b) — not-equal
;   cpu032I:  cmp + jeq (inverted)
;   cpu032II: bne $ra, $rb
; ============================================================================

; CMP-LABEL:  test_ifne:
; CMP:        cmp   $sw,
; CMP:        jeq   $sw,

; SLT-LABEL:  test_ifne:
; SLT:        bne   $r{{[0-9]+}}, $r{{[0-9]+}},

define i32 @test_ifne() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, ptr %a, align 4
  store volatile i32 3, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp ne i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 4: if (a > b) — signed greater-than
;   cpu032I:  cmp + jle (inverted)
;   cpu032II: slt $rb, $ra (swap operands) + bne
; ============================================================================

; CMP-LABEL:  test_ifgt:
; CMP:        cmp   $sw,
; CMP:        jle   $sw,

; SLT-LABEL:  test_ifgt:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        bne   $r{{[0-9]+}}, $zero,

define i32 @test_ifgt() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, ptr %a, align 4
  store volatile i32 3, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp sgt i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 5: if (a <= b) — signed less-or-equal
;   cpu032I:  cmp + jgt (inverted)
;   cpu032II: slt $rb, $ra (swap) + beq (branch if NOT greater)
; ============================================================================

; CMP-LABEL:  test_ifle:
; CMP:        cmp   $sw,
; CMP:        jgt   $sw,

; SLT-LABEL:  test_ifle:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        beq   $r{{[0-9]+}}, $zero,

define i32 @test_ifle() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 3, ptr %a, align 4
  store volatile i32 5, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp sle i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 6: if (a >= b) — signed greater-or-equal
;   cpu032I:  cmp + jlt (inverted)
;   cpu032II: slt $ra, $rb + beq (branch if NOT less)
; ============================================================================

; CMP-LABEL:  test_ifge:
; CMP:        cmp   $sw,
; CMP:        jlt   $sw,

; SLT-LABEL:  test_ifge:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        beq   $r{{[0-9]+}}, $zero,

define i32 @test_ifge() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, ptr %a, align 4
  store volatile i32 3, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp sge i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 7: Unconditional branch — if-else forces a JMP
;   cpu032I:  phi is lowered via jeq (inverted fallthrough) — no explicit jmp
;             in the true arm; the false-value assignment is the fallthrough.
;   cpu032II: BEQ goes to the true arm; the false arm needs an explicit JMP
;             to skip over the true arm's assignments.
; ============================================================================

; CMP-LABEL:  test_uncond:
; CMP:        jeq   $sw,

; SLT-LABEL:  test_uncond:
; SLT:        jmp

define i32 @test_uncond() nounwind {
entry:
  %a = alloca i32, align 4
  store volatile i32 10, ptr %a, align 4
  %0 = load volatile i32, ptr %a, align 4
  %cmp = icmp eq i32 %0, 0
  br i1 %cmp, label %if.then, label %if.else

if.then:
  br label %if.end

if.else:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 2, %if.else ]
  ret i32 %r
}

; ============================================================================
; Test 8: Unsigned less-than branch (icmp ult)
;   cpu032I:  cmpu $sw + jge $sw (inverted: jump over if.then when NOT u<)
;   cpu032II: sltu $tmp + bne $tmp, $zero (1 when a u< b)
; ============================================================================

; CMP-LABEL:  test_ifult:
; CMP:        cmpu  $sw,
; CMP:        jge   $sw,

; SLT-LABEL:  test_ifult:
; SLT:        sltu  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        bne   $r{{[0-9]+}}, $zero,

define i32 @test_ifult() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 2, ptr %a, align 4
  store volatile i32 3, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp ult i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 9: Unsigned greater-than branch (icmp ugt)
;   cpu032I:  cmpu $sw + jle $sw (inverted: jump over if.then when NOT u>)
;   cpu032II: sltu $tmp, $b, $a (1 when b u< a, i.e. a u> b) + bne
; ============================================================================

; CMP-LABEL:  test_ifugt:
; CMP:        cmpu  $sw,
; CMP:        jle   $sw,

; SLT-LABEL:  test_ifugt:
; SLT:        sltu  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        bne   $r{{[0-9]+}}, $zero,

define i32 @test_ifugt() nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  store volatile i32 5, ptr %a, align 4
  store volatile i32 3, ptr %b, align 4
  %0 = load volatile i32, ptr %a, align 4
  %1 = load volatile i32, ptr %b, align 4
  %cmp = icmp ugt i32 %0, %1
  br i1 %cmp, label %if.then, label %if.end

if.then:
  br label %if.end

if.end:
  %r = phi i32 [ 1, %if.then ], [ 0, %entry ]
  ret i32 %r
}

; ============================================================================
; Test 10: Conditional move — select(eq a, b) → XOR + MOVZ (both ISAs)
;   Pattern (MovzPats1): movz $T, (xor $a, $b), $F
;   Semantics: xor == 0 iff a == b → output T when equal
; ============================================================================

; CMP-LABEL:  test_select_eq:
; CMP:        xor   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CMP:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; SLT-LABEL:  test_select_eq:
; SLT:        xor   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_select_eq() nounwind {
  %a.s = alloca i32, align 4
  %b.s = alloca i32, align 4
  %t.s = alloca i32, align 4
  %f.s = alloca i32, align 4
  store volatile i32 5,   ptr %a.s, align 4
  store volatile i32 5,   ptr %b.s, align 4
  store volatile i32 100, ptr %t.s, align 4
  store volatile i32 200, ptr %f.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %b = load volatile i32, ptr %b.s, align 4
  %t = load volatile i32, ptr %t.s, align 4
  %f = load volatile i32, ptr %f.s, align 4
  %cmp = icmp eq i32 %a, %b
  %r = select i1 %cmp, i32 %t, i32 %f
  ret i32 %r
}

; ============================================================================
; Test 11: Conditional move — select(ne a, b) → XOR + MOVN (both ISAs)
;   Pattern (MovnPats): movn $T, (xor $a, $b), $F
;   Semantics: xor != 0 iff a != b → output T when not equal
; ============================================================================

; CMP-LABEL:  test_select_ne:
; CMP:        xor   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; CMP:        movn  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; SLT-LABEL:  test_select_ne:
; SLT:        xor   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        movn  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_select_ne() nounwind {
  %a.s = alloca i32, align 4
  %b.s = alloca i32, align 4
  %t.s = alloca i32, align 4
  %f.s = alloca i32, align 4
  store volatile i32 5,   ptr %a.s, align 4
  store volatile i32 3,   ptr %b.s, align 4
  store volatile i32 100, ptr %t.s, align 4
  store volatile i32 200, ptr %f.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %b = load volatile i32, ptr %b.s, align 4
  %t = load volatile i32, ptr %t.s, align 4
  %f = load volatile i32, ptr %f.s, align 4
  %cmp = icmp ne i32 %a, %b
  %r = select i1 %cmp, i32 %t, i32 %f
  ret i32 %r
}

; ============================================================================
; Test 12: Conditional move — select(sge a, b) → SLT + MOVZ (cpu032II only)
;   Pattern (MovzPats0Slt): movz $T, slt($a, $b), $F
;   Semantics: slt==0 iff NOT(a<b) iff a>=b → output T when sge
;   cpu032I fallback: CMP-based setge produces i32, generic movn catches it
; ============================================================================

; CMP-LABEL:  test_select_ge:
; CMP:        cmp   $sw,
; CMP:        movn  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; SLT-LABEL:  test_select_ge:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_select_ge() nounwind {
  %a.s = alloca i32, align 4
  %b.s = alloca i32, align 4
  %t.s = alloca i32, align 4
  %f.s = alloca i32, align 4
  store volatile i32 5,   ptr %a.s, align 4
  store volatile i32 3,   ptr %b.s, align 4
  store volatile i32 100, ptr %t.s, align 4
  store volatile i32 200, ptr %f.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %b = load volatile i32, ptr %b.s, align 4
  %t = load volatile i32, ptr %t.s, align 4
  %f = load volatile i32, ptr %f.s, align 4
  %cmp = icmp sge i32 %a, %b
  %r = select i1 %cmp, i32 %t, i32 %f
  ret i32 %r
}

; ============================================================================
; Test 13: Conditional move — select(sle a, b) → SLT(b,a) + MOVZ (cpu032II)
;   Pattern (MovzPats0Slt): movz $T, slt($b, $a), $F
;   Semantics: slt(b,a)==0 iff NOT(b<a) iff a<=b → output T when sle
;   cpu032I fallback: CMP-based setle produces i32, generic movn catches it
; ============================================================================

; CMP-LABEL:  test_select_le:
; CMP:        cmp   $sw,
; CMP:        movn  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; SLT-LABEL:  test_select_le:
; SLT:        slt   $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; SLT:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_select_le() nounwind {
  %a.s = alloca i32, align 4
  %b.s = alloca i32, align 4
  %t.s = alloca i32, align 4
  %f.s = alloca i32, align 4
  store volatile i32 3,   ptr %a.s, align 4
  store volatile i32 5,   ptr %b.s, align 4
  store volatile i32 100, ptr %t.s, align 4
  store volatile i32 200, ptr %f.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %b = load volatile i32, ptr %b.s, align 4
  %t = load volatile i32, ptr %t.s, align 4
  %f = load volatile i32, ptr %f.s, align 4
  %cmp = icmp sle i32 %a, %b
  %r = select i1 %cmp, i32 %t, i32 %f
  ret i32 %r
}

; ============================================================================
; Test 14: Conditional move — select(eq a, 0) → MOVZ $a (no XOR)
;   Special case in MovzPats1: when rhs == 0, condition reg is used directly.
;   movz $T, $a, $F — output T when $a == 0 (zero means equal-to-zero)
; ============================================================================

; CMP-LABEL:  test_select_eq_zero:
; CMP-NOT:    xor
; CMP:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; SLT-LABEL:  test_select_eq_zero:
; SLT-NOT:    xor
; SLT:        movz  $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_select_eq_zero() nounwind {
  %a.s = alloca i32, align 4
  %t.s = alloca i32, align 4
  %f.s = alloca i32, align 4
  store volatile i32 0,   ptr %a.s, align 4
  store volatile i32 100, ptr %t.s, align 4
  store volatile i32 200, ptr %f.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %t = load volatile i32, ptr %t.s, align 4
  %f = load volatile i32, ptr %f.s, align 4
  %cmp = icmp eq i32 %a, 0
  %r = select i1 %cmp, i32 %t, i32 %f
  ret i32 %r
}

; ============================================================================
; Test 15: DelJmp — redundant JMP to immediately-following block is removed.
;
; cpu032I layout:  entry | if.then | if.end
;   entry:   cmp; jne if.end (inverted: skip if.then when a != 0)
;   if.then: st 1            (no jmp to if.end — DelJmp removed it)
;   if.end:  ld; ret
;   CHECK-NOT: jmp confirms no unconditional branch survived in this function.
;
; cpu032II layout: entry(beq→if.then) | entry-false(jmp→if.end) | if.then | if.end
;   entry:        beq $r, $zero, if.then  (take branch when a == 0)
;   entry-false:  jmp if.end              (necessary: skips if.then on false path)
;   if.then:      st 1                    (no jmp to if.end — DelJmp removed it)
;   if.end:       ld; ret
;   The cpu032II entry-false jmp is EXPECTED (it bridges a real layout gap).
;   DelJmp's contribution is the elimination of if.then's jmp to the adjacent if.end.
; ============================================================================

; CMP-LABEL:  test_deljmp:
; CMP:        jne   $sw,
; CMP-NOT:    jmp
; CMP:        ret

; SLT-LABEL:  test_deljmp:
; SLT:        beq   $r{{[0-9]+}}, $zero,
; SLT:        jmp
; SLT:        ret

define i32 @test_deljmp() nounwind {
entry:
  %a.s = alloca i32, align 4
  %p.s = alloca i32, align 4
  store volatile i32 0, ptr %a.s, align 4
  store i32 0, ptr %p.s, align 4
  %a = load volatile i32, ptr %a.s, align 4
  %cmp = icmp eq i32 %a, 0
  br i1 %cmp, label %if.then, label %if.end

if.then:
  store i32 1, ptr %p.s, align 4
  br label %if.end

if.end:
  %r = load i32, ptr %p.s, align 4
  ret i32 %r
}
