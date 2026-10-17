package andro.marchy;

import android.content.Context;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.Uri;
import android.util.Log;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * PowOS: the app's end of the window control channel - PowOS windows KWin shows as their own Android tasks
 * (docs/powos-window-tasks.md). A connection to the display daemon in the control role ("app"); the daemon relays
 * one-line messages to and from KWin: {@code open <id> <app id> <caption>}, {@code title <id> <caption>},
 * {@code close <id>} from KWin; {@code closed <id>}, {@code focus <id>} to it (tab-separated).
 *
 * Runs for the session's life (SessionService), reconnecting while the daemon or KWin restart.
 */
public final class WindowTasks {
    private static final String TAG = "WindowTasks";
    // protocol.h
    private static final int CTRL_MSG_CONTROL_HELLO = 20;
    private static final int CTRL_MSG_CONTROL = 21;
    private static final int CONTROL_ROLE_APP = 1;
    private static final int CONTROL_MAX_PAYLOAD = 4096;

    private static volatile OutputStream out;
    private static Thread thread;
    /** The window tasks on screen, by surface id: KWin's "close" and "title" reach them here. */
    static final Map<Integer, PowosWindowActivity> tasks = new ConcurrentHashMap<>();

    private WindowTasks() {}

    static synchronized void start(Context context) {
        if (thread != null)
            return;
        Context app = context.getApplicationContext();
        String socket = SessionService.daemonSocket(app).getPath();
        thread = new Thread(() -> run(app, socket), "window-tasks");
        thread.setDaemon(true);
        thread.start();
    }

    private static void run(Context context, String socket) {
        while (true) {
            try (LocalSocket s = new LocalSocket()) {
                s.connect(new LocalSocketAddress(socket, LocalSocketAddress.Namespace.FILESYSTEM));
                OutputStream o = s.getOutputStream();
                o.write(frame(CTRL_MSG_CONTROL_HELLO, le32(CONTROL_ROLE_APP)));
                out = o;
                Log.i(TAG, "control channel up");
                read(context, s.getInputStream());
            } catch (IOException e) {
                // the daemon isn't there (yet / any more): retry
            } finally {
                out = null;
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    private static void read(Context context, InputStream in) throws IOException {
        DataInputStream d = new DataInputStream(in);
        byte[] header = new byte[8];
        while (true) {
            d.readFully(header);
            ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
            int type = h.getInt();
            int size = h.getInt();
            if (size < 0 || size > CONTROL_MAX_PAYLOAD)
                throw new IOException("bad control message size " + size);
            byte[] payload = new byte[size];
            d.readFully(payload);
            if (type == CTRL_MSG_CONTROL)
                handle(context, new String(payload, StandardCharsets.UTF_8));
        }
    }

    private static void handle(Context context, String line) {
        String[] f = line.split("\t", -1);
        int id;
        try {
            id = Integer.parseInt(f.length > 1 ? f[1] : "");
        } catch (NumberFormatException e) {
            Log.w(TAG, "bad control message: " + line);
            return;
        }
        switch (f[0]) {
            case "open": {
                // A document task per surface id: its own card in Recents, split screen, floating window.
                Intent i = new Intent(context, PowosWindowActivity.class)
                        .setData(Uri.parse("powos-window://" + id))
                        .putExtra(PowosWindowActivity.EXTRA_APP_ID, f.length > 2 ? f[2] : "")
                        .putExtra(PowosWindowActivity.EXTRA_TITLE, f.length > 3 ? f[3] : "")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NEW_DOCUMENT);
                context.startActivity(i);
                break;
            }
            case "title": {
                PowosWindowActivity a = tasks.get(id);
                if (a != null && f.length > 2)
                    a.runOnUiThread(() -> a.setTitleText(f[2]));
                break;
            }
            case "close": {
                PowosWindowActivity a = tasks.get(id);
                if (a != null)
                    a.runOnUiThread(a::closedByKWin);
                break;
            }
            default:
                Log.w(TAG, "unknown control message: " + line);
        }
    }

    /** Sends {@code <verb>\t<id>} to KWin; dropped while the channel is down (KWin knows nothing to act on then). */
    static void send(String verb, int id) {
        OutputStream o = out;
        if (o == null)
            return;
        byte[] line = (verb + "\t" + id).getBytes(StandardCharsets.UTF_8);
        try {
            synchronized (WindowTasks.class) {
                o.write(frame(CTRL_MSG_CONTROL, line));
            }
        } catch (IOException e) {
            Log.w(TAG, "control send failed: " + e.getMessage());
        }
    }

    private static byte[] frame(int type, byte[] payload) {
        return ByteBuffer.allocate(8 + payload.length).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(type).putInt(payload.length).put(payload).array();
    }

    private static byte[] le32(int v) {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array();
    }
}
