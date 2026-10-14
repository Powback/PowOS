/*
 * tcg-check: tells which kinds of AArch64 instructions an emulator gets wrong. Each group runs many iterations
 * on pseudo-random inputs (enough that qemu-wasm compiles the loop to Wasm, not just interprets it) and prints a
 * checksum. Run natively for the expected values; boot it as /init under qemu-wasm and compare (run.sh).
 * Static, no libc dependency beyond what -static gives; powers off when done.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <arm_neon.h>
#include <stdatomic.h>
#include <unistd.h>
#include <stdlib.h>
#include <arm_acle.h>
#include <sys/mman.h>
#include <sys/reboot.h>

#define N 20000

static uint64_t s = 0x9E3779B97F4A7C15ull;
static inline uint64_t rnd(void) { /* xorshift64*, computed the same everywhere */
    s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
    return s * 0x2545F4914F6CDD1Dull;
}
static inline uint64_t mix(uint64_t h, uint64_t v) { return (h ^ v) * 0x100000001B3ull + (h >> 29); }
static volatile uint64_t sink; /* keeps the compiler from folding constants */

#define GROUP(name, ...) do { uint64_t h = 0xcbf29ce484222325ull; s = 0x9E3779B97F4A7C15ull; \
    for (int i = 0; i < N; i++) { uint64_t a = rnd(), b = rnd(), c = rnd(); (void)c; __VA_ARGS__ } \
    printf("%-10s %016llx\n", name, (unsigned long long)h); fflush(stdout); } while (0)

static uint64_t rotl(uint64_t x, int r) { return (x << (r & 63)) | (x >> ((64 - r) & 63)); }

/* SipHash-2-4, as systemd's hashmaps use it */
static uint64_t siphash(const uint8_t *in, size_t len, uint64_t k0, uint64_t k1) {
    uint64_t v0 = 0x736f6d6570736575ull ^ k0, v1 = 0x646f72616e646f6dull ^ k1;
    uint64_t v2 = 0x6c7967656e657261ull ^ k0, v3 = 0x7465646279746573ull ^ k1, m;
#define ROUND v0 += v1; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32); v2 += v3; v3 = rotl(v3, 16); v3 ^= v2; \
    v0 += v3; v3 = rotl(v3, 21); v3 ^= v0; v2 += v1; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32);
    size_t i = 0;
    for (; i + 8 <= len; i += 8) { memcpy(&m, in + i, 8); v3 ^= m; ROUND ROUND v0 ^= m; }
    uint64_t b = (uint64_t)len << 56;
    for (size_t j = 0; i + j < len; j++) b |= (uint64_t)in[i + j] << (8 * j);
    v3 ^= b; ROUND ROUND v0 ^= b; v2 ^= 0xff; ROUND ROUND ROUND ROUND
    return v0 ^ v1 ^ v2 ^ v3;
}

