/*
 * tools/emu/su.c: the emulator's su, as the phone's Magisk grants it - root for adb's shell, root itself and the PowOS
 * app (com.powos.app's uid), nobody else. Installed setuid root at /system/xbin/su by tools/emu/emu.sh (built with the
 * warm builder's NDK); the emulator only, never the phone.
 * HACK: a hand-rolled su instead of Magisk on the emulator (no Magisk build for the AVD's ramdisk here). Real fix:
 * Magisk's own su on the AVD (rootAVD-style ramdisk patch), the same binary and grant policy as the phone.
 *   su                       a root shell on stdin (RootShell.java writes its commands to it)
 *   su -c CMD                sh -c CMD as root (Magisk's form: the app, the checks' `su -c '...'`)
 *   su [UID] [-c CMD | CMD]  AOSP's debug su form (`su 0 cmd`); UID is ignored past root
 * Options Magisk takes and that change nothing here (-mm, --mount-master, -p, --preserve-environment) are skipped.
 */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int allowed(uid_t uid) {
    struct stat st;
    if (uid == 0 || uid == 2000) return 1; /* root, adb shell */
    return stat("/data/data/com.powos.app", &st) == 0 && st.st_uid == uid;
}

int main(int argc, char **argv) {
    uid_t caller = getuid();
    if (!allowed(caller)) {
        fprintf(stderr, "su: uid %d not allowed\n", (int)caller);
        return 1;
    }
    if (setgid(0) || setuid(0)) {
        perror("su: setuid");
        return 1;
    }
    int i = 1;
    while (i < argc && (!strcmp(argv[i], "-mm") || !strcmp(argv[i], "-M") || !strcmp(argv[i], "--mount-master") ||
                        !strcmp(argv[i], "-p") || !strcmp(argv[i], "--preserve-environment") || !strcmp(argv[i], "-")))
        i++;
    if (i < argc && argv[i][0] >= '0' && argv[i][0] <= '9') i++; /* AOSP: su 0 ... */
    if (i >= argc) {
        execl("/system/bin/sh", "sh", (char *)NULL);
    } else if (!strcmp(argv[i], "-c") && i + 1 < argc) {
        execl("/system/bin/sh", "sh", "-c", argv[i + 1], (char *)NULL);
    } else {
        execvp(argv[i], argv + i);
    }
    perror("su: exec");
    return 127;
}
