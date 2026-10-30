import android.content.*;
import android.hardware.display.*;
import android.media.ImageReader;
import android.graphics.PixelFormat;
import android.os.*;

/** Touch probe: a trusted VD (flags argv[0]) as shell, optionally with a uinput touchscreen associated to it; prints its id, holds argv[1] ms. */
public class T1 {
  public static void main(String[] a) throws Exception {
    Looper.prepareMainLooper();
    Class<?> at = Class.forName("android.app.ActivityThread");
    java.lang.reflect.Constructor<?> c = at.getDeclaredConstructor(); c.setAccessible(true);
    Object th = c.newInstance();
    java.lang.reflect.Field f = at.getDeclaredField("sCurrentActivityThread"); f.setAccessible(true); f.set(null, th);
    java.lang.reflect.Field s = at.getDeclaredField("mSystemThread"); s.setAccessible(true); s.setBoolean(th, true);
    final Context sys = (Context) at.getMethod("getSystemContext").invoke(th);
    Context ctx = new ContextWrapper(sys) {
      public String getPackageName() { return "com.android.shell"; }
      public String getOpPackageName() { return "com.android.shell"; }
      public AttributionSource getAttributionSource() { return new AttributionSource.Builder(2000).setPackageName("com.android.shell").build(); }
      public Context getApplicationContext() { return this; }
    };
    java.lang.reflect.Constructor<DisplayManager> dc = DisplayManager.class.getDeclaredConstructor(Context.class); dc.setAccessible(true);
    DisplayManager dm = dc.newInstance(ctx);
    ImageReader r = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2);
    int flags = Integer.decode(a[0]);
    VirtualDisplay vd = dm.createVirtualDisplay("powos-ww-probe", 1298, 1761, 442, r.getSurface(), flags);
    String uid = (String) android.view.Display.class.getMethod("getUniqueId").invoke(vd.getDisplay());
    System.out.println("T1 VD " + vd.getDisplay().getDisplayId() + " " + uid);
    java.lang.Process p = null;
    if (a.length > 2) {
      IBinder b = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "input");
      Object svc = Class.forName("android.hardware.input.IInputManager$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
      svc.getClass().getMethod("addUniqueIdAssociationByPort", String.class, String.class).invoke(svc, "powos-ww-probe", uid);
      p = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
      p.getOutputStream().write(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(a[2]))); p.getOutputStream().write(10); p.getOutputStream().flush();
      System.out.println("T1 uinput up");
    }
    Thread.sleep(Long.parseLong(a[1]));
    if (p != null) p.destroy();
    vd.release();
    System.out.println("T1 done");
    System.exit(0);
  }
}
