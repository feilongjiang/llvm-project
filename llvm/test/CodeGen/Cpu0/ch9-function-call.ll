; NOTE: Tests for Ch9 — Cpu0 function call support.
;
; Covers:
;   1. Incoming arguments in $a0/$a1 (register) and stack
;   2. Outgoing call via jalr (PIC) and jsub (static)
;   3. Six-argument function: first 2 in regs, remaining 4 on stack
;   4. Six-argument caller: stack arg stores + call
;   5. GP restore after jalr in PIC mode (.cprestore)
;   6. Recursive call (factorial)
;   7. Variadic function (va_start/va_arg lowering)
;   8. __builtin_frame_address(0) → copy of $fp
;   9. __builtin_return_address(0) → copy of $lr
;  10. Local char array init via memcpy
;  11. Struct return via sret pointer
;
; --- PIC (cpu032I) ---
; RUN: llc -march=cpu0 -mcpu=cpu032I -relocation-model=pic < %s \
; RUN:   | FileCheck %s -check-prefix=PIC
;
; --- PIC (cpu032II) ---
; RUN: llc -march=cpu0 -mcpu=cpu032II -relocation-model=pic < %s \
; RUN:   | FileCheck %s -check-prefix=PIC2
;
; --- Static ---
; RUN: llc -march=cpu0 -mcpu=cpu032I -relocation-model=static < %s \
; RUN:   | FileCheck %s -check-prefix=STATIC
;
; --- Little-endian PIC ---
; RUN: llc -march=cpu0el -mcpu=cpu032I -relocation-model=pic < %s \
; RUN:   | FileCheck %s -check-prefix=EL

; ============================================================================
; Test 1: Incoming arguments — 3 args, first 2 in $a0/$a1, third on stack
; ============================================================================

; PIC-LABEL:    test_incoming_args:
; PIC:          st $r4,
; PIC:          st $r5,
; PIC:          addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; PIC:          ret $lr

; PIC2-LABEL:   test_incoming_args:
; PIC2:         st $r4,
; PIC2:         st $r5,
; PIC2:         addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; PIC2:         ret $lr

; STATIC-LABEL: test_incoming_args:
; STATIC:       st $r4,
; STATIC:       st $r5,
; STATIC:       addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; STATIC:       ret $lr

; EL-LABEL:     test_incoming_args:
; EL:           st $r4,
; EL:           st $r5,
; EL:           addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}
; EL:           ret $lr

define i32 @test_incoming_args(i32 %x1, i32 %x2, i32 %x3) nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  %c = alloca i32, align 4
  %sum = alloca i32, align 4
  store i32 %x1, i32* %a, align 4
  store i32 %x2, i32* %b, align 4
  store i32 %x3, i32* %c, align 4
  %0 = load i32, i32* %a, align 4
  %1 = load i32, i32* %b, align 4
  %2 = add nsw i32 %0, %1
  %3 = load i32, i32* %c, align 4
  %4 = add nsw i32 %2, %3
  store i32 %4, i32* %sum, align 4
  %5 = load i32, i32* %sum, align 4
  ret i32 %5
}

; ============================================================================
; Test 2: Outgoing call — jalr in PIC, jsub in static
; ============================================================================

; PIC-LABEL:    test_outgoing_call:
; PIC:          ld $t9, %call16(sum_i)($gp)
; PIC:          jalr $t9
; PIC:          ld $gp,

; PIC2-LABEL:   test_outgoing_call:
; PIC2:         ld $t9, %call16(sum_i)($gp)
; PIC2:         jalr $t9
; PIC2:         ld $gp,

; STATIC-LABEL: test_outgoing_call:
; STATIC:       jsub sum_i
; STATIC-NOT:   jalr

; EL-LABEL:     test_outgoing_call:
; EL:           ld $t9, %call16(sum_i)($gp)
; EL:           jalr $t9

declare i32 @sum_i(i32)

define i32 @test_outgoing_call() nounwind {
entry:
  %0 = call i32 @sum_i(i32 1)
  ret i32 %0
}

; ============================================================================
; Test 3: 6-argument callee — first 2 args in regs, remaining 4 from stack
; ============================================================================

; PIC-LABEL:    test_6args:
; PIC:          lui $r{{[0-9]+}}, %got_hi(gI)
; PIC:          addu $r{{[0-9]+}}, $r{{[0-9]+}}, $gp
; PIC:          ld $r{{[0-9]+}}, %got_lo(gI)
; PIC:          st $r4,
; PIC:          addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r4
; PIC:          st $r5,
; PIC:          ld $r{{[0-9]+}}, 24($sp)
; PIC:          ret $lr

