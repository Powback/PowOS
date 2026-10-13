// cpubench.exe: small Windows CPU benchmark for comparing x86 emulation paths on the phone
// (box64 running all of x86 Wine vs. ARM64 Wine with only the game's code emulated through FEX ARM64EC).
// Each workload prints its time in ms; "nop" exits at once (measures process startup).
// Build: tools/wintest/build.sh (llvm-mingw, x86_64 / i686 / aarch64 targets).
#include <windows.h>
#include <stdio.h>
#include "out.h"
#include <stdint.h>
#include <string.h>
#include <math.h>

static double now_ms(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

// Integer: sieve of Eratosthenes up to 20M, 3 passes.
static uint64_t w_sieve(void)
{
    const int n = 20000000;
    uint8_t *s = VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    uint64_t count = 0;
    for (int pass = 0; pass < 3; pass++) {
        memset(s, 1, n);
        count = 0;
        for (int i = 2; i < n; i++)
            if (s[i]) {
                count++;
                for (long long j = (long long)i * i; j < n; j += i)
                    s[j] = 0;
            }
    }
    VirtualFree(s, 0, MEM_RELEASE);
    return count;
}

// Floating point: 256x256 double matrix multiply, 8 times.
static uint64_t w_matmul(void)
{
    enum { N = 256 };
    static double a[N][N], b[N][N], c[N][N];
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            a[i][j] = sin(i + j);
            b[i][j] = cos(i - j);
        }
    for (int r = 0; r < 8; r++)
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) {
                double s = 0;
                for (int k = 0; k < N; k++)
                    s += a[i][k] * b[k][j];
                c[i][j] = s + r;
            }
    return (uint64_t)(int64_t)(c[N / 2][N / 3] * 1000); // via int64: negative double -> uint64 differs by arch
}

// Memory: 64 MB memcpy, 20 times.
static uint64_t w_memcpy(void)
{
    size_t n = 64 << 20;
    char *a = VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    char *b = VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    memset(a, 7, n);
    for (int r = 0; r < 20; r++)
        memcpy(r & 1 ? a : b, r & 1 ? b : a, n);
    uint64_t v = (uint8_t)b[12345];
    VirtualFree(a, 0, MEM_RELEASE);
    VirtualFree(b, 0, MEM_RELEASE);
    return v;
}

// Win32 API calls (the emulated -> native transition cost): 200k critical-section + heap + tick calls.
static uint64_t w_api(void)
{
    CRITICAL_SECTION cs;
    InitializeCriticalSection(&cs);
    HANDLE h = GetProcessHeap();
    uint64_t sum = 0;
    for (int i = 0; i < 200000; i++) {
        EnterCriticalSection(&cs);
        void *p = HeapAlloc(h, 0, 64 + (i & 255));
        sum += (uintptr_t)p & 0xff;
        HeapFree(h, 0, p);
        sum += GetTickCount() & 1;
        LeaveCriticalSection(&cs);
    }
    DeleteCriticalSection(&cs);
    return sum;
}

// Kernel round trips (wineserver / syscalls): 2k event create/set/wait/close.
static uint64_t w_sys(void)
{
    uint64_t ok = 0;
    for (int i = 0; i < 2000; i++) {
        HANDLE e = CreateEventW(NULL, TRUE, FALSE, NULL);
        SetEvent(e);
        ok += WaitForSingleObject(e, 0) == WAIT_OBJECT_0;
        CloseHandle(e);
    }
    return ok;
}

// Threads: 4 threads x 50M xorshift steps (a serial chain no compiler can shortcut, unlike an LCG).
static DWORD WINAPI lcg_thread(void *arg)
{
    uint64_t x = (uintptr_t)arg;
    for (int i = 0; i < 50000000; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    *(volatile uint64_t *)&x;
    return (DWORD)x;
}
static uint64_t w_threads(void)
{
    HANDLE t[4];
    for (int i = 0; i < 4; i++)
        t[i] = CreateThread(NULL, 0, lcg_thread, (void *)(uintptr_t)(i + 1), 0, NULL);
    WaitForMultipleObjects(4, t, TRUE, INFINITE);
    uint64_t s = 0;
    for (int i = 0; i < 4; i++) {
        DWORD c;
        GetExitCodeThread(t[i], &c);
        s += c;
        CloseHandle(t[i]);
    }
    return s;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "nop"))
        return 0;
    struct { const char *name; uint64_t (*fn)(void); } w[] = {
        {"sieve", w_sieve}, {"matmul", w_matmul}, {"memcpy", w_memcpy},
        {"win32api", w_api}, {"kernelobj", w_sys}, {"threads4", w_threads},
    };
#if defined(__aarch64__) || defined(_M_ARM64)
    const char *arch = "arm64";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
    const char *arch = "i386";
#endif
    double total = 0;
    for (size_t i = 0; i < sizeof w / sizeof w[0]; i++) {
        double t0 = now_ms();
        uint64_t r = w[i].fn();
        double dt = now_ms() - t0;
        total += dt;
        out("cpubench %s %-10s %9.1f ms  (check %llu)\n", arch, w[i].name, dt, (unsigned long long)r);
    }
    out("cpubench %s TOTAL      %9.1f ms\n", arch, total);
    return 0;
}
