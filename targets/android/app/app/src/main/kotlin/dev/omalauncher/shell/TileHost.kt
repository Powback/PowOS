package dev.omalauncher.shell

import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.text.TextUtils
import android.util.Log
import dev.omalauncher.shell.tiles.IQSService
import dev.omalauncher.shell.tiles.IQSTileService
import java.util.concurrent.ConcurrentHashMap

/**
 * The control center's third-party tiles (custom(pkg/cls) in sysui_qs_tiles: OnePlus Share, Quick Share, eye
 * comfort...), hosted here as SystemUI hosts them, so they switch in place instead of opening their app: PowOS binds
 * each tile's TileService (TileService.ACTION_QS_TILE, with an IQSService of its own and a token per tile, as AOSP's
 * TileLifecycleManager does), tells it it's added (once ever, kept in tiles_prefs as there), listening while the control
 * center shows, and tapped; the service answers with its Tile (updateQsTile: label, subtitle, state), which the page
 * shows ([QuickSettings.tile]).
 *
 * One per process: every page's [QuickSettings] (home, shade, lock...) reads the same tiles and is told of a change
 * ([attach]); the tiles listen while any of them is shown ([listening]). Bound when the tiles are first known (to have
 * their state before the control center first opens), when shown, when tapped; unbound [UNBIND_MS] after, as
 * SystemUI's TileServiceManager lets a tile go - the last state stays.
 *
 * Needs BIND_QUICK_SETTINGS_TILE, which every TileService requires of its binder: signature|recents on the phone, and
 * PowOS holds the recents role.
 *
 * HACK: hosting tiles at all - the tile interfaces (IQSService, IQSTileService) are hidden framework API, copied in
 * src/main/aidl/dev/omalauncher/shell/tiles/ under the framework's descriptors, method order (the transaction codes)
 * AOSP android16's. Real fix: none for an app; only SystemUI hosts tiles. What PowOS can't do as SystemUI does: a
 * tile's dialog (TileService.showDialog) needs its click token added as a TYPE_QS_DIALOG window token, which takes
 * MANAGE_APP_TOKENS (signature) - such a tile's dialog fails in its own process; and the status bar icon a system tile
 * may set (updateStatusIcon) is SystemUI's status bar's, so it's dropped.
 */
object TileHost {
    private const val TAG = "PowosTiles"

    /** TileLifecycleManager's: the tiles told onTileAdded, by component. */
    private const val PREFS = "tiles_prefs"

    /** A tile's binding kept this long after it stops listening (SystemUI's TileServiceManager: 30 s). */
    private const val UNBIND_MS = 30_000L

    /** How long a tile listens on its own: first bound (for its state), or tapped while the control center is shut. */
    private const val AWAKE_MS = 5_000L

    /** A binding that died is tried again after this. */
    private const val REBIND_MS = 1_000L

    /**
     * HACK: Context.BIND_FOREGROUND_SERVICE_WHILE_AWAKE is hidden (@hide), the flag SystemUI binds tiles with (with
     * BIND_AUTO_CREATE and BIND_WAIVE_PRIORITY): the tile's process at foreground-service priority while the screen
     * is on. Real fix: none public; BIND_IMPORTANT is near but keeps it up with the screen off too.
     */
    private const val BIND_FOREGROUND_SERVICE_WHILE_AWAKE = 0x02000000

    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private val keyguard by lazy { app!!.getSystemService(KeyguardManager::class.java) }

    /** The hosted tiles, by id (custom(...)), in the phone's order. Main thread. */
    private val tiles = LinkedHashMap<String, Hosted>()

    /** The same, by token: IQSService's calls come on binder threads. */
    private val byToken = ConcurrentHashMap<IBinder, Hosted>()

    private val listeners = LinkedHashSet<Listener>()

    /** The pages showing the control center ([listening]). */
    private val shown = HashSet<Any>()

    /** Listening without a page shown, until then ([AWAKE_MS]). */
    private var awakeUntil = 0L

    /** A page's QuickSettings: told when a tile's state changes, and when a tile asks the panel to go (it opens something). */
    class Listener(
        val changed: () -> Unit,
        val collapse: () -> Unit,
    )

    /** A hosted tile's state as it last reported it: null until it has. */
    class State(
        val label: CharSequence?,
        val subtitle: CharSequence?,
        val state: Int,
    )