; STATIC-LABEL: test_6args:
; STATIC:       lui $r{{[0-9]+}}, %hi(gI)
; STATIC:       ori $r{{[0-9]+}}, $r{{[0-9]+}}, %lo(gI)
; STATIC:       addu $r{{[0-9]+}}, $r{{[0-9]+}}, $r4
; STATIC:       ret $lr

@gI = global i32 100, align 4

define i32 @test_6args(i32 %x1, i32 %x2, i32 %x3, i32 %x4, i32 %x5, i32 %x6) nounwind {
entry:
  %a = alloca i32, align 4
  %b = alloca i32, align 4
  %c = alloca i32, align 4
  %d = alloca i32, align 4
  %e = alloca i32, align 4
  %f = alloca i32, align 4
  %sum = alloca i32, align 4
  store i32 %x1, i32* %a, align 4
  store i32 %x2, i32* %b, align 4
  store i32 %x3, i32* %c, align 4
  store i32 %x4, i32* %d, align 4
  store i32 %x5, i32* %e, align 4
  store i32 %x6, i32* %f, align 4
  %0 = load i32, i32* @gI, align 4
  %1 = load i32, i32* %a, align 4
  %2 = add nsw i32 %0, %1
  %3 = load i32, i32* %b, align 4
  %4 = add nsw i32 %2, %3
  %5 = load i32, i32* %c, align 4
  %6 = add nsw i32 %4, %5
  %7 = load i32, i32* %d, align 4
  %8 = add nsw i32 %6, %7
  %9 = load i32, i32* %e, align 4
  %10 = add nsw i32 %8, %9
  %11 = load i32, i32* %f, align 4
  %12 = add nsw i32 %10, %11
  store i32 %12, i32* %sum, align 4
  %13 = load i32, i32* %sum, align 4
  ret i32 %13
}

; ============================================================================
; Test 4: 6-argument caller — stack arg stores + call
; ============================================================================

; PIC-LABEL:    test_6args_caller:
; PIC:          st $r{{[0-9]+}}, {{[0-9]+}}($sp)
; PIC:          st $r{{[0-9]+}}, {{[0-9]+}}($sp)
; PIC:          ld $t9, %call16(test_6args)($gp)
; PIC:          addiu $r4, $zero, 1
; PIC:          addiu $r5, $zero, 2
; PIC:          jalr $t9

; STATIC-LABEL: test_6args_caller:
; STATIC:       st $r{{[0-9]+}}, {{[0-9]+}}($sp)
; STATIC:       st $r{{[0-9]+}}, {{[0-9]+}}($sp)
; STATIC:       addiu $r4, $zero, 1
; STATIC:       addiu $r5, $zero, 2
; STATIC:       jsub test_6args

define i32 @test_6args_caller() nounwind {
entry:
  %a = alloca i32, align 4
  store i32 0, i32* %a, align 4
  %0 = call i32 @test_6args(i32 1, i32 2, i32 3, i32 4, i32 5, i32 6)
  store i32 %0, i32* %a, align 4
  %1 = load i32, i32* %a, align 4
  ret i32 %1
}

; ============================================================================
; Test 5: GP restore — multiple external calls with GP restore between them
; ============================================================================

; PIC-LABEL:    test_gprestore:
; PIC:          .cprestore
; PIC:          ld $t9, %call16(sum_i)($gp)
; PIC:          jalr $t9
; PIC:          nop
; PIC:          ld $gp,
; PIC:          ld $t9, %call16(sum_i)($gp)
; PIC:          jalr $t9
; PIC:          nop
; PIC:          ld $gp,

; STATIC-LABEL: test_gprestore:
; STATIC:       jsub sum_i
; STATIC:       jsub sum_i
; STATIC-NOT:   ld $gp,

define i32 @test_gprestore() nounwind {
entry:
  %a = alloca i32, align 4
  %0 = call i32 @sum_i(i32 1)
  store i32 %0, i32* %a, align 4
  %1 = call i32 @sum_i(i32 2)
  %2 = load i32, i32* %a, align 4
  %3 = add nsw i32 %2, %1
  store i32 %3, i32* %a, align 4
  %4 = load i32, i32* %a, align 4
  ret i32 %4
}

; ============================================================================
; Test 6: Recursive call (factorial)
; ============================================================================

; PIC-LABEL:    test_factorial:
; PIC:          ld $t9, %call16(test_factorial)($gp)
; PIC:          jalr $t9
; PIC:          mul $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

; STATIC-LABEL: test_factorial:
; STATIC:       jsub test_factorial
; STATIC:       mul $r{{[0-9]+}}, $r{{[0-9]+}}, $r{{[0-9]+}}

