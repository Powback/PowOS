/* PowOS: patch 0011's Present-copy fence counts (xwayland-kgsl-copy-wait.h), no X server or EGL. Run: test/run.sh. */
#include <stdio.h>
#include "../xwayland-kgsl-copy-wait.h"

static int fails;
#define EXPECT(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

int main(void)
{
    /* The kernel's stub fence (EXPORT_SYNC_FILE: signalled or nothing attached) vs a client's KGSL timeline fence. */
    EXPECT(xwl_kgsl_copy_fence_is_stub("stub", 1));
    EXPECT(xwl_kgsl_copy_fence_is_stub("kgsl-timeline", 0));
    EXPECT(!xwl_kgsl_copy_fence_is_stub("kgsl-timeline", 1));

    struct xwl_kgsl_copy_wait_stats s = { 0 };
    char line[512];
    const uint64_t t0 = 5000000;
    /* Broforce at ~24 fps for 30 s: 700 copies, 10 waited (4 + 12 ms), 2 stubs, 1 failure. */
    for (int i = 0; i < 687; i++)
        xwl_kgsl_copy_wait_note(&s, XWL_KGSL_COPY_DRAWN, t0 + i);
    for (int i = 0; i < 10; i++)
        xwl_kgsl_copy_wait_note(&s, XWL_KGSL_COPY_WAITED, t0 + 1000 + i);
    xwl_kgsl_copy_wait_done(&s, 4000);
    xwl_kgsl_copy_wait_done(&s, 12000);
    xwl_kgsl_copy_wait_note(&s, XWL_KGSL_COPY_STUB, t0 + 2000);
    xwl_kgsl_copy_wait_note(&s, XWL_KGSL_COPY_STUB, t0 + 2001);
    xwl_kgsl_copy_wait_note(&s, XWL_KGSL_COPY_FAILED, t0 + 2002);
    /* Not before 30 s; at 30 s one line with every count; then a fresh period. */
    EXPECT(!xwl_kgsl_copy_wait_line(&s, t0 + 29999999, line, sizeof(line)));
    EXPECT(xwl_kgsl_copy_wait_line(&s, t0 + 30000000, line, sizeof(line)));
    EXPECT(strstr(line, "last 30s: 700 Present copies"));
    EXPECT(strstr(line, "10 waited for the client's GPU fence (avg 8.0 ms, max 12.0 ms)"));
    EXPECT(strstr(line, "687 already drawn"));
    EXPECT(strstr(line, "2 with the fence already signalled or none (stub)"));
    EXPECT(strstr(line, "1 export failures"));
    EXPECT(s.drawn == 0 && s.waited == 0 && s.period_start_us == t0 + 30000000);
    /* A quiet period says nothing. */
    EXPECT(!xwl_kgsl_copy_wait_line(&s, t0 + 90000000, line, sizeof(line)));

    if (fails)
        return 1;
    printf("copy-wait-test: ok\n");
    return 0;
}
