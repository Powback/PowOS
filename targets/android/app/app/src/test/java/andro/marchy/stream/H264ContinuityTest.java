package andro.marchy.stream;

import java.nio.ByteBuffer;
import org.junit.Test;
import static org.junit.Assert.*;

public class H264ContinuityTest {
    private ByteBuffer recovery(int sps) {
        return ByteBuffer.wrap(new byte[]{0,0,0,1,0x67,(byte)sps,0,0,1,0x68,2,0,0,1,0x65,3});
    }
    private ByteBuffer delta() { return ByteBuffer.wrap(new byte[]{0,0,1,0x41,1}); }
    @Test public void requiresCompleteRecoveryAndPreservesCallerBuffer() {
        H264Continuity p = new H264Continuity();
        assertEquals(H264Continuity.Action.DROP, p.accept(delta(), 0, 640, 480));
        ByteBuffer au = recovery(1);
        assertEquals(H264Continuity.Action.RECREATE, p.accept(au, 1, 640, 480));
        assertEquals(0, au.position());
        assertEquals(H264Continuity.Action.FEED, p.accept(delta(), 2, 640, 480));
        assertEquals(H264Continuity.Action.DROP, p.accept(delta(), 4, 640, 480));
        assertEquals(H264Continuity.Action.DROP, p.accept(ByteBuffer.wrap(new byte[]{0,0,1,0x65,3}), 5, 640, 480));
        assertEquals(H264Continuity.Action.RECREATE, p.accept(recovery(1), 6, 640, 480));
    }
    @Test public void wrapAndSpsAndSizeChanges() {
        H264Continuity p = new H264Continuity();
        assertEquals(H264Continuity.Action.RECREATE, p.accept(recovery(1), 0xffffffffL, 640, 480));
        assertEquals(H264Continuity.Action.FEED, p.accept(delta(), 0, 640, 480));
        assertEquals(H264Continuity.Action.RECREATE, p.accept(recovery(2), 1, 640, 480));
        assertEquals(H264Continuity.Action.DROP, p.accept(delta(), 2, 1280, 720));
        assertEquals(H264Continuity.Action.RECREATE, p.accept(recovery(2), 3, 1280, 720));
    }
    @Test public void noMetadataInterpretation() {
        assertNull(H264Continuity.nal(ByteBuffer.wrap(new byte[32]), 7));
        assertNull(H264Continuity.nal(ByteBuffer.wrap(new byte[]{0,0,1}), 5));
    }
}