define i32 @test_factorial(i32 %x) nounwind {
entry:
  %retval = alloca i32, align 4
  %xaddr = alloca i32, align 4
  store i32 %x, i32* %xaddr, align 4
  %0 = load i32, i32* %xaddr, align 4
  %cmp = icmp sgt i32 %0, 0
  br i1 %cmp, label %if.then, label %if.else

if.then:
  %1 = load i32, i32* %xaddr, align 4
  %2 = load i32, i32* %xaddr, align 4
  %sub = sub nsw i32 %2, 1
  %call = call i32 @test_factorial(i32 %sub)
  %mul = mul nsw i32 %1, %call
  store i32 %mul, i32* %retval, align 4
  br label %return

if.else:
  store i32 1, i32* %retval, align 4
  br label %return

return:
  %3 = load i32, i32* %retval, align 4
  ret i32 %3
}

; ============================================================================
; Test 7: Variadic function — va_start / va_arg lowering
; ============================================================================

; PIC-LABEL:    test_vararg:
; PIC:          addiu $sp, $sp,
; PIC:          st $r4,
; PIC:          ret $lr

; STATIC-LABEL: test_vararg:
; STATIC:       addiu $sp, $sp,
; STATIC:       st $r4,
; STATIC:       ret $lr

define i32 @test_vararg(i32 %amount, ...) nounwind {
entry:
  %amount.addr = alloca i32, align 4
  %i = alloca i32, align 4
  %val = alloca i32, align 4
  %sum = alloca i32, align 4
  %vl = alloca i8*, align 4
  store i32 %amount, i32* %amount.addr, align 4
  store i32 0, i32* %i, align 4
  store i32 0, i32* %val, align 4
  store i32 0, i32* %sum, align 4
  %vl.cast = bitcast i8** %vl to i8*
  call void @llvm.va_start(i8* %vl.cast)
  store i32 0, i32* %i, align 4
  br label %for.cond

for.cond:
  %0 = load i32, i32* %i, align 4
  %1 = load i32, i32* %amount.addr, align 4
  %cmp = icmp slt i32 %0, %1
  br i1 %cmp, label %for.body, label %for.end

for.body:
  %ap.cur = load i8*, i8** %vl, align 4
  %ap.next = getelementptr inbounds i8, i8* %ap.cur, i32 4
  store i8* %ap.next, i8** %vl, align 4
  %ap.val.ptr = bitcast i8* %ap.cur to i32*
  %ap.val = load i32, i32* %ap.val.ptr, align 4
  store i32 %ap.val, i32* %val, align 4
  %2 = load i32, i32* %val, align 4
  %3 = load i32, i32* %sum, align 4
  %add = add nsw i32 %3, %2
  store i32 %add, i32* %sum, align 4
  br label %for.inc

for.inc:
  %4 = load i32, i32* %i, align 4
  %inc = add nsw i32 %4, 1
  store i32 %inc, i32* %i, align 4
  br label %for.cond

for.end:
  %vl.cast2 = bitcast i8** %vl to i8*
  call void @llvm.va_end(i8* %vl.cast2)
  %5 = load i32, i32* %sum, align 4
  ret i32 %5
}

declare void @llvm.va_start(i8*) nounwind
declare void @llvm.va_end(i8*) nounwind

; ============================================================================
; Test 8: __builtin_frame_address(0) — returns $fp
; ============================================================================

; PIC-LABEL:    test_frameaddr:
; PIC:          move $fp, $sp
; PIC:          addu $r2, $zero, $fp

; PIC2-LABEL:   test_frameaddr:
; PIC2:         move $fp, $sp
; PIC2:         addu $r2, $zero, $fp

; STATIC-LABEL: test_frameaddr:
; STATIC:       move $fp, $sp
; STATIC:       addu $r2, $zero, $fp

; EL-LABEL:     test_frameaddr:
; EL:           move $fp, $sp
; EL:           addu $r2, $zero, $fp

define i32 @test_frameaddr() nounwind {
entry:
  %0 = call i8* @llvm.frameaddress(i32 0)
  %1 = ptrtoint i8* %0 to i32
  ret i32 %1
}

declare i8* @llvm.frameaddress(i32) nounwind readnone

; ============================================================================
; Test 9: __builtin_return_address(0) — returns $lr
; ============================================================================

; PIC-LABEL:    test_returnaddr:
; PIC:          st $lr, {{[0-9]+}}($sp)
; PIC:          jalr $t9
; PIC:          ld $r2, {{[0-9]+}}($sp)
; PIC:          ret $lr

; PIC2-LABEL:   test_returnaddr:
; PIC2:         st $lr, {{[0-9]+}}($sp)
; PIC2:         jalr $t9
; PIC2:         ld $r2, {{[0-9]+}}($sp)
; PIC2:         ret $lr

