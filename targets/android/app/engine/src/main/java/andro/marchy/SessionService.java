package andro.marchy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.BroadcastReceiver;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiInfo;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Andromarchy session: keeps the Linux side alive in a foreground service (HyperOS kills background apps).
 *
 * Starts, once per process: the Andromarchy display daemon, the PipeWire audio stack and Hyprland, the last two inside
 * the Arch rootfs through lotfix-run (the native launcher: patched glibc loader + fakechroot, no proot).
 * Layout, all under getFilesDir() (short: Unix socket paths are limited to 108 bytes):
 *   rootfs/            the Arch Linux ARM system
 *   run/               XDG_RUNTIME_DIR (Wayland, PipeWire, Hyprland sockets), excluded from fakechroot
 *   run/andromarchy/        the display daemon's socket (no-root engine; rooted mode: DISPLAY_SOCKET, no file)
 *   run/*.log          output of each process
 */
public class SessionService extends Service {
    private static final String TAG = "Andromarchy";
    private static final String CHANNEL = "session";
    private static final int NOTIFICATION_ID = 1;
    private static final String SETUP_CHANNEL = "setup";
    private static final int SETUP_NOTIFICATION_ID = 2;

    private final List<Process> processes = new ArrayList<>();
    private PowerManager.WakeLock wakeLock;

    public static File rootfs(Context ctx) {
        return new File(ctx.getFilesDir(), "rootfs");
    }

    /** The session runs in this process (false: anything left in run/ is from a previous one). */
    static volatile boolean started;

    public static File runDir(Context ctx) {
        return new File(ctx.getFilesDir(), "run");
    }

    /**
     * The display daemon's socket in rooted mode: Linux's abstract namespace (no file), where KWin (as root's user
     * powos) and this app's own connections reach it. As a privileged app (the PowOS system module), this app may not
     * create or connect to socket files in its own data (SELinux gives priv_app no sock_file rights there), and an
     * abstract socket needs none. Without files, the daemon and its clients check each other's uid instead
     * (socket_utils.c). The no-root engine keeps the socket file: its programs run as this app (fakechroot), whose
     * domain may make one, and its Linux side knows only paths.
     */
    static final String DISPLAY_SOCKET = "@powos.display";

    /** The display daemon's address: a socket path, or "@name" in the abstract namespace (see DISPLAY_SOCKET). */
    public static String daemonSocket(Context ctx) {
        return RootMode.enabled() ? DISPLAY_SOCKET : new File(runDir(ctx), "andromarchy/display_daemon.sock").getPath();
    }

    /** The display daemon is up: its socket file exists, or (abstract, no file) this app's control channel reached it. */
    static boolean daemonListening(Context ctx) {
        String address = daemonSocket(ctx);
        return address.startsWith("@") ? WindowTasks.connected() : new File(address).exists();
    }

    /** A daemon address (daemonSocket, PadHub's) for android.net.LocalSocket. */
    static android.net.LocalSocketAddress localAddress(String address) {
        return address.startsWith("@")
                ? new android.net.LocalSocketAddress(address.substring(1), android.net.LocalSocketAddress.Namespace.ABSTRACT)
                : new android.net.LocalSocketAddress(address, android.net.LocalSocketAddress.Namespace.FILESYSTEM);
    }

    /**
     * An abstract name can be bound by any process first: a connection to one only counts when the other end is
     * this app's uid or root (the daemons of this app and of the rooted session). A socket file is protected by its
     * directory instead.
     */
    static boolean trustedPeer(android.net.LocalSocket s, String address) throws IOException {
        if (!address.startsWith("@"))
            return true;
        int uid = s.getPeerCredentials().getUid();
        return uid == android.os.Process.myUid() || uid == 0;
    }

    /** True once the Arch rootfs (built by build/build-rootfs.sh) is in place. */
    public static boolean rootfsReady(Context ctx) {
        return new File(rootfs(ctx), "opt/lotfix/arch-glibc/ld-linux-aarch64.so.1").exists();
    }

    public static void start(Context ctx) {
        ctx.startForegroundService(new Intent(ctx, SessionService.class));
    }

    /**
     * {@link #start}, off the caller's thread: startForegroundService is a binder call into the activity manager -
     * 137 ms on the UI thread in MainActivity.onCreate (perf-1793409569119). The service starts asynchronously either
     * way (its onCreate runs later on the main thread); only the request moves. The caller is in front (an activity
     * being created), so the foreground start stays allowed a few ms later.
     */
    public static void startAsync(Context ctx) {
        Context app = ctx.getApplicationContext();
        START.execute(() -> {
            try {
                start(app);
            } catch (RuntimeException e) {
                android.util.Log.w("SessionService", "session service start refused", e);
            }
        });
    }

    private static final java.util.concurrent.Executor START =
        java.util.concurrent.Executors.newSingleThreadExecutor(r -> new Thread(r, "session-start"));

    @Override
    public void onCreate() {
        super.onCreate();
        started = true;
        HostGestures.apply(this); // HyperOS 3-finger gestures off again after a restart, if allowed
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Session", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE);
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("Andromarchy")
                .setContentText("Omarchy session running")
                .setContentIntent(open)
                .setOngoing(true)
                .build();
        startForeground(NOTIFICATION_ID, n);

        PowerManager pm = getSystemService(PowerManager.class);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "andromarchy:session");
        wakeLock.acquire();

