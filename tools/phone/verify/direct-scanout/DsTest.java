// DsTest.java: host for dstest.c under app_process (root) - a root SurfaceControl on the active display's layer
// stack, above everything, that dstest.c parents its child (the cloned gralloc buffer) to.
// usage: CLASSPATH=dstest.dex app_process /system/bin DsTest <libdstest.so> <layerStack> [dstest args...]
import android.view.SurfaceControl;
import java.lang.reflect.Method;
import java.util.Arrays;

public class DsTest {
    static native int run(SurfaceControl sc, String[] args);

    public static void main(String[] a) throws Throwable {
        System.load(a[0]);
        int stack = Integer.parseInt(a[1]);
        SurfaceControl sc = new SurfaceControl.Builder().setName("powos-ds-test").build();
        SurfaceControl.Transaction t = new SurfaceControl.Transaction();
        // Hidden API (no enforcement under app_process): a parentless layer shows only on the layer stack it names.
        Method ls = SurfaceControl.Transaction.class.getMethod("setLayerStack", SurfaceControl.class, int.class);
        ls.invoke(t, sc, stack);
        t.setLayer(sc, Integer.MAX_VALUE - 16);
        t.setVisibility(sc, true);
        t.apply();
        int rc = run(sc, Arrays.copyOfRange(a, 2, a.length));
        t = new SurfaceControl.Transaction();
        t.reparent(sc, null);
        t.apply();
        sc.release();
        System.out.println("EXIT " + rc);
        System.exit(rc);
    }
}
