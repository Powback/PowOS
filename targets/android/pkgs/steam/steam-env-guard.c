// Preloaded into Valve's ARM64 Steam client by /usr/bin/steam (see there): the client sets
// MESA_LOADER_DRIVER_OVERRIDE=kgsl for its web UI (steamwebhelper) on a Turnip/KGSL phone, and Chromium's GPU process
// on freedreno keeps dying ("GPU state invalid") - pages black, UI crawling. Without the override it can't start
// freedreno and Chromium falls back to its own software renderer (SwiftShader, shipped with the client).
//
// HACK: this drops that one setenv/putenv. Real fix: CEF's GPU process on freedreno/KGSL.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#define VAR "MESA_LOADER_DRIVER_OVERRIDE"

int setenv(const char *name, const char *value, int overwrite)
{
    static int (*real)(const char *, const char *, int);
    if (name && strcmp(name, VAR) == 0)
        return 0;
    if (!real)
        real = (int (*)(const char *, const char *, int))dlsym(RTLD_NEXT, "setenv");
    return real(name, value, overwrite);
}

int putenv(char *string)
{
    static int (*real)(char *);
    if (string && strncmp(string, VAR "=", sizeof(VAR)) == 0)
        return 0;
    if (!real)
        real = (int (*)(char *))dlsym(RTLD_NEXT, "putenv");
    return real(string);
}