int main(void) {
    char buf[256], buf2[256];
    _Atomic uint64_t at = 0;
    memset(buf, 0, sizeof buf); /* deterministic: groups read past what they copy */
    memset(buf2, 0, sizeof buf2);

    printf("tcg-check start\n");
    GROUP("add", h = mix(h, a + b); h = mix(h, a - b); h = mix(h, (uint32_t)a + (uint32_t)b););
    GROUP("mul", h = mix(h, a * b); h = mix(h, (uint32_t)a * (uint32_t)b););
    GROUP("mulh", h = mix(h, (uint64_t)(((unsigned __int128)a * b) >> 64));
                  h = mix(h, (uint64_t)(((__int128)(int64_t)a * (int64_t)b) >> 64)););
    GROUP("div", h = mix(h, a / (b | 1)); h = mix(h, (int64_t)a / (int64_t)(b | 1)); h = mix(h, a % (b | 1));
                 h = mix(h, (uint32_t)a / ((uint32_t)b | 1)); h = mix(h, (int32_t)a % ((int32_t)b | 1)););
    GROUP("shift", int r = c & 63; h = mix(h, a << r); h = mix(h, a >> r); h = mix(h, (uint64_t)((int64_t)a >> r));
                   h = mix(h, (uint32_t)a << (r & 31)); h = mix(h, (uint64_t)((int32_t)a >> (r & 31))););
    GROUP("rotate", int r = c & 63; h = mix(h, rotl(a, r)); h = mix(h, rotl(a, 13)); h = mix(h, rotl(a, 0));
                    h = mix(h, rotl(a, 32)););
    GROUP("bitfield", h = mix(h, (a >> (c & 31)) & 0xfff); h = mix(h, (uint64_t)(((int64_t)(a << 20)) >> 44));
                      h = mix(h, (a & ~(0xffull << 8)) | ((b & 0xff) << 8)););
    GROUP("clz/rbit", h = mix(h, __builtin_clzll(a | 1)); h = mix(h, __builtin_ctzll(a | (1ull << 63)));
                      h = mix(h, __builtin_bswap64(a)); h = mix(h, __builtin_bswap32((uint32_t)a));
                      h = mix(h, __builtin_popcountll(a)););
    GROUP("cmp/csel", h = mix(h, a < b ? a : b); h = mix(h, (int64_t)a < (int64_t)b ? c : a);
                      h = mix(h, (a == b) + 2 * ((uint32_t)a > (uint32_t)b)););
    GROUP("carry", unsigned __int128 x = (unsigned __int128)a + b + (c & 1); h = mix(h, (uint64_t)x);
                   h = mix(h, (uint64_t)(x >> 64)); h = mix(h, __builtin_add_overflow((int64_t)a, (int64_t)b,
                   &(int64_t){0})););
    GROUP("memory", memset(buf, (int)(a & 0xff), sizeof buf); memcpy(buf2, buf + (b & 63), 64 + (c & 63));
                    buf2[200] = 0; h = mix(h, buf2[c & 127]); memmove(buf + 1, buf, 100);
                    h = mix(h, (uint64_t)buf[(a >> 8) & 99]););
    GROUP("string", snprintf(buf, sizeof buf, "%llx-%llu", (unsigned long long)a, (unsigned long long)b);
                    h = mix(h, strlen(buf)); h = mix(h, (uint64_t)strchr(buf, '-') - (uint64_t)buf);
                    h = mix(h, (uint64_t)(int64_t)strcmp(buf, buf2) > 0););
    GROUP("atomic", atomic_fetch_add(&at, a); h = mix(h, atomic_load(&at)); uint64_t e = atomic_load(&at);
                    atomic_compare_exchange_strong(&at, &e, b); h = mix(h, atomic_exchange(&at, c)););
    GROUP("siphash", memcpy(buf, &a, 8); memcpy(buf + 8, &b, 8); h = mix(h, siphash((uint8_t *)buf, 3 + (c & 15), a, b)););
    GROUP("neon", uint8x16_t va = vreinterpretq_u8_u64(vcombine_u64(vcreate_u64(a), vcreate_u64(b)));
                  uint8x16_t vb = vreinterpretq_u8_u64(vcombine_u64(vcreate_u64(c), vcreate_u64(a ^ b)));
                  uint8x16_t vr = vaddq_u8(va, vb); vr = veorq_u8(vr, vcntq_u8(va)); vr = vmaxq_u8(vr, vb);
                  uint64x2_t vq = vreinterpretq_u64_u8(vr); h = mix(h, vgetq_lane_u64(vq, 0));
                  h = mix(h, vgetq_lane_u64(vq, 1)); h = mix(h, vaddvq_u8(va)););
    GROUP("float", double x = (double)(a >> 11) / 9007199254740992.0, y = (double)(b >> 11) + 1.0;
                   double r = x * y + x / y - sqrt(y); uint64_t bits; memcpy(&bits, &r, 8); h = mix(h, bits);
                   h = mix(h, (uint64_t)(int64_t)(r * 1000.0)); float f = (float)r; uint32_t fb;
                   memcpy(&fb, &f, 4); h = mix(h, fb););
    /* Crypto extensions (v8.2 CPUs advertise them; libraries pick them at runtime) */
    GROUP("crc32", h = mix(h, __builtin_aarch64_crc32cx((uint32_t)a, b)); h = mix(h, __builtin_aarch64_crc32w((uint32_t)a, (uint32_t)b)););
    GROUP("aes", uint8x16_t st = vreinterpretq_u8_u64(vcombine_u64(vcreate_u64(a), vcreate_u64(b)));
                 uint8x16_t k = vreinterpretq_u8_u64(vcombine_u64(vcreate_u64(c), vcreate_u64(~a)));
                 st = vaesmcq_u8(vaeseq_u8(st, k)); st = vaesimcq_u8(vaesdq_u8(st, k));
                 h = mix(h, vgetq_lane_u64(vreinterpretq_u64_u8(st), 0)); h = mix(h, vgetq_lane_u64(vreinterpretq_u64_u8(st), 1)););
    GROUP("sha", uint32x4_t x0 = vreinterpretq_u32_u64(vcombine_u64(vcreate_u64(a), vcreate_u64(b)));
                 uint32x4_t x1 = vreinterpretq_u32_u64(vcombine_u64(vcreate_u64(c), vcreate_u64(a ^ c)));
                 uint32x4_t r2 = vsha256hq_u32(x0, x1, x0); r2 = vsha256su0q_u32(r2, x1);
                 uint32x4_t r1 = vsha1cq_u32(x0, (uint32_t)c, x1);
                 h = mix(h, vgetq_lane_u64(vreinterpretq_u64_u32(r2), 0)); h = mix(h, vgetq_lane_u64(vreinterpretq_u64_u32(r1), 1)););
    GROUP("pmull", poly128_t p = vmull_p64((poly64_t)a, (poly64_t)b); uint64_t q[2]; memcpy(q, &p, 16);
                   h = mix(h, q[0]); h = mix(h, q[1]););
    /* Exclusive pairs and 128-bit compare-and-swap (16-byte atomics) */
    { static unsigned __int128 pair __attribute__((aligned(16)));
      GROUP("excl-pair", unsigned __int128 e = pair, d = ((unsigned __int128)a << 64) | b;
                         __atomic_compare_exchange_n(&pair, &e, d, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
                         unsigned __int128 v = __atomic_load_n(&pair, __ATOMIC_SEQ_CST);
                         h = mix(h, (uint64_t)v); h = mix(h, (uint64_t)(v >> 64));); }
    /* Big memory: write and verify ~600 MB, reaching guest RAM that sits at high host addresses */
    {
        size_t words = (600u << 20) / 8;
        uint64_t *m = malloc(words * 8), h = 0xcbf29ce484222325ull;
        if (!m) { printf("bigmem     malloc failed\n"); }
        else {
            for (size_t i = 0; i < words; i++) m[i] = i * 0x9E3779B97F4A7C15ull ^ (i >> 7);
            for (size_t i = 0; i < words; i += 4099) h = mix(h, m[i]);
            for (size_t i = 0; i < words; i++) if (m[i] != (i * 0x9E3779B97F4A7C15ull ^ (i >> 7))) { h = mix(h, i); break; }
            printf("%-10s %016llx\n", "bigmem", (unsigned long long)h); fflush(stdout);
            free(m);
        }
    }
    /* Exact instruction forms (inline asm), one group each: sign/zero extension in its many AArch64 shapes. The
     * systemd crash under qemu-wasm was a pointer off by 0xF_FFFF_FF80 = (u32)-8 << 4: a 32-bit index
     * zero-extended where it should have been sign-extended. */
#define ASM1(name, insn) GROUP(name, uint64_t r; __asm__ volatile(insn : "=r"(r) : "r"(a), "r"(b)); h = mix(h, r););
    ASM1("sxtw",       "sxtw %0, %w1")
    ASM1("sxth",       "sxth %0, %w1")
    ASM1("sxtb",       "sxtb %0, %w1")
    ASM1("sxth.w",     "sxth %w0, %w1")
    ASM1("uxtw",       "mov %w0, %w1")
    ASM1("add.sxtw4",  "add %0, %2, %w1, sxtw #4")
    ASM1("add.sxtw0",  "add %0, %2, %w1, sxtw")
    ASM1("add.uxtw3",  "add %0, %2, %w1, uxtw #3")
    ASM1("sub.sxtw2",  "sub %0, %2, %w1, sxtw #2")
    ASM1("add.sxth1",  "add %0, %2, %w1, sxth #1")
    ASM1("add.sxtb",   "add %0, %2, %w1, sxtb")
    ASM1("sbfiz64",    "sbfiz %0, %1, #4, #32")
    ASM1("sbfiz.w",    "sbfiz %w0, %w1, #3, #12")
    ASM1("sbfx64",     "sbfx %0, %1, #7, #20")
    ASM1("sbfx.w",     "sbfx %w0, %w1, #5, #9")
    ASM1("sbfx.w0",    "sbfx %w0, %w1, #0, #8")
    ASM1("ubfx.w",     "ubfx %w0, %w1, #5, #9")
    ASM1("ubfiz.w",    "ubfiz %w0, %w1, #4, #20")
    ASM1("asr.w",      "asr %w0, %w1, #3")
    ASM1("asrv.w",     "asr %w0, %w1, %w2")
    ASM1("lsrv.w",     "lsr %w0, %w1, %w2")
    ASM1("neg.w",      "neg %w0, %w1")
    ASM1("sub.w",      "sub %w0, %w1, %w2")
    ASM1("subs.w",     "subs %w0, %w1, %w2")
    ASM1("cneg.w",     "cmp %w1, %w2\n\tcneg %w0, %w1, lt")
    ASM1("smaddl",     "smaddl %0, %w1, %w2, %2")
    ASM1("umaddl",     "umaddl %0, %w1, %w2, %2")
    ASM1("smull",      "smull %0, %w1, %w2")
    ASM1("sdiv.w",     "orr w9, %w2, #1\n\tsdiv %w0, %w1, w9")
    { static int32_t i32s[256]; static int16_t i16s[256]; static int8_t i8s[256];
      for (int i = 0; i < 256; i++) { i32s[i] = (int32_t)rnd(); i16s[i] = (int16_t)rnd(); i8s[i] = (int8_t)rnd(); }
      GROUP("ldrsw", uint64_t r; __asm__ volatile("ldrsw %0, [%1]" : "=r"(r) : "r"(&i32s[a & 255])); h = mix(h, r););
      GROUP("ldrsh", uint64_t r; __asm__ volatile("ldrsh %0, [%1]" : "=r"(r) : "r"(&i16s[a & 255])); h = mix(h, r););
      GROUP("ldrsb.w", uint64_t r; __asm__ volatile("ldrsb %w0, [%1]" : "=r"(r) : "r"(&i8s[a & 255])); h = mix(h, r););
      GROUP("ldrsw.idx", uint64_t r; __asm__ volatile("ldrsw %0, [%1, %w2, sxtw #2]" : "=r"(r) : "r"(&i32s[128]), "r"((int32_t)(a % 100) - 50)); h = mix(h, r););
    }
    /* Verbatim from libsystemd-shared-262 +0x31b418..0x31b484, where memcpy got a bad source under qemu-wasm
     * (test/probe): w2 in {-4,-3}, index = w2 + 4, 24-byte entries, umaddl with a constant multiplier. */
    { static uint8_t arr[1024];
      GROUP("sd-umaddl",
        uint64_t x1 = (uint64_t)arr, x3; uint32_t w2 = (a & 1) ? 0xfffffffcu : 0xfffffffdu, w19 = (b & 1) ? 0u : 0xfffffffcu;
        uint64_t x20;
        (void)w19;
        __asm__ volatile(
          "mov x9, %[x1]\n\t"
          "mov w10, %w[w2]\n\t"
          "add w11, w10, #0x4\n\t"
          "mov w12, #0x18\n\t"
          "umaddl x13, w11, w12, x9\n\t"
          "cmn w10, #0x5\n\t"
          "b.ls 1f\n\t"
          "add w14, w10, #0x4\n\t"
          "umaddl x14, w14, w12, x9\n\t"
          "b 2f\n"
          "1:\tmov x14, x9\n"
          "2:\tmov %[x3], x13\n\t"
          "mov %[x20], x14\n\t"
          : [x3] "=r"(x3), [x20] "=r"(x20) : [x1] "r"(x1), [w2] "r"(w2)
          : "x9", "x10", "x11", "x12", "x13", "x14", "cc");
        h = mix(h, x3 - x1); h = mix(h, x20 - x1););
    }
    /* Self-modifying code: code memory reused for different code (what every exec / page-cache reuse / JIT
     * does). The emulator must drop its old translation - including any compiled Wasm module for it. Each round
     * writes "mov w0, #k; ret", runs it enough times to get it compiled, then rewrites it with a new k. */
    {
        uint32_t *code = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        uint64_t h = 0xcbf29ce484222325ull, bad = 0;
        for (uint32_t round = 0; round < 64; round++) {
            uint32_t k = (round * 7919u) & 0xffff;
            code[0] = 0x52800000u | (k << 5);   /* movz w0, #k */
            code[1] = 0xd65f03c0u;              /* ret */
            __builtin___clear_cache((char *)code, (char *)(code + 2));
            int (*fn)(void) = (int (*)(void))code;
            for (int i = 0; i < 4000; i++) {
                uint32_t r = (uint32_t)fn();
                if (r != k) { bad++; h = mix(h, ((uint64_t)round << 32) | r); break; }
            }
            h = mix(h, k);
        }
        printf("%-10s %016llx%s\n", "smc", (unsigned long long)h, bad ? "  STALE CODE RAN" : ""); fflush(stdout);
    }
    sink = 0;
    printf("tcg-check done\n");
    fflush(stdout);
    if (getpid() == 1) {
        sync();
        reboot(RB_POWER_OFF);
    }
    return 0;
}
