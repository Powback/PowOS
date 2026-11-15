package andro.marchy.stream;

import java.nio.ByteBuffer;
import java.util.Arrays;

/** Pure-JVM policy: never feed a P frame after a missing reference or a format change. */
public final class H264Continuity {
    private long last = -1;
    private int width, height;
    private byte[] sps, pps;
    private boolean waiting = true;
    public enum Action { DROP, FEED, RECREATE }

    public Action accept(ByteBuffer au, long id, int w, int h) {
        byte[] nextSps = nal(au, 7), nextPps = nal(au, 8);
        boolean idr = nal(au, 5) != null;
        boolean gap = last >= 0 && ((last + 1) & 0xffffffffL) != id;
        last = id;
        boolean format = w != width || h != height
            || (nextSps != null && !Arrays.equals(sps, nextSps))
            || (nextPps != null && !Arrays.equals(pps, nextPps));
        if (gap || format) waiting = true;
        if (waiting) {
            // IDR alone is not a recovery guarantee. Require both parameter sets in THIS AU;
            // do not combine a new PPS with stale SPS or infer codec bytes from FrameMeta.
            if (!idr || nextSps == null || nextPps == null) return Action.DROP;
            sps = nextSps; pps = nextPps; width = w; height = h; waiting = false;
            return Action.RECREATE;
        }
        return Action.FEED;
    }

    public static byte[] nal(ByteBuffer data, int wanted) {
        int end = data.limit();
        for (int i = data.position(); i + 3 < end; i++) {
            int prefix = prefix(data, i);
            if (prefix == 0 || i + prefix >= end) continue;
            int start = i + prefix;
            int next = start + 1;
            while (next + 3 < end && prefix(data, next) == 0) next++;
            if (next + 3 >= end) next = end;
            if ((data.get(start) & 31) == wanted) {
                byte[] bytes = new byte[next - i];
                ByteBuffer view = data.duplicate(); view.position(i); view.get(bytes);
                return bytes;
            }
            i = next - 1;
        }
        return null;
    }
    private static int prefix(ByteBuffer b, int i) {
        if (i + 2 >= b.limit() || b.get(i) != 0 || b.get(i + 1) != 0) return 0;
        if (b.get(i + 2) == 1) return 3;
        return i + 3 < b.limit() && b.get(i + 2) == 0 && b.get(i + 3) == 1 ? 4 : 0;
    }
}
