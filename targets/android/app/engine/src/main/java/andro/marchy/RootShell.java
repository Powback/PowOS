package andro.marchy;

import android.util.Log;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.function.Consumer;

/**
 * The app's one root shell: a single long-lived `su` that every short root command goes through, instead of a new `su`
 * per command. Each `su` is a superuser request Magisk logs and toasts ("granted Superuser rights"), and on ColorOS every
 * toast window caps the panel at 60 Hz while it shows - one `su` a second (the tiles' state, a widget's check, an agent's
 * message) was the display flickering between 60 and 120 Hz. One shell: one request when it starts, none after.
 *
 * Commands run one at a time, each in a subshell of its own (a `cd` or `exit` in one doesn't reach the next), stdin
 * closed, stderr merged; the end of each is a marker line with its exit code, unique per command. A command still
 * running after its timeout has its shell killed (the next command starts a new one). Long-lived root processes (a
 * terminal's pty, the PowOS session, a stream) keep their own `su`: they start rarely and stay.
 */
public final class RootShell {
    private static final String TAG = "PowosRootShell";

    private static final Object lock = new Object();
    private static Process shell;
    private static BufferedWriter in;
    private static BufferedReader out;
    private static long serial;

    private RootShell() {}

    /** A command's end: its exit code and its output (stdout and stderr, trailing newline trimmed). */
    public static final class Result {
        public final int code;
        public final String output;

        Result(int code, String output) {
            this.code = code;
            this.output = output;
        }
    }

    /** Runs [command] as root; [onLine] hears each output line as it comes (may be null). -1 and the error if it couldn't. */
    public static Result run(String command, Consumer<String> onLine, long timeoutMs) {
        synchronized (lock) {
            String marker = "__powos_root_" + android.os.Process.myPid() + "_" + (++serial) + "__";
            Thread watchdog = null;
            try {
                ensure();
                final Process running = shell;
                watchdog = new Thread(() -> {
                    try {
                        Thread.sleep(timeoutMs);
                        Log.w(TAG, "timed out after " + timeoutMs + " ms: " + command);
                        running.destroy();
                    } catch (InterruptedException ignored) {
                    }
                }, "root-shell-timeout");
                watchdog.setDaemon(true);
                watchdog.start();
                in.write("( " + command + "\n) </dev/null 2>&1; printf '\\n" + marker + " %d\\n' $?\n");
                in.flush();
                StringBuilder text = new StringBuilder();
                String pending = null;
                for (String line; (line = out.readLine()) != null; ) {
                    if (line.startsWith(marker + " ")) {
                        // The marker's own leading newline: a line of its own after output that ended with one.
                        if (pending != null && !pending.isEmpty()) emit(text, pending, onLine);
                        int code = Integer.parseInt(line.substring(marker.length() + 1).trim());
                        return new Result(code, text.toString().replaceAll("\n+$", ""));
                    }
                    if (pending != null) emit(text, pending, onLine);
                    pending = line;
                }
                throw new IOException("root shell ended");
            } catch (IOException | RuntimeException e) {
                Log.w(TAG, command + ": " + e);
                stop();
                return new Result(-1, String.valueOf(e.getMessage()));
            } finally {
                if (watchdog != null) watchdog.interrupt();
            }
        }
    }

    public static Result run(String command) {
        return run(command, null, 120_000);
    }

    /** Runs [command] as root: its exit code, each output line to [onLine]. */
    public static int run(String command, Consumer<String> onLine) {
        return run(command, onLine, 120_000).code;
    }

    private static void emit(StringBuilder text, String line, Consumer<String> onLine) {
        text.append(line).append('\n');
        if (onLine != null) onLine.accept(line);
    }

    private static void ensure() throws IOException {
        if (shell != null && shell.isAlive()) return;
        shell = new ProcessBuilder("su").redirectErrorStream(true).start();
        in = new BufferedWriter(new OutputStreamWriter(shell.getOutputStream()));
        out = new BufferedReader(new InputStreamReader(shell.getInputStream()));
        Log.i(TAG, "root shell started");
    }

    private static void stop() {
        if (shell != null) shell.destroy();
        shell = null;
        in = null;
        out = null;
    }
}
