; RUN: llc -march=cpu0 -mcpu=cpu032I -relocation-model=static -filetype=obj %s -o %t.o
; RUN: llvm-objdump -d %t.o | FileCheck %s -check-prefix=OBJ32I
; RUN: llc -march=cpu0el -mcpu=cpu032I -relocation-model=static -filetype=obj %s -o %t.el.o
; RUN: llvm-objdump -d %t.el.o | FileCheck %s -check-prefix=OBJ32I
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=static -filetype=obj %s -o %t.ii.o
; RUN: llvm-objdump -d %t.ii.o | FileCheck %s -check-prefix=OBJ32II

@g = global i32 5, align 4

; === Test 1: Basic arithmetic, branch, global load ===
; Covers: addu, subu, shl, shr, cmp, jne (Cpu032I), lui, ori, ld, ret
define i32 @test_basic(i32 %a, i32 %b) nounwind {
entry:
  %add = add nsw i32 %a, %b
  %sub = sub nsw i32 %a, %b
  %shl = shl i32 %a, 2
  %shr = lshr i32 %b, 3
  %cmp = icmp eq i32 %add, %sub
  br i1 %cmp, label %if.then, label %if.end

if.then:
  %gval = load i32, i32* @g, align 4
  %result = add nsw i32 %gval, %shl
  br label %if.end

if.end:
  %retval = phi i32 [ %result, %if.then ], [ %shr, %entry ]
  ret i32 %retval
}

; OBJ32I-LABEL: <test_basic>:
; OBJ32I:         shr
; OBJ32I:         subu
; OBJ32I:         addu
; OBJ32I:         cmp
; OBJ32I:         jne
; OBJ32I:         shl
; OBJ32I:         lui
; OBJ32I:         ori
; OBJ32I:         ld
; OBJ32I:         addu
; OBJ32I:         ret	$lr

; === Test 2: Prologue/epilogue, stack ops, jsub, negative immediates ===
; Covers: addiu $sp (negative), st $lr, jsub, ld $lr, addiu $sp (positive)
define i32 @test_call(i32 %a) nounwind {
entry:
  %local = alloca i32, align 4
  store i32 %a, i32* %local, align 4
  %call = call i32 @test_basic(i32 %a, i32 %a)
  %val = load i32, i32* %local, align 4
  %result = add nsw i32 %call, %val
  ret i32 %result
}

; OBJ32I-LABEL: <test_call>:
; OBJ32I:         addiu	$sp, $sp, -16
; OBJ32I:         st	$lr,
; OBJ32I:         st	$r4,
; OBJ32I:         jsub
; OBJ32I:         ld
; OBJ32I:         addu
; OBJ32I:         ld	$lr,
; OBJ32I:         addiu	$sp, $sp, 16
; OBJ32I:         ret	$lr

; === Test 3: Backward branch (negative offset), loop ===
; Covers: DecodeBranch24Target with negative offset (jne $sw, -N)
define i32 @test_loop(i32 %n) nounwind {
entry:
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %inc, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %add, %loop ]
  %add = add nsw i32 %sum, %i
  %inc = add nsw i32 %i, 1
  %cmp = icmp eq i32 %inc, %n
  br i1 %cmp, label %exit, label %loop

exit:
  ret i32 %add
}

; OBJ32I-LABEL: <test_loop>:
; OBJ32I:         addiu	$r3, $zero, 0
; OBJ32I:         addu
; OBJ32I:         addu
; OBJ32I:         addiu	$r3, $r3, 1
; OBJ32I:         cmp
; OBJ32I:         jne	$sw, -16
; OBJ32I:         nop
; OBJ32I:         ret	$lr

; === Test 4: Indirect call (jalr) ===
; Covers: jalr $t9 (JumpLinkReg)
define i32 @test_indirect(i32 (i32, i32)* %fp, i32 %arg) nounwind {
entry:
  %result = call i32 %fp(i32 %arg, i32 %arg)
  ret i32 %result
}

; OBJ32I-LABEL: <test_indirect>:
; OBJ32I:         addiu	$sp, $sp, -16
; OBJ32I:         st	$lr,
; OBJ32I:         jalr	$t9
; OBJ32I:         ld	$lr,
; OBJ32I:         ret	$lr

; === Test 5: Cpu032II variant ===
; Covers: beq (DecodeBranch16Target), slt
; OBJ32II-LABEL: <test_loop>:
; OBJ32II:         addiu
; OBJ32II:         addu
; OBJ32II:         addu
; OBJ32II:         addiu
; OBJ32II:         beq
