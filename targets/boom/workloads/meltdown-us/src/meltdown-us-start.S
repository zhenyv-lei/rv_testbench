#include "encoding.h"

#if __riscv_xlen == 64
# define LREG ld
# define SREG sd
# define REGBYTES 8
#else
# define LREG lw
# define SREG sw
# define REGBYTES 4
#endif

  .section ".text.init"
  .globl _start
_start:
  li  x1, 0
  li  x2, 0
  li  x3, 0
  li  x4, 0
  li  x5, 0
  li  x6, 0
  li  x7, 0
  li  x8, 0
  li  x9, 0
  li  x10,0
  li  x11,0
  li  x12,0
  li  x13,0
  li  x14,0
  li  x15,0
  li  x16,0
  li  x17,0
  li  x18,0
  li  x19,0
  li  x20,0
  li  x21,0
  li  x22,0
  li  x23,0
  li  x24,0
  li  x25,0
  li  x26,0
  li  x27,0
  li  x28,0
  li  x29,0
  li  x30,0
  li  x31,0

  li t0, MSTATUS_FS | MSTATUS_XS
  csrs mstatus, t0

  la t0, meltdown_us_trap_entry
  csrw mtvec, t0

.option push
.option norelax
  la gp, __global_pointer$
.option pop

  la  tp, _end + 63
  and tp, tp, -64

  csrr a0, mhartid
  li a1, 1
1:bgeu a0, a1, 1b

#define STKSHIFT 17
  sll a2, a0, STKSHIFT
  add tp, tp, a2
  add sp, a0, 1
  sll sp, sp, STKSHIFT
  add sp, sp, tp

  call main
  mv a0, a0
  call meltdown_us_exit

  .align 2
  .globl meltdown_us_trap_entry
meltdown_us_trap_entry:
  addi sp, sp, -272

  SREG x1, 1*REGBYTES(sp)
  SREG x2, 2*REGBYTES(sp)
  SREG x3, 3*REGBYTES(sp)
  SREG x4, 4*REGBYTES(sp)
  SREG x5, 5*REGBYTES(sp)
  SREG x6, 6*REGBYTES(sp)
  SREG x7, 7*REGBYTES(sp)
  SREG x8, 8*REGBYTES(sp)
  SREG x9, 9*REGBYTES(sp)
  SREG x10, 10*REGBYTES(sp)
  SREG x11, 11*REGBYTES(sp)
  SREG x12, 12*REGBYTES(sp)
  SREG x13, 13*REGBYTES(sp)
  SREG x14, 14*REGBYTES(sp)
  SREG x15, 15*REGBYTES(sp)
  SREG x16, 16*REGBYTES(sp)
  SREG x17, 17*REGBYTES(sp)
  SREG x18, 18*REGBYTES(sp)
  SREG x19, 19*REGBYTES(sp)
  SREG x20, 20*REGBYTES(sp)
  SREG x21, 21*REGBYTES(sp)
  SREG x22, 22*REGBYTES(sp)
  SREG x23, 23*REGBYTES(sp)
  SREG x24, 24*REGBYTES(sp)
  SREG x25, 25*REGBYTES(sp)
  SREG x26, 26*REGBYTES(sp)
  SREG x27, 27*REGBYTES(sp)
  SREG x28, 28*REGBYTES(sp)
  SREG x29, 29*REGBYTES(sp)
  SREG x30, 30*REGBYTES(sp)
  SREG x31, 31*REGBYTES(sp)

  csrr a0, mcause
  csrr a1, mepc
  csrr a2, mtval
  mv a3, sp
  jal meltdown_us_handle_trap
  andi t0, a0, 1
  beqz t0, restore_user_context
  addi a0, a0, -1
  la t0, meltdown_us_debug_target
  SREG a0, 0(t0)
  la t0, meltdown_us_debug_trap_sp
  SREG sp, 0(t0)
  csrw mepc, a0
  csrw satp, x0
  sfence.vma
  li t0, MSTATUS_MPP
  csrs mstatus, t0
  addi sp, sp, 272
  mret

restore_user_context:
  csrw mepc, a0

  LREG x1, 1*REGBYTES(sp)
  LREG x3, 3*REGBYTES(sp)
  LREG x4, 4*REGBYTES(sp)
  LREG x5, 5*REGBYTES(sp)
  LREG x6, 6*REGBYTES(sp)
  LREG x7, 7*REGBYTES(sp)
  LREG x8, 8*REGBYTES(sp)
  LREG x9, 9*REGBYTES(sp)
  LREG x10, 10*REGBYTES(sp)
  LREG x11, 11*REGBYTES(sp)
  LREG x12, 12*REGBYTES(sp)
  LREG x13, 13*REGBYTES(sp)
  LREG x14, 14*REGBYTES(sp)
  LREG x15, 15*REGBYTES(sp)
  LREG x16, 16*REGBYTES(sp)
  LREG x17, 17*REGBYTES(sp)
  LREG x18, 18*REGBYTES(sp)
  LREG x19, 19*REGBYTES(sp)
  LREG x20, 20*REGBYTES(sp)
  LREG x21, 21*REGBYTES(sp)
  LREG x22, 22*REGBYTES(sp)
  LREG x23, 23*REGBYTES(sp)
  LREG x24, 24*REGBYTES(sp)
  LREG x25, 25*REGBYTES(sp)
  LREG x26, 26*REGBYTES(sp)
  LREG x27, 27*REGBYTES(sp)
  LREG x28, 28*REGBYTES(sp)
  LREG x29, 29*REGBYTES(sp)
  LREG x30, 30*REGBYTES(sp)
  LREG x31, 31*REGBYTES(sp)

  addi sp, sp, 272
  mret

