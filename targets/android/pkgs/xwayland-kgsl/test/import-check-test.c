/* PowOS: the KGSL DRI3 import rules and the per-shape failure log (xwayland-kgsl-import-check.h), no X server or EGL.
 * Run: test/run.sh (Docker gcc). Shapes are the ones seen on the OnePlus Open (design-qa/bf-black-20261103-000740). */
#include <assert.h>
#include <stdio.h>
#include "../xwayland-kgsl-import-check.h"

static int fails;
#define EXPECT(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

int main(void)
{
    /* Broforce full screen on the cover screen: tight linear XR24 pitch 4464 is not 64-aligned. */
    EXPECT(xwl_kgsl_import_check(1116, 2484, 4, 1116 * 4, 0, 1116 * 4 * 2484) != NULL);
    EXPECT(strstr(xwl_kgsl_import_check(1116, 2484, 4, 4464, 0, -1), "64-byte"));
    /* The same window padded the way turnip/WSI allocate (256 B) imports. */
    EXPECT(xwl_kgsl_import_check(1116, 2484, 4, 4608, 0, (int64_t) 4608 * 2484) == NULL);
    /* KWin's own buffers from the same run (2314x2268 stride 9472, 2440x2268 stride 9984, 640x480 stride 2560). */
    EXPECT(xwl_kgsl_import_check(2314, 2268, 4, 9472, 0, (int64_t) 9472 * 2268) == NULL);
    EXPECT(xwl_kgsl_import_check(2440, 2268, 4, 9984, 0, (int64_t) 9984 * 2268) == NULL);
    EXPECT(xwl_kgsl_import_check(640, 480, 4, 2560, 0, -1) == NULL);
    /* 2268 wide tight (9072) is 16- but not 64-aligned. */
    EXPECT(xwl_kgsl_import_check(2268, 2440, 4, 9072, 0, -1) != NULL);
    /* Short stride, short bo, cpp 8 needs 128. */
    EXPECT(strstr(xwl_kgsl_import_check(1116, 2484, 4, 4096, 0, -1), "shorter"));
    EXPECT(strstr(xwl_kgsl_import_check(1116, 2484, 4, 4608, 0, 4608 * 100), "smaller"));
    EXPECT(xwl_kgsl_import_check(16, 16, 8, 192, 0, -1) != NULL);
    EXPECT(xwl_kgsl_import_check(16, 16, 8, 256, 0, -1) == NULL);

    /* One line per distinct shape, then every 1000th. */
    struct xwl_kgsl_import_log log = { 0 };
    int printed = 0;
    for (int i = 0; i < 13775; i++)
        printed += xwl_kgsl_import_log_should_print(xwl_kgsl_import_log_note(&log, 1116, 2484, 4464, 0, 11088576));
    EXPECT(printed == 1 + 13);
    EXPECT(xwl_kgsl_import_log_note(&log, 2268, 2440, 9216, 0, -1) == 1);
    /* A full table recycles its oldest slot: a 9th new shape is still "first". */
    for (uint32_t w = 1; w <= 8; w++)
        xwl_kgsl_import_log_note(&log, w, 1, 64, 0, -1);
    EXPECT(xwl_kgsl_import_log_note(&log, 99, 1, 64, 0, -1) == 1);

    if (fails)
        return 1;
    printf("import-check-test: ok\n");
    return 0;
}
