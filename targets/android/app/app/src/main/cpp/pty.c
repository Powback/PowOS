// Pseudoterminals for the web shell's terminals (shell/Pty.kt): a process on a pty whose raw bytes the page's
// xterm.js reads and writes. Termux's TerminalSession does the same, but feeds the bytes to its own emulator and keeps
// its pty calls package-private, so the shell has these few of its own.
#include <jni.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define FN(name) Java_dev_omalauncher_shell_Pty_##name

static char **strings(JNIEnv *env, jobjectArray array) {
    jsize n = array ? (*env)->GetArrayLength(env, array) : 0;
    char **out = calloc(n + 1, sizeof(char *));
    for (jsize i = 0; i < n; i++) {
        jstring s = (*env)->GetObjectArrayElement(env, array, i);
        const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
        out[i] = strdup(utf);
        (*env)->ReleaseStringUTFChars(env, s, utf);
        (*env)->DeleteLocalRef(env, s);
    }
    return out;
}

static void release(char **list) {
    if (!list) return;
    for (char **p = list; *p; p++) free(*p);
    free(list);
}

// Starts argv[0] (a full path) in [cwd] with exactly [envp], its stdin/out/err the slave of a new pty of
// [rows] x [cols]. Returns the master's fd (pid[0] = the process) or -errno.
JNIEXPORT jint JNICALL FN(spawn)(JNIEnv *env, jclass cls, jstring jcwd, jobjectArray jargv, jobjectArray jenvp, jint rows, jint cols, jintArray jpid) {
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) return -errno;
    char slave[64];
    if (grantpt(master) || unlockpt(master) || ptsname_r(master, slave, sizeof(slave))) {
        int err = errno;
        close(master);
        return -err;
    }
    // UTF-8 line editing (a backspace erases a whole character), and the first size before anything reads it.
    struct termios tio;
    if (tcgetattr(master, &tio) == 0) {
        tio.c_iflag |= IUTF8;
        tio.c_iflag &= ~(IXON | IXOFF);
        tcsetattr(master, TCSANOW, &tio);
    }
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    ioctl(master, TIOCSWINSZ, &size);

    // Everything the child needs, copied before fork: it calls no JNI and allocates nothing.
    const char *c = (*env)->GetStringUTFChars(env, jcwd, NULL);
    char *cwd = strdup(c);
    (*env)->ReleaseStringUTFChars(env, jcwd, c);
    char **argv = strings(env, jargv);
    char **envp = strings(env, jenvp);

    pid_t pid = fork();
    if (pid < 0) {
        int err = errno;
        close(master);
        free(cwd);
        release(argv);
        release(envp);
        return -err;
    }
    if (pid == 0) {
        // The app's threads block signals the shell needs (SIGINT, SIGCHLD, ...): a fresh process starts with none.
        sigset_t all;
        sigfillset(&all);
        sigprocmask(SIG_UNBLOCK, &all, NULL);
        close(master);
        setsid();
        int s = open(slave, O_RDWR);
        if (s < 0) _exit(126);
        ioctl(s, TIOCSCTTY, 0);
        dup2(s, 0);
        dup2(s, 1);
        dup2(s, 2);
        // Nothing of the app's leaks into the shell: every other fd closes.
        DIR *fds = opendir("/proc/self/fd");
        if (fds) {
            int self = dirfd(fds);
            struct dirent *e;
            while ((e = readdir(fds))) {
                int fd = atoi(e->d_name);
                if (fd > 2 && fd != self) close(fd);
            }
            closedir(fds);
        }
        if (chdir(cwd)) chdir("/");
        execve(argv[0], argv, envp);
        static const char failed[] = "can't start the terminal's shell\r\n";
        write(2, failed, sizeof(failed) - 1);
        _exit(127);
    }
    free(cwd);
    release(argv);
    release(envp);
    jint p = pid;
    (*env)->SetIntArrayRegion(env, jpid, 0, 1, &p);
    return master;
}

JNIEXPORT void JNICALL FN(resize)(JNIEnv *env, jclass cls, jint fd, jint rows, jint cols) {
    struct winsize size = {.ws_row = rows, .ws_col = cols};
    ioctl(fd, TIOCSWINSZ, &size);
}

// Blocks until [pid] ends: its exit status, or -signal if a signal ended it.
JNIEXPORT jint JNICALL FN(waitFor)(JNIEnv *env, jclass cls, jint pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return -WTERMSIG(status);
    return 0;
}
