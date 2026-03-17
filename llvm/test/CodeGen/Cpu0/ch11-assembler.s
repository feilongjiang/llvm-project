# RUN: llvm-mc -triple cpu0 -filetype=obj %s -o %t.o
# RUN: llvm-objdump -d %t.o | FileCheck %s
# RUN: llvm-mc -triple cpu0el -filetype=obj %s -o %t.el.o
# RUN: llvm-objdump -d %t.el.o | FileCheck %s

# Test ignored directives (.ent, .end, .frame, .mask, .fmask)
  .ent main
  .frame $sp, 8, $lr
  .mask 0x00000000, 0
  .fmask 0x00000000, 0
  .set noreorder
  .set nomacro

# --- Basic arithmetic/logic instructions ---

# CHECK: addiu $r2, $zero, 5
  addiu $2, $zero, 5

# CHECK: addu $r2, $r3, $r4
  addu $2, $3, $4

# CHECK: subu $r2, $r3, $r4
  subu $2, $3, $4

# CHECK: and $r2, $r3, $r4
  and $2, $3, $4

# CHECK: or $r2, $r3, $r4
  or $2, $3, $4

# CHECK: xor $r2, $r3, $r4
  xor $2, $3, $4

# CHECK: andi $r2, $r3, 10
  andi $2, $3, 10

# CHECK: ori $r2, $r3, 10
  ori $2, $3, 10

# CHECK: xori $r2, $r3, 10
  xori $2, $3, 10

# CHECK: lui $r2, 100
  lui $2, 100

# CHECK: shl $r2, $r3, 2
  shl $2, $3, 2

# CHECK: shr $r2, $r3, 2
  shr $2, $3, 2

# CHECK: sra $r2, $r3, 2
  sra $2, $3, 2

# CHECK: rol $r2, $r3, 2
  rol $2, $3, 2

# CHECK: ror $r2, $r3, 2
  ror $2, $3, 2

# --- HI/LO move instructions ---

# CHECK: mfhi $r3
  mfhi $3

# CHECK: mflo $r2
  mflo $2

# CHECK: mthi $r2
  mthi $2

# CHECK: mtlo $r2
  mtlo $2

# --- Load/Store with various offsets ---

# CHECK: ld $r2, 0($sp)
  ld $2, 0($sp)

# CHECK: ld $r3, 16($fp)
  ld $3, 16($fp)

# CHECK: st $r2, 0($sp)
  st $2, 0($sp)

# CHECK: st $r4, -4($sp)
  st $4, -4($sp)

# CHECK: lb $r2, 0($sp)
  lb $2, 0($sp)

# CHECK: lbu $r2, 0($sp)
  lbu $2, 0($sp)

# CHECK: sb $r2, 0($sp)
  sb $2, 0($sp)

# CHECK: lh $r2, 0($sp)
  lh $2, 0($sp)

# CHECK: lhu $r2, 0($sp)
  lhu $2, 0($sp)

# CHECK: sh $r2, 0($sp)
  sh $2, 0($sp)

# --- Register by number ---

# CHECK: addiu $zero, $zero, 0
  addiu $0, $0, 0

# --- Register by AsmName (rN aliases used by inline asm) ---

# CHECK: addu $r2, $r3, $r2
  addu $r2, $r3, $r2

# CHECK: addiu $r2, $r2, -5
  addiu $r2, $r2, -5

# CHECK: ori $r2, $r2, 255
  ori $r2, $r2, 255

# CHECK: subu $r2, $r2, $r3
  subu $r2, $r2, $r3

# --- Memory operands with imm($rN) format ---

# CHECK: ld $r2, 0($r2)
  ld $r2, 0($r2)

# CHECK: st $r3, 4($r5)
  st $r3, 4($r5)

# CHECK: ld $r4, -8($r9)
  ld $r4, -8($r9)

# --- Nop and Ret ---

# CHECK: nop
  nop

# CHECK: ret $lr
  ret $lr

# --- li pseudo-instruction: three expansion paths ---

# li small unsigned (0-65535) -> ori
# CHECK: ori $r2, $zero, 0
  li $2, 0

# CHECK: ori $r2, $zero, 65535
  li $2, 65535

# CHECK: ori $r2, $zero, 100
  li $2, 100

# li negative (-32768 to -1) -> addiu
# CHECK: addiu $r2, $zero, -1
  li $2, -1

# CHECK: addiu $r2, $zero, -32768
  li $2, -32768

# li large (needs lui+ori)
# CHECK: lui $r2, 1
# CHECK-NEXT: ori $r2, $r2, 0
  li $2, 65536

# CHECK: lui $r2, 4660
# CHECK-NEXT: ori $r2, $r2, 22136
  li $2, 0x12345678

# --- la pseudo-instruction ---

# la small (fits in addiu)
# CHECK: addiu $r2, $zero, 100
  la $2, 100

# la large (needs lui+ori)
# CHECK: lui $r2, 1
# CHECK-NEXT: ori $r2, $r2, 0
  la $2, 65536

# --- %hi/%lo relocations ---

# CHECK: lui $r2
  lui $2, %hi(symbol)

# CHECK: ori $r2, $r2
  ori $2, $2, %lo(symbol)

# --- .set macro/reorder restore ---

  .set macro
  .set reorder
  .end main