.section ".text"
.align 2
.globl meltdown_us_enter_user1
meltdown_us_enter_user1:
  addi sp, sp, -(14*REGBYTES)
  SREG ra, 0*REGBYTES(sp)
  SREG s0, 1*REGBYTES(sp)
  SREG s1, 2*REGBYTES(sp)
  SREG s2, 3*REGBYTES(sp)
  SREG s3, 4*REGBYTES(sp)
  SREG s4, 5*REGBYTES(sp)
  SREG s5, 6*REGBYTES(sp)
  SREG s6, 7*REGBYTES(sp)
  SREG s7, 8*REGBYTES(sp)
  SREG s8, 9*REGBYTES(sp)
  SREG s9, 10*REGBYTES(sp)
  SREG s10, 11*REGBYTES(sp)
  SREG s11, 12*REGBYTES(sp)

  la t0, m_return_pc
  la t1, 1f
  SREG t1, 0(t0)

  csrr t0, mstatus
  li t1, ~(MSTATUS_MPP | MSTATUS_MPRV)
  and t0, t0, t1
  csrw mstatus, t0
  la t0, meltdown_us_satp_value
  LREG t0, 0(t0)
  csrw satp, t0
  sfence.vma
  csrw mepc, a0
  mv a0, a1
  mret
1:
  LREG ra, 0*REGBYTES(sp)
  LREG s0, 1*REGBYTES(sp)
  LREG s1, 2*REGBYTES(sp)
  LREG s2, 3*REGBYTES(sp)
  LREG s3, 4*REGBYTES(sp)
  LREG s4, 5*REGBYTES(sp)
  LREG s5, 6*REGBYTES(sp)
  LREG s6, 7*REGBYTES(sp)
  LREG s7, 8*REGBYTES(sp)
  LREG s8, 9*REGBYTES(sp)
  LREG s9, 10*REGBYTES(sp)
  LREG s10, 11*REGBYTES(sp)
  LREG s11, 12*REGBYTES(sp)
  addi sp, sp, (14*REGBYTES)
  ret

.align 2
.globl meltdown_us_enter_user2
meltdown_us_enter_user2:
  addi sp, sp, -(14*REGBYTES)
  SREG ra, 0*REGBYTES(sp)
  SREG s0, 1*REGBYTES(sp)
  SREG s1, 2*REGBYTES(sp)
  SREG s2, 3*REGBYTES(sp)
  SREG s3, 4*REGBYTES(sp)
  SREG s4, 5*REGBYTES(sp)
  SREG s5, 6*REGBYTES(sp)
  SREG s6, 7*REGBYTES(sp)
  SREG s7, 8*REGBYTES(sp)
  SREG s8, 9*REGBYTES(sp)
  SREG s9, 10*REGBYTES(sp)
  SREG s10, 11*REGBYTES(sp)
  SREG s11, 12*REGBYTES(sp)

  la t0, m_return_pc
  la t1, 1f
  SREG t1, 0(t0)

  csrr t0, mstatus
  li t1, ~(MSTATUS_MPP | MSTATUS_MPRV)
  and t0, t0, t1
  csrw mstatus, t0
  la t0, meltdown_us_satp_value
  LREG t0, 0(t0)
  csrw satp, t0
  sfence.vma
  csrw mepc, a0
  mv a0, a1
  mv a1, a2
  mret
1:
  LREG ra, 0*REGBYTES(sp)
  LREG s0, 1*REGBYTES(sp)
  LREG s1, 2*REGBYTES(sp)
  LREG s2, 3*REGBYTES(sp)
  LREG s3, 4*REGBYTES(sp)
  LREG s4, 5*REGBYTES(sp)
  LREG s5, 6*REGBYTES(sp)
  LREG s6, 7*REGBYTES(sp)
  LREG s7, 8*REGBYTES(sp)
  LREG s8, 9*REGBYTES(sp)
  LREG s9, 10*REGBYTES(sp)
  LREG s10, 11*REGBYTES(sp)
  LREG s11, 12*REGBYTES(sp)
  addi sp, sp, (14*REGBYTES)
  ret

.section ".tohost","aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
