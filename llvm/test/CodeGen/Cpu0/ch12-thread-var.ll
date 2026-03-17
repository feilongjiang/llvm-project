; NOTE: Tests for Ch12 — Cpu0 thread-local storage (C++ support).
;
; Covers all 4 TLS models:
;   1. LocalExec — static relocation, generates %tp_hi / %tp_lo
;   2. InitialExec — static relocation, generates %gottprel (GOT load)
;   3. GeneralDynamic — PIC relocation, calls __tls_get_addr with %tlsgd
;   4. LocalDynamic — PIC relocation, calls __tls_get_addr with %tlsldm + dtp offset
;
; --- LocalExec TLS model (static) ---
; RUN: llc -march=cpu0 -relocation-model=static -filetype=asm < %s \
; RUN:   | FileCheck %s --check-prefix=LOCALEXEC

@t_le = thread_local(localexec) global i32 0, align 4

define i32 @read_tls_localexec() nounwind {
; LOCALEXEC-LABEL: read_tls_localexec:
; LOCALEXEC: %tp_hi(t_le)
; LOCALEXEC: %tp_lo(t_le)
  %val = load i32, i32* @t_le, align 4
  ret i32 %val
}

; --- InitialExec TLS model (static) ---
; RUN: llc -march=cpu0 -relocation-model=static -filetype=asm < %s \
; RUN:   | FileCheck %s --check-prefix=INITEXEC

@t_ie = external thread_local(initialexec) global i32

define i32 @read_tls_initialexec() nounwind {
; INITEXEC-LABEL: read_tls_initialexec:
; INITEXEC: %gottprel(t_ie)
  %val = load i32, i32* @t_ie, align 4
  ret i32 %val
}

; --- GeneralDynamic TLS model (PIC) ---
; RUN: llc -march=cpu0 -relocation-model=pic -filetype=asm < %s \
; RUN:   | FileCheck %s --check-prefix=GD

@t_gd = external thread_local global i32

define i32 @read_tls_generaldynamic() nounwind {
; GD-LABEL: read_tls_generaldynamic:
; GD: __tls_get_addr
; GD: %tlsgd(t_gd)
  %val = load i32, i32* @t_gd, align 4
  ret i32 %val
}

; --- LocalDynamic TLS model (PIC) ---
; RUN: llc -march=cpu0 -relocation-model=pic -filetype=asm < %s \
; RUN:   | FileCheck %s --check-prefix=LD

@t_ld = external thread_local(localdynamic) global i32

define i32 @read_tls_localdynamic() nounwind {
; LD-LABEL: read_tls_localdynamic:
; LD: __tls_get_addr
; LD: %tlsldm(t_ld)
; LD: %dtp_hi(t_ld)
; LD: %dtp_lo(t_ld)
  %val = load i32, i32* @t_ld, align 4
  ret i32 %val
}
