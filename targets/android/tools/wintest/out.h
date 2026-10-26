// Result lines go to stdout and, if WINTEST_LOG names a file, are appended there too: Proton's launcher
// (steam.exe/umu.exe) does not pass a console program's stdout through, so the scripts read the file.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
static void out(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
    const char *p = getenv("WINTEST_LOG");
    FILE *f = p ? fopen(p, "a") : NULL;
    if (f) {
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fclose(f);
    }
}