        // Battery for the session's UPower stand-in (android-upower): apps cannot read /sys/class/power_supply.
        registerReceiver(battery, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        startLocation(this);
        // Active network for the NetworkManager stand-in (android-nm): apps cannot see the interfaces.
        getSystemService(ConnectivityManager.class).registerDefaultNetworkCallback(network);
        // Requests from Linux for Android-only actions (Wi-Fi panel, launching Android apps).
        requests = new AndroidRequests(this, runDir(this));
        requests.startWatching();
        // Android apps in PowOS's application menu (.desktop entries in the rootfs, launched through the requests above).
        apps = new AndroidApps(this);
        apps.register(this);
        // What Home opens (desktop or launcher); FoldWatcher refines it from the hinge on foldables.
        HomeScreen.apply(this, null);
        // Foldables: opening the phone brings the PowOS desktop up (FoldWatcher).
        fold = new FoldWatcher(this);
        fold.start();

        if (RootMode.enabled()) {
            // Rooted: started once, here, as always (nothing in it waits: su runs the session on its own).
            try {
                startSession();
            } catch (IOException e) {
                Log.e(TAG, "session start failed", e);
            }
        } else
            kick(); // no root: on the session thread, once the image is complete, with retries (SessionPlan)
        // PowOS: PowOS windows as their own Android tasks - the control channel to KWin (through the daemon).
        WindowTasks.start(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // The processes belong to this service. No root: each start request (InstallActivity done, the app opened
        // again after a give-up) looks again whether the session must start or retry.
        if (!RootMode.enabled())
            kick();
        return START_STICKY;
    }

    /** The splash's line while the session waits for the image, retries or gave up (SessionPlan.status); else null. */
    static volatile String status;

    /**
     * The no-root session's own thread: startSession runs first-boot.sh and waits for it, which held the MAIN thread
     * in onCreate (11-04 emulator: the home stopped drawing - its WebView never came alive - while the session
     * started; a foreground service's onCreate is also an ANR past 20 s).
     */
    private final android.os.Handler session = newSessionThread();
    private int attempts;
    private long startedAt = -1; // uptime of the current start, -1: none running

    private static android.os.Handler newSessionThread() {
        android.os.HandlerThread t = new android.os.HandlerThread("powos-session");
        t.start();
        return new android.os.Handler(t.getLooper());
    }

    private void kick() {
        session.removeCallbacks(step);
        session.post(step);
    }

    /** One look at the no-root session (SessionPlan): wait, start, watch, end and retry, or give up. */
    private final Runnable step = new Runnable() {
        @Override
        public void run() {
            File run = runDir(SessionService.this);
            long now = android.os.SystemClock.uptimeMillis();
            File[] wl = run.listFiles((d, n) -> n.startsWith("wayland-") && !n.endsWith(".lock"));
            SessionPlan.Health h = SessionPlan.health(startedAt >= 0, new File(run, "bus").exists(),
                    wl != null && wl.length > 0, now - startedAt, lostCore);
            SessionPlan.Action a = SessionPlan.next(false, rootfsReady(SessionService.this), InstallService.installing(SessionService.this),
                    SetupGate.pending(now), h, attempts);
            long delay = SessionPlan.retryDelayMs(attempts);
            status = SessionPlan.status(a, attempts, delay);
            switch (a) {
                case WAIT_IMAGE: // InstallService starts this service again once the image is complete
                    Log.i(TAG, "session: waiting for the PowOS image to finish installing");
                    return;
                case WAIT_SETUP: // MainActivity's setup steps (SetupGate): look again shortly
                    session.postDelayed(this, 1000);
                    return;
                case START:
                    attempts++;
                    startedAt = now;
                    lostCore = null;
                    Log.i(TAG, "session: starting (try " + attempts + ")");
                    try {
                        startSession();
                    } catch (IOException e) {
                        Log.e(TAG, "session start failed", e);
                    }
                    session.postDelayed(this, 2000);
                    return;
                case UP:
                    if (h == SessionPlan.Health.UP) {
                        if (attempts > 0)
                            Log.i(TAG, "session: up (try " + attempts + ")");
                        // attempts goes back to 0 only once it stayed up a minute (limitCheck): a session Android
                        // keeps killing right after it comes up must reach GIVE_UP, not restart every few seconds.
                        // The whole session runs by now (Plasma is what pushes it past the limit): look again then.
                        session.postDelayed(limitCheck, 60_000);
                    } else
                        session.postDelayed(this, 2000); // still coming up
                    return;
                case RETRY:
                    if (lostCore != null)
                        Log.w(TAG, "session: " + lostCore + " ended " + (now - startedAt) / 1000 + " s after try "
                                + attempts + ", the session can't work without it: ending it and trying again in "
                                + delay / 1000 + " s");
                    else
                        Log.w(TAG, "session: no D-Bus or compositor " + (now - startedAt) / 1000 + " s after try "
                                + attempts + ", ending it and trying again in " + delay / 1000 + " s");
                    endSession();
                    session.postDelayed(this, delay);
                    return;
                default:
                    Log.e(TAG, "session: gave up after " + attempts + " tries");
                    endSession();
                    attempts = 0; // the next start request (the app opened again) begins anew
            }
        }
    };

    /** Ends the processes of a failed start, so the next one begins clean. */
    private void endSession() {
        synchronized (processes) {
            for (Process p : processes)
                p.destroyForcibly();
            processes.clear();
        }
        endLeftovers("libandromarchy.so");
        // Everything the session's own programs started (kwin_wayland, plasma_session, Xwayland, the units): ending
        // only the processes this service spawned left them running - holding wayland-0 and a dead bus - so the next
        // try's KWin could not take the socket. Only this app's uid is visible and killable here.
        endGuests();
        session.removeCallbacks(limitCheck); // a stale one would count the next try as up for a minute
        startedAt = -1;
        lostCore = null;
    }

    /**
     * A session process the session can't work without ended (SessionPlan.CORE), or null. 11-09 razr: granting the
     * storage permission (asked right as the session starts) made Android SIGKILL the session's first processes -
     * D-Bus and the display daemon among them - 1 s after the start. The bus socket FILE stayed, so the session
     * counted as up; KWin, Plasma and the portals came up on a dead bus ("Not connected to D-Bus server",
     * WaitForName timed out), plasmashell never started and the desktop stayed blank. Now that ends the try and the
     * session starts again (SessionPlan.health: FAILED).
     */
    private volatile String lostCore;

    /** This app's processes that aren't its own Android ones: the Linux session's, ended outright. */
    private void endGuests() {
        File[] procs = new File("/proc").listFiles((d, n) -> n.chars().allMatch(Character::isDigit));
        if (procs == null)
            return;
        int uid = android.os.Process.myUid(), me = android.os.Process.myPid();
        for (File p : procs) {
            try {
                int pid = Integer.parseInt(p.getName());
                if (pid == me || android.system.Os.stat(p.getPath()).st_uid != uid)
                    continue;
                byte[] b = java.nio.file.Files.readAllBytes(new File(p, "cmdline").toPath());
                if (b.length > 0 && !new String(b, java.nio.charset.StandardCharsets.UTF_8).startsWith(getPackageName()))
                    android.os.Process.killProcess(pid);
            } catch (Exception e) {
                // gone meanwhile, or not ours
            }
        }
    }

    /** No-root termux-va's socket (see startSession 2c): run/termux-va/, so its 01777 chmod stays off the run dir. */
    static File termuxVaSocket(File run) {
        return new File(run, "termux-va/termux-va.sock");
    }

    private void startSession() throws IOException {
        File run = runDir(this);
        String sock = daemonSocket(this);
        if (!sock.startsWith("@")) {
            File file = new File(sock);
            file.getParentFile().mkdirs();
            // A stale socket from a killed session would make the daemon's bind fail - and with it the whole session.
            if (file.exists() && !file.delete())
                Log.e(TAG, "can't remove the stale display socket " + file + ": the display daemon won't start");
        }

        String libDir = getApplicationInfo().nativeLibraryDir;
        String launcher = libDir + "/liblotfixrun.so";

        // PowOS rooted mode (RootMode): the display daemon here as always, then the whole session as root inside
        // PowOS's own system - D-Bus, PipeWire, the stand-in services and the desktop (rooted/powos-rooted-session).
        // Nothing of the no-root engine below runs. The session sees this run dir at /run/powos-app (bind mount), so
        // the phone-state files and desktop-ready (SplashScreen) are shared as they are; the daemon listens in the
        // abstract namespace (DISPLAY_SOCKET), which the session shares too.
        if (RootMode.enabled()) {
            // A daemon this app's previous process left (killed without onDestroy) still holds the abstract name.
            endLeftovers("libandromarchy.so");
            // The screen the desktop will get, for KWin before the desktop is first shown (see andromarchy.c,
            // provisional_screen): else KWin's startup - and all of Plasma's - waited for it to be opened.
            spawn("andromarchy", List.of(libDir + "/libandromarchy.so", sock, "--screen", screenArg()), null);
            // Hardware video for PowOS (VA-API through Mesa's termuxva bridge -> MediaCodec), as below - here started
            // by the root session (powos-session.sh, from this app's libtermuxva.so): Mesa's termuxva client only
            // connects to a socket file, which a privileged app can't make, and root can.
            endLeftovers("libtermuxva.so"); // one an older version of this app started
            Map<String, String> env = archEnv(run, sock);
            spawn("powos-root-session", List.of("su", "-c", "sh " + RootMode.SESSION + " " + run.getPath() + " "
                    + sock + " " + env.get("ANDROMARCHY_PHYSICAL_MM") + " " + env.get("LANG") + " "
                    + env.get("TZ") + " " + libDir + "/libtermuxva.so"), null);
            return;
        }

        // XDG_RUNTIME_DIR is the run dir: owner only, as the spec (and Qt's QStandardPaths check) wants. A device set up
        // before termuxVaSocket moved still has it at 01777. Rooted mode doesn't come here (root's session reads it).
        try {
            android.system.Os.chmod(run.getPath(), 0700);
        } catch (android.system.ErrnoException e) {
            Log.w(TAG, "can't make " + run + " 0700: " + e);
        }

        // 0. First boot of this rootfs on this device (once; the locale part on each start): see first-boot.sh.
        try {
            ProcessBuilder pb = new ProcessBuilder(launcher, "/opt/lotfix/first-boot.sh");
            pb.environment().clear();
            pb.environment().putAll(archEnv(run, sock));
            Process fb = pb.redirectErrorStream(true)
                    .redirectOutput(new File(run, "first-boot.log")).start();
            fb.getOutputStream().close();
            fb.waitFor();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        // 0b. PowOS: our packages (KWin with the Anland backend, box64, FEX, PowOS packages Arch Linux ARM doesn't
        //     build) from the [powos] repo in the PowApps store (targets/android/publish-repo.sh), installed and
        //     updated on each start - phones get them without adb or a new rootfs. Its own pacman config with only
        //     that repo: Arch's repos are never refreshed here, so this can't make a partial upgrade. Off the
        //     store's network (android.pow unresolvable) it just fails; in the background, so the session starts
        //     at once, and an updated KWin takes over on the next session.
        File repoConf = new File(rootfs(this), "etc/pacman.d/powos-repo.conf");
        repoConf.getParentFile().mkdirs();
        // HACK: SigLevel TrustAll - the repo is unsigned (served over plain HTTP on the LAN/VPN only). Real fix:
        // sign the packages in build-pkgs.sh with a PowOS key and ship its public key in the rootfs keyring.
        try (java.io.FileWriter w = new java.io.FileWriter(repoConf)) {
            w.write("[options]\nArchitecture = auto\nDisableSandbox\nSigLevel = Optional TrustAll\n\n"
                    + "[powos]\nServer = http://android.pow/apk/repo\n");
        }
        // Upgrades only, never a downgrade (SessionPlan.packagesCommand: a stale repo's KWin broke the session).
        spawn("powos-packages", List.of(launcher, "-c", SessionPlan.packagesCommand()), archEnv(run, sock));

        // 1. Display daemon: relays buffers and input between this app's display and the compositor. With the
        //    screen the desktop will get, as in rooted mode (andromarchy.c, provisional_screen): without it KWin's
        //    handshake waited for the desktop to be on screen, so a session started behind home never got as far as
        //    org.kde.KWin - every app launch from home (powos-open-task) said "desktop" (exit 2) and no window came.
        spawn("andromarchy", List.of(libDir + "/libandromarchy.so", sock, "--screen", screenArg()), null);

        // 2. Session D-Bus (systemd provides it on a normal Linux login). Browsers, file dialogs, portals and tray
        //    apps need it; archEnv() gives every program its address.
        new File(run, "bus").delete();
        spawn("dbus", List.of(launcher, "-c", "exec dbus-daemon --session --nofork --nopidfile --address=unix:path="
                + new File(run, "bus").getPath()), archEnv(run, sock));

        // 2b. A "system" bus of our own (there is none for apps), for the services standing in for hardware ones.
        new File(run, "system_bus").delete();
        spawn("system-dbus", List.of(launcher, "-c", "exec dbus-daemon --config-file=/opt/lotfix/system-bus.conf"
                + " --nofork --nopidfile --address=unix:path=" + new File(run, "system_bus").getPath()), archEnv(run, sock));
        spawn("android-nm", List.of(launcher, "-c", "for i in $(seq 50); do [ -S \"$XDG_RUNTIME_DIR/system_bus\" ]"
                + " && break; sleep 0.1; done; exec android-nm"), archEnv(run, sock));
        spawn("android-upower", List.of(launcher, "-c", "for i in $(seq 50); do [ -S \"$XDG_RUNTIME_DIR/system_bus\" ]"
                + " && break; sleep 0.1; done; exec android-upower"), archEnv(run, sock));
        // The other system services a desktop expects (login1, hostname1, timedate1, locale1, PolicyKit, power
        // profiles, Accounts, RealtimeKit, GeoClue), as stand-ins: native/android-system-services.py.
        spawn("android-system-services", List.of(launcher, "-c", "for i in $(seq 50); do [ -S \"$XDG_RUNTIME_DIR/"
                + "system_bus\" ] && break; sleep 0.1; done; exec android-system-services"), archEnv(run, sock));
        // Session side: ScreenSaver inhibit and FileManager1 (native/android-session-services.py), and the secrets
        // keyring (passwords for browsers, VS Code, git). No login screen unlocks a keyring here: a password-less
        // "login" keyring is created once (gnome-keyring's plain format) and made the default.
        spawn("android-session-services", List.of(launcher, "-c", "for i in $(seq 50); do [ -S \"$XDG_RUNTIME_DIR/"
                + "bus\" ] && break; sleep 0.1; done; exec android-session-services"), archEnv(run, sock));
        // Only when the image has it: a base image without it (11-09 razr) spent one of Android's 32 child processes
        // on "exec: gnome-keyring-daemon: not found". rootfs-packs.conf keeps it in the base now.
        if (new File(rootfs(this), "usr/bin/gnome-keyring-daemon").exists())
            spawn("gnome-keyring", List.of(launcher, "-c", "for i in $(seq 50); do [ -S \"$XDG_RUNTIME_DIR/bus\" ] && break;"
                + " sleep 0.1; done; K=$HOME/.local/share/keyrings; mkdir -p $K && chmod 700 $K;"
                + " [ -f $K/login.keyring ] || printf '[keyring]\\ndisplay-name=Login\\nctime=0\\nmtime=0\\n"
                + "lock-on-idle=false\\nlock-after=false\\n' > $K/login.keyring; [ -f $K/default ] || printf login > $K/default;"
                + " exec gnome-keyring-daemon --foreground --components=secrets < /dev/null"), archEnv(run, sock));

        // 2c. Hardware video (termux-va, third_party/): decodes and encodes with MediaCodec for the VA-API bridge.
        //     Its socket in a directory of its own (termuxVaSocket): the daemon chmods its socket's directory to 01777
        //     (shared-tmp containers), which made the whole run dir world-writable - Qt then refused XDG_RUNTIME_DIR
        //     ("wrong permissions on runtime directory ... 0777 instead of 0700").
        File tva = termuxVaSocket(run);
        tva.getParentFile().mkdirs();
        spawn("termux-va", List.of(libDir + "/libtermuxva.so", "--sock", tva.getPath()), null);

        // 3. Sound: Hyprland's Andromarchy backend creates PipeWire nodes, so the stack must exist (it reconnects anyway).
        //    wireplumber and pipewire-pulse give up when PipeWire is not up yet (a cold first start): they wait for its
        //    socket.
        spawn("pipewire", List.of(launcher, "-c", "exec pipewire"), archEnv(run, sock));
        for (String p : new String[] {"wireplumber", "pipewire-pulse"})
            spawn(p, List.of(launcher, "-c", "for i in $(seq 100); do [ -S \"$XDG_RUNTIME_DIR/pipewire-0\" ] && break;"
                    + " sleep 0.1; done; exec " + p), archEnv(run, sock));

        // 4. Hyprland with Omarchy. It waits for this app's display to connect (MainActivity).
        Map<String, String> env = archEnv(run, sock);
        env.put("EGL_PLATFORM", "surfaceless");
        env.put("OMARCHY_PATH", "/usr/share/omarchy");
        spawn("hyprland", List.of(launcher, "-c", "export PATH=/usr/share/omarchy/bin:$PATH; exec /usr/bin/Hyprland"), env);

        // 5. desktop-ready (ends the splash, SplashScreen): the session launcher touches it once plasmashell runs
        //    (session/Hyprland). The app's own waiter for Omarchy's quickshell is gone: PowOS has no quickshell, so it
        //    only polled pgrep for 2 minutes - a process and ~600 more against Android 12+'s child process limit.
    }

    /**
     * The default display's current size and refresh rate as "WxH@mHz" - what the desktop's surface reports once it is
     * on screen (native_consumer.c: the full-screen SurfaceView's size, in the display's current rotation).
     */
    private String screenArg() {
        android.view.Display d = getSystemService(android.hardware.display.DisplayManager.class)
                .getDisplay(android.view.Display.DEFAULT_DISPLAY);
        android.util.DisplayMetrics m = new android.util.DisplayMetrics();
        d.getRealMetrics(m); // deprecated for window sizes; here it is the panel's, which is what is wanted
        return m.widthPixels + "x" + m.heightPixels + "@" + Math.round(d.getRefreshRate() * 1000);
    }

    /**
     * Ends this app's processes running nativeLibraryDir's [lib] that this process didn't start: left by a previous
     * process of the app that was killed outright. Only this app's uid is visible and killable here.
     */
    private static void endLeftovers(String lib) {
        File[] procs = new File("/proc").listFiles((d, n) -> n.chars().allMatch(Character::isDigit));
        if (procs == null)
            return;
        for (File p : procs) {
            String cmd;
            try {
                byte[] b = java.nio.file.Files.readAllBytes(new File(p, "cmdline").toPath());
                int end = 0;
                while (end < b.length && b[end] != 0)
                    end++;
                cmd = new String(b, 0, end, java.nio.charset.StandardCharsets.UTF_8);
            } catch (IOException | SecurityException e) {
                continue;
            }
            if (cmd.endsWith("/" + lib)) {
                Log.i(TAG, "ending a leftover " + lib + " (pid " + p.getName() + ")");
                android.os.Process.killProcess(Integer.parseInt(p.getName()));
            }
        }
    }

    /** Android's language as a glibc locale name (fr_FR.UTF-8); C.UTF-8 when it has no country. */
    static String androidLocale(Context ctx) {
        java.util.Locale l = ctx.getResources().getConfiguration().getLocales().get(0);
        return l.getCountry().isEmpty() ? "C.UTF-8" : l.getLanguage() + "_" + l.getCountry() + ".UTF-8";
    }

    /** Environment for programs of the rootfs; lotfix-run sets the rest (loader, fakechroot, GPU...). */
    private Map<String, String> archEnv(File run, String sock) {
        return archEnv(this, run, sock);
    }

    /**
     * No-root PowOS: a process running {@code sh -c command} in the rootfs (lotfix-run, the same way in as the
     * session's own programs), with the session's environment - for the launcher's widget commands and streams
     * (dev.omalauncher.linux.EngineGuest). Needs no running session: a command that only reads files and runs tools
     * works without it; one that talks to the session's D-Bus needs the session up.
     */
    public static ProcessBuilder guestProcess(Context ctx, String command) {
        ProcessBuilder pb = new ProcessBuilder(ctx.getApplicationInfo().nativeLibraryDir + "/liblotfixrun.so", "-c", command);
        File run = runDir(ctx);
        run.mkdirs();
        pb.environment().clear();
        pb.environment().putAll(guestEnv(ctx, run));
        return pb;
    }

    /**
     * The environment of everything the app starts in the running session (Guest/EngineGuest: app launches,
     * powos-open-task, terminals, widgets, AI chat): the session programs' own (archEnv: its bus, run dir) plus the
     * desktop's display, as a program the desktop started has it. archEnv drops WAYLAND_DISPLAY (KWin itself must not
     * get one, it'd start nested); without it every app the launcher opened died at once (Qt: no display, abort -6)
     * and powos-open-task said "failed: exited -6". KWin's socket in XDG_RUNTIME_DIR, as rooted mode's
     * (RootedGuest.WAYLAND_DISPLAY).
     */
    static Map<String, String> guestEnv(Context ctx, File run) {
        Map<String, String> env = archEnv(ctx, run, daemonSocket(ctx));
        env.put("WAYLAND_DISPLAY", "wayland-0");
        env.put("TERM", "xterm-256color");
        return env;
    }

    static Map<String, String> archEnv(Context ctx, File run, String sock) {
        Map<String, String> env = new java.util.HashMap<>(System.getenv());
        env.put("ARCH_ROOTFS", rootfs(ctx).getPath());
        // sockets: real paths, not rewritten into the rootfs. PowOS: also the phone's shared storage (/storage,
        // /sdcard), so PowOS's file manager and apps see the phone's files (storage permission: MainActivity).
        env.put("ARCH_EXCLUDE_EXTRA", run.getPath() + ":/storage:/sdcard");
        env.put("XDG_RUNTIME_DIR", run.getPath());
        env.put("TZ", java.util.TimeZone.getDefault().getID()); // glibc only knows /etc/localtime otherwise: UTC
        env.put("LANG", androidLocale(ctx)); // Android's language (first-boot.sh compiles its locale)
        env.put("ANDROMARCHY_UID", String.valueOf(android.os.Process.myUid()));
        env.put("ANDROMARCHY_GID", String.valueOf(android.os.Process.myUid()));
        env.put("ANDROMARCHY_SOCKET", sock);
        // The display's physical size (landscape, mm) for the compositor's output: clients size themselves from it
        android.util.DisplayMetrics dm = new android.util.DisplayMetrics();
        ((android.view.WindowManager) ctx.getSystemService(WINDOW_SERVICE)).getDefaultDisplay().getRealMetrics(dm);
        int wmm = Math.round(Math.max(dm.widthPixels / dm.xdpi, dm.heightPixels / dm.ydpi) * 25.4f);
        int hmm = Math.round(Math.min(dm.widthPixels / dm.xdpi, dm.heightPixels / dm.ydpi) * 25.4f);
        env.put("ANDROMARCHY_PHYSICAL_MM", wmm + "x" + hmm);
        // Flatpak apps' launchers (exported .desktop files, icons): a normal login gets these from
        // /etc/profile.d/flatpak.sh or systemd's environment generator; this session starts from the app.
        env.put("XDG_DATA_DIRS", "/root/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share"
                + ":/usr/local/share:/usr/share");
        env.put("ANDROMARCHY_VENDOR", android.os.Build.MANUFACTURER); // the machine's identity (DMI) for Linux tools
        env.put("ANDROMARCHY_MODEL", android.os.Build.MODEL);
        env.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + new File(run, "bus").getPath());
        env.put("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=" + new File(run, "system_bus").getPath());
        // Hardware video: VA-API through Mesa's termuxva bridge to the termux-va daemon (MediaCodec), when the
        // rootfs's Mesa has the bridge.
        if (new File(rootfs(ctx), "usr/lib/dri/termuxva_drv_video.so").exists()) {
            env.put("LIBVA_DRIVER_NAME", "termuxva");
            env.put("TERMUX_VA_BRIDGE", "1");
            env.put("TERMUX_VA_GPU_BACKEND", "kgsl");
            env.put("TERMUX_VA_SOCKET", termuxVaSocket(run).getPath());
        }
        // No root: PowOS's service ports (SpacetimeDB, the App API) are private Unix sockets in loopbackDir, not TCP
        // ports every app on the phone could reach (lotfix-run preloads loopback-unix.c; docs/research/nonroot-parity.md).
        // Rooted: powos-start.sh locks the TCP ports to this uid instead, so nothing here.
        if (!RootMode.enabled()) {
            env.put("POWOS_LOOPBACK_DIR", loopbackDir(ctx).getPath());
            env.put("POWOS_LOOPBACK_PORTS", LOOPBACK_PORTS);
            env.put("POWOS_LOOPBACK_PRELOAD", ctx.getApplicationInfo().nativeLibraryDir + "/libpowosloopback.so");
        }
        env.remove("WAYLAND_DISPLAY");
        env.remove("DISPLAY");
        return env;
    }

    /**
     * The no-root PowOS image's service ports, which loopback-unix.c turns into Unix sockets in the app's private files:
     * SpacetimeDB 3410, the App API 3411, and 5037 - the adb server any `adb` call of the image starts (powos android,
     * powos-deviced, scrcpy): on Android's shared loopback it was reachable by every app on the phone, which could then
     * drive PowOS's adb (razr 11-09, board-close-waiting). The image's adb clients reach it at 127.0.0.1:5037 as before.
     */
    public static final String LOOPBACK_PORTS = "3410,3411,5037";

    /** Where those sockets are (<port>.sock): the app's private files, 0700, so only this app's uid opens them. */
    public static File loopbackDir(Context ctx) {
        File d = new File(runDir(ctx), "loopback");
        if (d.mkdirs() || d.isDirectory()) {
            d.setReadable(false, false);
            d.setWritable(false, false);
            d.setExecutable(false, false);
            d.setReadable(true, true);
            d.setWritable(true, true);
            d.setExecutable(true, true);
        }
        return d;
    }

    /** Android's default network -> run/network ("wifi <strength> <ssid>" | "wired" | "none"), read by android-nm. */
    private AndroidRequests requests;
    private AndroidApps apps;
    private FoldWatcher fold;

    // FLAG_INCLUDE_LOCATION_INFO: the Wi-Fi name (SSID) instead of "<unknown ssid>", once location is granted.
    private final ConnectivityManager.NetworkCallback network = new ConnectivityManager.NetworkCallback(
            ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO) {
        @Override
        public void onLinkPropertiesChanged(Network n, android.net.LinkProperties lp) {
            StringBuilder dns = new StringBuilder(); // for omarchy-dns "DHCP": the network's own DNS servers
            for (java.net.InetAddress a : lp.getDnsServers())
                dns.append(dns.length() > 0 ? " " : "").append(a.getHostAddress());
            writeState("dns", dns.toString());
        }

        @Override
        public void onCapabilitiesChanged(Network n, NetworkCapabilities caps) {
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                int strength = 0;
                String ssid = "";
                if (caps.getTransportInfo() instanceof WifiInfo) {
                    WifiInfo w = (WifiInfo) caps.getTransportInfo();
                    strength = Math.max(0, Math.min(100, 2 * (w.getRssi() + 100))); // -100..-50 dBm -> 0..100
                    ssid = w.getSSID().replace("\"", ""); // redacted without the location permission
                    if (ssid.startsWith("<"))
                        ssid = "";
                }
                writeState("network", "wifi " + strength + " " + ssid);
            } else
                writeState("network", "wired"); // mobile data, USB, Ethernet: Quickshell only knows wired
        }

        @Override
        public void onLost(Network n) {
            writeState("network", "none");
        }
    };

