/*
 * probe-init: PID 1 of a probe initramfs (PowOS's own initramfs + this). Sets up the minimum systemd expects,
 * then runs systemd's unit loading as an ORDINARY child (systemd --test --system): a crash there is not caught
 * by systemd's PID-1 crash handler, so the kernel reports it (print-fatal-signals=1: PC, registers, the
 * library and offset). Used to find what qemu-wasm mis-executes where PID 1 dies with "Caught <SEGV>".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>

static void run(char *const argv[]) {
    printf("probe: run %s %s\n", argv[0], argv[1] ? argv[1] : "");
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        /* systemd refuses --test as root ("Don't run test mode as root"): run it as nobody. */
        if (setgid(65534) || setuid(65534)) perror("drop privileges");
        execv(argv[0], argv);
        perror("execv");
        _exit(127);
    }
    /* The child's memory map, snapshotted while it runs: after a crash it turns pc/lr into library + offset
     * (boot with norandmaps so addresses are stable). */
    static char maps[256 * 1024];
    size_t maps_len = 0;
    int st = 0;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/maps", p);
    while (waitpid(p, &st, WNOHANG) == 0) {
        FILE *f = fopen(path, "r");
        if (f) {
            size_t n = fread(maps, 1, sizeof maps - 1, f);
            fclose(f);
            if (n > 0) maps_len = n;
        }
        usleep(50000);
    }
    maps[maps_len] = 0;
    if (WIFSIGNALED(st)) {
        printf("probe: last maps of the child (executable mappings):\n");
        for (char *l = strtok(maps, "\n"); l; l = strtok(NULL, "\n"))
            if (strstr(l, " r-xp ")) printf("probe:   %s\n", l);
    }
    if (WIFSIGNALED(st)) printf("probe: %s KILLED by signal %d\n", argv[0], WTERMSIG(st));
    else printf("probe: %s exited %d\n", argv[0], WEXITSTATUS(st));
    fflush(stdout);
}

int main(void) {
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("tmpfs", "/run", "tmpfs", 0, "mode=755");
    mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, NULL); /* systemd's manager needs its cgroup */
    mkdir("/tmp", 01777);
    mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");        /* --test makes its unit dirs there, as nobody */
    mkdir("/run/systemd", 0755);
    setenv("SYSTEMD_LOG_LEVEL", "debug", 1);
    setenv("SYSTEMD_LOG_TARGET", "console", 1);
    char *test[] = { "/usr/lib/systemd/systemd", "--test", "--system", "--no-pager", NULL };
    for (int i = 0; i < 3; i++) run(test);
    printf("probe done\n");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