; STATIC-LABEL: test_returnaddr:
; STATIC:       st $lr, {{[0-9]+}}($sp)
; STATIC:       jsub fn
; STATIC:       ld $r2, {{[0-9]+}}($sp)
; STATIC:       ret $lr

; EL-LABEL:     test_returnaddr:
; EL:           st $lr, {{[0-9]+}}($sp)
; EL:           jalr $t9
; EL:           ld $r2, {{[0-9]+}}($sp)
; EL:           ret $lr

declare i32 @fn()

define i32 @test_returnaddr() nounwind {
entry:
  %a = alloca i32, align 4
  %0 = call i8* @llvm.returnaddress(i32 0)
  %1 = ptrtoint i8* %0 to i32
  store i32 %1, i32* %a, align 4
  %2 = call i32 @fn()
  %3 = load i32, i32* %a, align 4
  ret i32 %3
}

declare i8* @llvm.returnaddress(i32) nounwind readnone

; ============================================================================
; Test 10: Local char array init via memcpy (jsub memcpy in static)
; ============================================================================

; PIC-LABEL:    test_char_array:
; PIC:          jalr $t9
; PIC:          ret $lr

; STATIC-LABEL: test_char_array:
; STATIC:       jsub memcpy
; STATIC:       ret $lr

@.str.hello_world = private unnamed_addr constant [81 x i8] c"Hello world\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00", align 1
@.str.hello = private unnamed_addr constant [6 x i8] c"Hello\00", align 1

define i32 @test_char_array() nounwind {
entry:
  %retval = alloca i32, align 4
  %str = alloca [81 x i8], align 1
  %s = alloca [6 x i8], align 1
  store i32 0, i32* %retval, align 4
  %str.cast = bitcast [81 x i8]* %str to i8*
  call void @llvm.memcpy.p0i8.p0i8.i32(i8* align 1 %str.cast, i8* align 1 getelementptr inbounds ([81 x i8], [81 x i8]* @.str.hello_world, i32 0, i32 0), i32 81, i1 false)
  %s.cast = bitcast [6 x i8]* %s to i8*
  call void @llvm.memcpy.p0i8.p0i8.i32(i8* align 1 %s.cast, i8* align 1 getelementptr inbounds ([6 x i8], [6 x i8]* @.str.hello, i32 0, i32 0), i32 6, i1 false)
  ret i32 0
}

declare void @llvm.memcpy.p0i8.p0i8.i32(i8* noalias nocapture writeonly, i8* noalias nocapture readonly, i32, i1 immarg) nounwind

; ============================================================================
; Test 11: Struct return via sret pointer in $a0
; ============================================================================

; PIC-LABEL:    test_sret_callee:
; PIC:          ld $r{{[0-9]+}}, %got(gDate)($gp)
; PIC:          st $r{{[0-9]+}}, 20($r4)
; PIC:          st $r{{[0-9]+}}, 0($r4)
; PIC:          addu $r2, $zero, $r4
; PIC:          ret $lr

; STATIC-LABEL: test_sret_callee:
; STATIC:       lui $r{{[0-9]+}}, %hi(gDate)
; STATIC:       st $r{{[0-9]+}}, 20($r4)
; STATIC:       st $r{{[0-9]+}}, 0($r4)
; STATIC:       addu $r2, $zero, $r4
; STATIC:       ret $lr

%struct.Date = type { i32, i32, i32, i32, i32, i32 }

@gDate = internal global %struct.Date { i32 2012, i32 10, i32 12, i32 1, i32 2, i32 3 }, align 4

define void @test_sret_callee(%struct.Date* sret(%struct.Date) align 4 %agg.result) nounwind {
entry:
  %0 = bitcast %struct.Date* %agg.result to i8*
  %1 = bitcast %struct.Date* @gDate to i8*
  call void @llvm.memcpy.p0i8.p0i8.i32(i8* align 4 %0, i8* align 4 %1, i32 24, i1 false)
  ret void
}

; PIC-LABEL:    test_sret_caller:
; PIC:          jalr $t9
; PIC:          ret $lr

; STATIC-LABEL: test_sret_caller:
; STATIC:       jsub test_sret_callee
; STATIC:       ret $lr

define i32 @test_sret_caller() nounwind {
entry:
  %date = alloca %struct.Date, align 4
  call void @test_sret_callee(%struct.Date* sret(%struct.Date) align 4 %date)
  %year.ptr = getelementptr inbounds %struct.Date, %struct.Date* %date, i32 0, i32 0
  %year = load i32, i32* %year.ptr, align 4
  ret i32 %year
}