    /** Atomic write of one line to run/<name>: the reader never sees half a line. */
    private void writeState(String name, String line) {
        File f = new File(runDir(this), name), tmp = new File(runDir(this), "." + name);
        try (java.io.FileWriter w = new java.io.FileWriter(tmp)) {
            w.write(line + "\n");
        } catch (IOException e) {
            return;
        }
        tmp.renameTo(f);
    }

    /** Android battery state -> run/battery ("<percent> <charging 0|1>"), read by android-upower. */
    /** Android's network location -> run/location ("lat lon accuracy unixtime"), served as GeoClue2 by
     *  android-system-services. Network provider: coarse, cheap on battery; every 10 minutes or 500 m. Called again
     *  by MainActivity once the permission is granted. */
    static void startLocation(Context ctx) {
        if (ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED)
            return;
        android.location.LocationManager lm = ctx.getSystemService(android.location.LocationManager.class);
        String provider = lm.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER)
                ? android.location.LocationManager.NETWORK_PROVIDER : android.location.LocationManager.PASSIVE_PROVIDER;
        android.location.LocationListener l = loc -> {
            File f = new File(runDir(ctx), "location"), tmp = new File(runDir(ctx), ".location");
            try (java.io.FileWriter w = new java.io.FileWriter(tmp)) {
                w.write(loc.getLatitude() + " " + loc.getLongitude() + " " + loc.getAccuracy() + " "
                        + loc.getTime() / 1000 + "\n");
            } catch (IOException e) {
                return;
            }
            tmp.renameTo(f);
        };
        android.location.Location last = lm.getLastKnownLocation(provider);
        if (last != null)
            l.onLocationChanged(last);
        lm.requestLocationUpdates(provider, 10 * 60 * 1000L, 500f, l, android.os.Looper.getMainLooper());
    }

    private final BroadcastReceiver battery = new BroadcastReceiver() {
        @Override
        public void onReceive(Context ctx, Intent i) {
            int level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            int status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            boolean charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL;
            if (level < 0)
                return;
            File f = new File(runDir(ctx), "battery"), tmp = new File(runDir(ctx), ".battery");
            try (java.io.FileWriter w = new java.io.FileWriter(tmp)) {
                w.write((level * 100 / scale) + " " + (charging ? 1 : 0) + "\n");
            } catch (IOException e) {
                return;
            }
            tmp.renameTo(f); // atomic: the reader never sees half a line
        }
    };

    private void spawn(String name, List<String> cmd, Map<String, String> env) throws IOException {
        ProcessBuilder pb = new ProcessBuilder(cmd);
        if (env != null) {
            pb.environment().clear();
            pb.environment().putAll(env);
        }
        File log = new File(runDir(this), name + ".log");
        // Runs on as long as the session: none of this app's pipes (docs/powos-window-tasks.md "Output"):
        // stdin /dev/null, output its log (made anew each start).
        pb.redirectErrorStream(true).redirectOutput(log)
                .redirectInput(new File("/dev/null"));
        Process p = pb.start();
        synchronized (processes) {
            processes.add(p);
        }
        Log.i(TAG, "started " + name + " (log: " + log + ")");
        watch(name, p);
    }

    /**
     * Notices a session process Android ended (PhantomLimit.killedByAndroid): SIGKILL while still one of this
     * session's - endSession/onDestroy take theirs out of `processes` in the same step as they end them.
     */
    private void watch(String name, Process p) {
        Thread t = new Thread(() -> {
            int code;
            try {
                code = p.waitFor();
            } catch (InterruptedException e) {
                return;
            }
            boolean ours;
            synchronized (processes) {
                ours = processes.remove(p);
            }
            if (PhantomLimit.killedByAndroid(code, !ours)) {
                Log.w(TAG, "session: " + name + " was killed (signal 9) - Android's child process limit?");
                phantomNotice(true);
            }
            // A core process gone while this try still owns it (not ended by endSession): the try has failed.
            if (ours && !RootMode.enabled() && SessionPlan.CORE.contains(name) && lostCore == null) {
                lostCore = name;
                kick();
            }
        }, "watch-" + name);
        t.setDaemon(true);
        t.start();
    }

    /** The guest at or over Android's child process limit while the limit is on: the setup step, before a kill. */
    private final Runnable limitCheck = () -> {
        if (startedAt >= 0 && lostCore == null)
            attempts = 0; // up for a minute: a later failure starts counting anew
        int n = guestProcesses();
        Log.i(TAG, "session: " + n + " guest processes (Android 12+ limit " + PhantomLimit.ANDROID_LIMIT + ")");
        if (PhantomLimit.atLimit(n))
            phantomNotice(false, n);
    };

    /** This app's processes other than its own Android ones (the app, :restart): the Linux session's. */
    private int guestProcesses() {
        File[] procs = new File("/proc").listFiles((d, n) -> n.chars().allMatch(Character::isDigit));
        if (procs == null)
            return 0;
        int uid = android.os.Process.myUid(), n = 0;
        for (File p : procs) {
            try {
                if (android.system.Os.stat(p.getPath()).st_uid != uid)
                    continue;
                byte[] b = java.nio.file.Files.readAllBytes(new File(p, "cmdline").toPath());
                if (!new String(b, java.nio.charset.StandardCharsets.UTF_8).startsWith(getPackageName()))
                    n++;
            } catch (Exception e) {
                // gone meanwhile, or not ours
            }
        }
        return n;
    }

    private static volatile boolean phantomNoticeShown; // once per app process: a setup step, not an alarm

    private void phantomNotice(boolean killed) {
        phantomNotice(killed, guestProcesses());
    }

    /** The one-time setup step (ChildProcessSetupActivity), as a notification, when this phone still has the limit. */
    private void phantomNotice(boolean killed, int processes) {
        PhantomLimit.Fix fix = PhantomLimit.fix(android.os.Build.VERSION.SDK_INT,
                android.provider.Settings.Global.getString(getContentResolver(), PhantomLimit.MONITOR_SETTING));
        if (fix == PhantomLimit.Fix.NONE)
            return;
        if (phantomNoticeShown)
            return;
        phantomNoticeShown = true;
        Intent open = new Intent(this, ChildProcessSetupActivity.class)
                .putExtra(ChildProcessSetupActivity.EXTRA_KILLED, killed)
                .putExtra(ChildProcessSetupActivity.EXTRA_PROCESSES, processes)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(SETUP_CHANNEL, "Setup", NotificationManager.IMPORTANCE_HIGH));
        nm.notify(SETUP_NOTIFICATION_ID, new Notification.Builder(this, SETUP_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("Linux apps: one setup step")
                .setContentText(killed ? "Android stopped part of the desktop. Turn off child process restrictions."
                        : "Turn off Android's child process restrictions, or Linux apps may close.")
                .setContentIntent(PendingIntent.getActivity(this, 1, open,
                        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT))
                .setAutoCancel(true)
                .build());
    }

    @Override
    public void onDestroy() {
        unregisterReceiver(battery);
        getSystemService(ConnectivityManager.class).unregisterNetworkCallback(network);
        requests.stopWatching();
        unregisterReceiver(apps);
        fold.stop();
        session.removeCallbacksAndMessages(null);
        session.getLooper().quitSafely();
        synchronized (processes) {
            for (Process p : processes)
                p.destroy();
            processes.clear(); // ended by the app, not by Android (watch)
        }
        if (wakeLock != null && wakeLock.isHeld())
            wakeLock.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
