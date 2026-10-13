// dlmopen(LM_ID_NEWLM) under Andromarchy's runtime: glibc loads LD_PRELOAD objects into the base namespace only,
// so a library loaded into a new namespace runs without fakechroot and android-compat: it no longer sees the
// rootfs as / (Valve's Steam client loads its whole UI, steamui.so, this way). The wrapper loads the runtime's
// preloads (the LD_PRELOAD list, host paths) into the new namespace first, RTLD_GLOBAL, then the requested
// library into that same namespace. Lab standalone version; shipped in android-compat.c by Andromarchy patch 0004.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <link.h>
#include <stdlib.h>
#include <string.h>

// nsroot.so (built next to this library, DT_NEEDED android-compat.so + libfakechroot.so, RUNPATH $ORIGIN-relative)
// is loaded first into every new namespace: glibc makes the first object of a namespace that namespace's global
// scope, so the runtime's wrappers come before libc for everything loaded there later. (RTLD_GLOBAL is refused
// outside the base namespace, so the preloads cannot simply be added.)
void *dlmopen(Lmid_t lmid, const char *file, int mode)
{
    static void *(*next)(Lmid_t, const char *, int);
    static char root[4096];
    if (!next) {
        next = dlsym(RTLD_NEXT, "dlmopen");
        const char *r = getenv("DLMOPEN_FIX_ROOT"); // lab: path of nsroot.so (host path)
        if (r)
            snprintf(root, sizeof root, "%s", r);
    }
    if (lmid != LM_ID_NEWLM || !root[0])
        return next(lmid, file, mode);
    void *h = next(LM_ID_NEWLM, root, RTLD_NOW);
    Lmid_t ns;
    if (getenv("DLMOPEN_FIX_DEBUG"))
        fprintf(stderr, "dlmopen-fix: namespace root %s -> %p %s\n", root, h, h ? "" : dlerror());
    if (!h || dlinfo(h, RTLD_DI_LMID, &ns) != 0)
        return next(lmid, file, mode);
    return next(ns, file, mode);
}
