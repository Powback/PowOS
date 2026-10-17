package andro.marchy;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.util.Log;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;

/**
 * Delivers the on-screen gamepad's state to powos-padd in PowOS (targets/android/session/powos-padd), which
 * turns it into a virtual Xbox 360 pad. The UI thread queues states; this thread writes them, reconnecting
 * when the daemon (re)starts. Button changes are never merged away (a quick tap is a press and a release
 * within one frame); consecutive states that differ only in stick/trigger values are merged, newest wins.
 */
final class PadSender extends Thread {

    /** Button bits, as powos-padd reads them. */
    static final int A = 1, B = 1 << 1, X = 1 << 2, Y = 1 << 3, LB = 1 << 4, RB = 1 << 5, BACK = 1 << 6,
            START = 1 << 7, GUIDE = 1 << 8, LS = 1 << 9, RS = 1 << 10,
            UP = 1 << 11, DOWN = 1 << 12, LEFT = 1 << 13, RIGHT = 1 << 14;

    private static final String TAG = "PadSender";
    private static final int MAX_QUEUE = 64;
    private final String path;
    private final ArrayDeque<byte[]> queue = new ArrayDeque<>();
    private int lastQueuedButtons = -1;
    private volatile boolean running = true;

    PadSender(String socketPath) {
        super("PadSender");
        path = socketPath;
        setDaemon(true);
    }

    /** Called on every change; cheap, never blocks on the socket. Sticks -1..1 (y down), triggers 0..1. */
    synchronized void post(int buttons, float lx, float ly, float rx, float ry, float lt, float rt) {
        // PAD2: PAD1's fields, then trackpads x/y and gyro/accel (zero until a module drives them).
        byte[] p = new byte[40];
        ByteBuffer b = ByteBuffer.wrap(p).order(ByteOrder.LITTLE_ENDIAN);
        b.put((byte) 'P').put((byte) 'A').put((byte) 'D').put((byte) '2');
        b.putInt(buttons);
        b.putShort(axis(lx)).putShort(axis(ly)).putShort(axis(rx)).putShort(axis(ry));
        b.put(trigger(lt)).put(trigger(rt)).putShort((short) 0);
        if (!queue.isEmpty() && buttons == lastQueuedButtons) {
            queue.pollLast(); // same buttons: only the newest analog values matter
        } else if (queue.size() >= MAX_QUEUE) {
            queue.pollFirst(); // daemon away for long: drop the oldest
        }
        queue.addLast(p);
        lastQueuedButtons = buttons;
        notifyAll();
    }

    void shutdown() {
        running = false;
        interrupt();
    }

    private static short axis(float v) {
        return (short) Math.round(Math.max(-1f, Math.min(1f, v)) * 32767f);
    }

    private static byte trigger(float v) {
        return (byte) Math.round(Math.max(0f, Math.min(1f, v)) * 255f);
    }

    @Override
    public void run() {
        LocalSocket sock = null;
        OutputStream out = null;
        while (running) {
            byte[] packet;
            synchronized (this) {
                while (queue.isEmpty() && running) {
                    try {
                        wait();
                    } catch (InterruptedException e) {
                        if (!running) return;
                    }
                }
                packet = queue.peekFirst();
            }
            if (packet == null) continue;
            try {
                if (sock == null) {
                    sock = new LocalSocket();
                    sock.connect(new LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM));
                    out = sock.getOutputStream();
                    Log.i(TAG, "connected to " + path);
                }
                out.write(packet);
                synchronized (this) {
                    if (queue.peekFirst() == packet) queue.pollFirst();
                    if (queue.isEmpty()) lastQueuedButtons = -1;
                }
            } catch (IOException e) {
                Log.w(TAG, "powos-padd unreachable: " + e.getMessage());
                try {
                    if (sock != null) sock.close();
                } catch (IOException ignored) {
                }
                sock = null;
                out = null;
                try {
                    Thread.sleep(1000); // keep the queue; retry (daemon starting with the session)
                } catch (InterruptedException ignored) {
                }
            }
        }
        try {
            if (sock != null) sock.close();
        } catch (IOException ignored) {
        }
    }
}