    fun attach(
        context: Context,
        listener: Listener,
    ) {
        if (app == null) app = context.applicationContext
        listeners += listener
    }

    fun detach(
        listener: Listener,
        owner: Any,
    ) {
        listeners -= listener
        listening(owner, false)
    }

    /**
     * The phone's tile order's third-party tiles ([ids]: custom(pkg/cls)): those not hosted yet bound, briefly, for
     * their state; those gone from it let go. Idempotent - every page's QuickSettings calls it.
     */
    fun host(ids: List<String>) {
        val ctx = app ?: return
        var added = false
        for (id in ids) {
            if (id in tiles) continue
            val cn = ComponentName.unflattenFromString(id.removePrefix("custom(").removeSuffix(")")) ?: continue
            val info = runCatching { ctx.packageManager.getServiceInfo(cn, 0) }.getOrNull() ?: continue
            tiles[id] = Hosted(id, cn, info).also { byToken[it.token] = it }
            added = true
        }
        for (id in tiles.keys - ids.toSet()) {
            tiles.remove(id)?.let {
                byToken.remove(it.token)
                it.unbind()
            }
        }
        if (added) {
            awakeUntil = SystemClock.uptimeMillis() + AWAKE_MS
            update()
        }
    }

    /** Whether the control center shows on [owner]'s page: the tiles listen while one does. */
    fun listening(
        owner: Any,
        on: Boolean,
    ) {
        val changed = if (on) shown.add(owner) else shown.remove(owner)
        if (changed) update()
    }

    /** [id]'s state, null if it isn't hosted or hasn't reported one yet (the page then opens it instead). */
    fun state(id: String): State? {
        val h = tiles[id] ?: return null
        if (!h.reported) return null
        val t = h.tile
        return State(t.label, t.subtitle, t.state)
    }

    /** A tap on [id], as SystemUI's CustomTile.handleClick: false if it isn't a hosted tile that can take one. */
    fun click(id: String): Boolean {
        val h = tiles[id] ?: return false
        if (!h.reported || h.tile.state == Tile.STATE_UNAVAILABLE) return false
        // The tile's own activity instead of the click, when it set one (Tile.setActivityLaunchForClick, API 34).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            h.tile.activityLaunchForClick?.let {
                launch(it)
                return true
            }
        }
        // The click needs it listening (AOSP drops a click on a tile that isn't); shut, it listens a moment for it.
        if (shown.isEmpty()) awakeUntil = SystemClock.uptimeMillis() + AWAKE_MS
        h.pendingClick = true
        update()
        return true
    }

    /** Every tile bound and listening, or not, as the pages want. */
    private fun update() {
        main.removeCallbacks(updater)
        val now = SystemClock.uptimeMillis()
        val want = shown.isNotEmpty() || now < awakeUntil
        for (h in tiles.values) h.sync(want)
        main.removeCallbacks(unbinder)
        if (!want) main.postDelayed(unbinder, UNBIND_MS)
        if (shown.isEmpty() && now < awakeUntil) main.postDelayed(updater, awakeUntil - now)
    }

    private val updater = Runnable { update() }
    private val unbinder =
        Runnable {
            if (shown.isNotEmpty() || SystemClock.uptimeMillis() < awakeUntil) return@Runnable
            for (h in tiles.values) h.unbind()
        }

    private fun changed() {
        main.removeCallbacks(fanOut)
        main.post(fanOut)
    }

    private val fanOut = Runnable { for (l in listeners.toList()) l.changed() }

    private fun collapse() = main.post { for (l in listeners.toList()) l.collapse() }

    /** A tile's activity (its PendingIntent), from PowOS in the background as far as Android knows: allowed to start. */
    private fun launch(pi: PendingIntent) {
        val opts = ActivityOptions.makeBasic()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            @Suppress("DEPRECATION")
            opts.setPendingIntentBackgroundActivityStartMode(
                if (Build.VERSION.SDK_INT >= 36) {
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                } else {
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                },
            )
        }
        runCatching { pi.send(app, 0, null, null, null, null, app?.let { dev.omalauncher.system.AppWindows.bundle(it, opts) } ?: opts.toBundle()) }
            .onFailure { Log.w(TAG, "can't start a tile's activity", it) }
        collapse()
    }

    /**
     * A tile's TileService.unlockAndRun: run once the phone is unlocked (onUnlockComplete). SystemUI brings its
     * bouncer up for it; here the panel goes and the tile waits for the user's unlock (ACTION_USER_PRESENT).
     */
    private fun unlockAndRun(h: Hosted) {
        if (!keyguard.isKeyguardLocked) {
            h.call { onUnlockComplete() }
            return
        }
        collapse()
        val ctx = app ?: return
        h.unlock?.let { runCatching { ctx.unregisterReceiver(it) } }
        h.unlock =
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context,
                    intent: Intent,
                ) {
                    runCatching { ctx.unregisterReceiver(this) }
                    h.unlock = null
                    h.call { onUnlockComplete() }
                }
            }.also { ctx.registerReceiver(it, IntentFilter(Intent.ACTION_USER_PRESENT)) }
    }

    /** IQSService.updateQsTile and the rest come from the tile's process: only its own token, from its own uid. */
    private fun caller(token: IBinder?): Hosted? {
        val h = token?.let(byToken::get) ?: return null.also { Log.w(TAG, "a call for no tile ($token)") }
        if (Binder.getCallingUid() != h.uid) throw SecurityException("uid ${Binder.getCallingUid()} isn't ${h.cn.flattenToShortString()}")
        return h
    }

    /** PowOS's tile host, as TileServices is SystemUI's: what a TileService calls back (EXTRA_SERVICE). */
    private val qs =
        object : IQSService.Stub() {
            override fun getTile(tile: IBinder?): Tile? = caller(tile)?.tile

            override fun updateQsTile(
                tile: Tile?,
                service: IBinder?,
            ) {
                val h = caller(service) ?: return
                h.tile = tile ?: return
                h.reported = true
                Log.d(TAG, "${h.cn.flattenToShortString()}: state ${tile.state} \"${tile.label}\" \"${tile.subtitle ?: ""}\"")
                changed()
            }

            // A system tile's status bar icon: the status bar is SystemUI's (see the class's HACK).
            override fun updateStatusIcon(
                tile: IBinder?,
                icon: Icon?,
                contentDescription: String?,
            ) {
                caller(tile)
            }

            override fun onShowDialog(tile: IBinder?) {
                caller(tile) ?: return
                collapse()
            }

            override fun onStartActivity(tile: IBinder?) {
                caller(tile) ?: return
                collapse()
            }

            override fun startActivity(
                tile: IBinder?,
                pendingIntent: PendingIntent?,
            ) {
                caller(tile) ?: return
                pendingIntent?.let { main.post { launch(it) } }
            }

            override fun isLocked(): Boolean = keyguard.isKeyguardLocked

            override fun isSecure(): Boolean = keyguard.isDeviceSecure && keyguard.isKeyguardLocked

            override fun startUnlockAndRun(tile: IBinder?) {
                val h = caller(tile) ?: return
                main.post { unlockAndRun(h) }
            }

            override fun onDialogHidden(tile: IBinder?) {
                caller(tile)
            }

            override fun onStartSuccessful(tile: IBinder?) {
                caller(tile) ?: return
                changed()
            }
        }

    /** One tile: its binding, its service, its last Tile. Main thread, but [tile] / [reported] (binder threads too). */
    private class Hosted(
        val id: String,
        val cn: ComponentName,
        info: ServiceInfo,
    ) : ServiceConnection {
        /** EXTRA_TOKEN: the tile's identity in its IQSService calls (TileLifecycleManager's mToken). */
        val token: IBinder = Binder()

        /** onClick's token (CustomTile's mToken, which SystemUI also makes the tile's dialog window token). */
        val clickToken: IBinder = Binder()
        val uid = info.applicationInfo.uid

        /** What the service has (getTile) and last sent (updateQsTile); SystemUI's starts as this, its service's label and icon. */
        @Volatile var tile: Tile = newTile(info)

        @Volatile var reported = false
        var unlock: BroadcastReceiver? = null
        private var bound = false
        private var service: IQSTileService? = null

        /** What the service was told: onStartListening (true) / onStopListening. */
        private var listening = false
        var pendingClick = false
        private var want = false

        fun sync(want: Boolean) {
            this.want = want
            if (want && !bound) bind()
            if (service == null) return
            if (want && !listening) {
                listening = true
                call { onStartListening() }
            }
            if (pendingClick) {
                pendingClick = false
                if (listening) call { onClick(clickToken) }
            }
            if (!want && listening) {
                listening = false
                call { onStopListening() }
            }
        }

        private fun bind() {
            val ctx = app ?: return
            // HACK: TileService.EXTRA_SERVICE ("service") and EXTRA_TOKEN ("token") are hidden names, and
            // Intent.putExtra(String, IBinder) a hidden method: the binders go in as a Bundle's (public), which
            // TileService.onBind reads back with getIBinderExtra. Real fix: none public - only SystemUI binds tiles.
            val extras =
                Bundle().apply {
                    putBinder("service", qs.asBinder())
                    putBinder("token", token)
                }
            val intent = Intent(TileService.ACTION_QS_TILE).setComponent(cn).putExtras(extras)
            val flags = Context.BIND_AUTO_CREATE or BIND_FOREGROUND_SERVICE_WHILE_AWAKE or Context.BIND_WAIVE_PRIORITY
            bound = runCatching { ctx.bindService(intent, this, flags) }
                .onFailure { Log.w(TAG, "can't bind ${cn.flattenToShortString()}", it) }
                .getOrDefault(false)
            if (!bound) {
                Log.w(TAG, "${cn.flattenToShortString()} didn't bind")
                runCatching { ctx.unbindService(this) }
            }
        }

        fun unbind() {
            if (!bound) return
            if (listening) {
                listening = false
                call { onStopListening() }
            }
            bound = false
            service = null
            runCatching { app?.unbindService(this) }
        }

        /** A one-way call to the tile; a dead one just isn't heard (the binding's death says so). */
        fun call(f: IQSTileService.() -> Unit) {
            val s = service ?: return
            runCatching { s.f() }.onFailure { Log.w(TAG, "${cn.flattenToShortString()}: ${it.message}") }
        }

        override fun onServiceConnected(
            name: ComponentName,
            binder: IBinder,
        ) {
            if (!bound) return
            service = IQSTileService.Stub.asInterface(binder)
            listening = false
            Log.d(TAG, "${cn.flattenToShortString()} bound")
            // TileLifecycleManager's order: added (once ever), listening, the click.
            val prefs = app!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val key = cn.flattenToString()
            if (!prefs.getBoolean(key, false)) {
                call { onTileAdded() }
                prefs.edit().putBoolean(key, true).apply()
            }
            sync(want)
        }

        override fun onServiceDisconnected(name: ComponentName) {
            // The process died; the system binds it again by itself (onServiceConnected).
            service = null
            listening = false
        }

        override fun onBindingDied(name: ComponentName) {
            Log.w(TAG, "${cn.flattenToShortString()}: binding died")
            unbind()
            main.postDelayed({ if (tiles[id] === this) update() }, REBIND_MS)
        }

        override fun onNullBinding(name: ComponentName) {
            // The service had no tile (its getTile came back null) or won't be bound: as SystemUI, let it go.
            Log.w(TAG, "${cn.flattenToShortString()}: no binder")
            unbind()
        }
    }

    /**
     * A fresh Tile: the service's label and icon, inactive, as SystemUI's CustomTile starts its own.
     *
     * HACK: Tile's constructors are hidden (@hide); it's built from a Parcel through its public CREATOR instead, in
     * Tile.writeToParcel's layout (android16: icon, pending intent, state, label, default label, subtitle, content and
     * state descriptions). Real fix: none public - an app never makes Tiles; a layout change shows as a garbled tile.
     */
    private fun newTile(info: ServiceInfo): Tile {
        val ctx = app!!
        val icon = info.iconResource.takeIf { it != 0 }?.let { Icon.createWithResource(info.packageName, it) }
        val p = Parcel.obtain()
        try {
            if (icon != null) {
                p.writeByte(1)
                icon.writeToParcel(p, 0)
            } else {
                p.writeByte(0)
            }
            p.writeByte(0)
            p.writeInt(Tile.STATE_INACTIVE)
            TextUtils.writeToParcel(null, p, 0)
            TextUtils.writeToParcel(info.loadLabel(ctx.packageManager), p, 0)
            repeat(3) { TextUtils.writeToParcel(null, p, 0) }
            p.setDataPosition(0)
            return Tile.CREATOR.createFromParcel(p)
        } finally {
            p.recycle()
        }
    }
}
