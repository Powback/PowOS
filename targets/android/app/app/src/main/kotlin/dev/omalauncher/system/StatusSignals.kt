package dev.omalauncher.system

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.MediaRouter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.service.notification.NotificationListenerService
import android.telephony.AccessNetworkConstants
import android.telephony.CarrierConfigManager
import android.telephony.NetworkRegistrationInfo
import android.telephony.ServiceState
import android.telephony.SignalStrength
import android.telephony.SubscriptionManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import android.util.Log
import dev.omalauncher.shell.ShellHost
import dev.omalauncher.system.StatusIcons.Cell
import dev.omalauncher.system.StatusIcons.Status
import dev.omalauncher.widgets.runtime.MediaListener
import dev.omalauncher.widgets.runtime.NotificationPicture
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

/**
 * The status bar's system icons (shell/ui/chrome.tsx StatusIcons), the stock set: each SIM's signal, network type,
 * roaming and data activity (TelephonyCallback per active subscription), Wi-Fi strength, airplane mode, hotspot,
 * Bluetooth (and a headset's battery), NFC, location in use, do not disturb, the ringer, the next alarm, data saver,
 * battery saver, casting and the notifications' icons. Every one is pushed by Android (callbacks, broadcasts), never
 * polled; [changed] gets the new [Status] only when what the bar shows differs (bars, not dBm).
 *
 * Permissions: READ_PHONE_STATE (runtime) for the subscriptions (a second SIM), the 5G/LTE+ override and the carrier's
 * "4G" naming. Without it the bar still shows the first SIM's bars, its service and its radio's own type (ServiceState
 * needs nothing) - [Status.limited]. Rooted, PowOS grants it to itself ([grant]); not rooted, home asks once
 * ([StatusPermission]). Bluetooth needs no runtime permission at targetSdk 28 (BLUETOOTH covers BLUETOOTH_CONNECT).
 */
class StatusSignals(
    private val context: Context,
    private val changed: (Status) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val executor = context.mainExecutor
    private val scope = MainScope()
    private val telephony = context.getSystemService(TelephonyManager::class.java)
    private val subscriptions = context.getSystemService(SubscriptionManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val wifiManager = context.getSystemService(WifiManager::class.java)
    private val audio = context.getSystemService(AudioManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notificationManager = context.getSystemService(NotificationManager::class.java)
    private val btAdapter: BluetoothAdapter? = runCatching { context.getSystemService(BluetoothManager::class.java)?.adapter }.getOrNull()
    private val nfcAdapter: NfcAdapter? = runCatching { NfcAdapter.getDefaultAdapter(context) }.getOrNull()
    private val router: MediaRouter? = runCatching { context.getSystemService(MediaRouter::class.java) }.getOrNull()
    private val recording = RecordingWatcher.shared(context)

    private var status = Status()
    private var sent: Status? = null

    /** Per subscription id: its slot and what its callbacks said last. */
    private class Sub(val id: Int, val slot: Int, val manager: TelephonyManager) {
        var bars: Int? = null
        var service = "in"
        var network = TelephonyManager.NETWORK_TYPE_UNKNOWN
        var override = TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE
        var roaming = false
        var activity: String? = null
        var connected = false
        var show4g = false
        var carrier: String? = null
        val callbacks = mutableListOf<TelephonyCallback>()
    }

    private val subs = linkedMapOf<Int, Sub>()

    /** Whether [subs]' callbacks were registered with the phone permission (the display override needs it). */
    private var listenedAllowed = false

    // --- pushes from Android

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                c: Context,
                intent: Intent,
            ) {
                when (intent.action) {
                    WIFI_AP_STATE_CHANGED -> update { copy(hotspot = intent.getIntExtra("wifi_state", 0) == WIFI_AP_STATE_ENABLED) }
                    BATTERY_LEVEL_CHANGED -> bluetoothBattery(intent)
                    SIM_STATE_CHANGED, CarrierConfigManager.ACTION_CARRIER_CONFIG_CHANGED -> resubscribe()
                    else -> refresh()
                }
            }
        }

    private val subsListener =
        object : SubscriptionManager.OnSubscriptionsChangedListener() {
            override fun onSubscriptionsChanged() = resubscribe()
        }

    private val wifiCallback =
        object : ConnectivityManager.NetworkCallback() {
            private val nets = HashMap<Network, NetworkCapabilities>()

            override fun onCapabilitiesChanged(
                n: Network,
                caps: NetworkCapabilities,
            ) {
                nets[n] = caps
                main.post { wifi(nets.values.toList()) }
            }

            override fun onLost(n: Network) {
                nets.remove(n)
                main.post { wifi(nets.values.toList()) }
            }
        }

    private val routerCallback =
        object : MediaRouter.SimpleCallback() {
            override fun onRouteSelected(
                r: MediaRouter,
                type: Int,
                info: MediaRouter.RouteInfo,
            ) = cast()

            override fun onRouteUnselected(
                r: MediaRouter,
                type: Int,
                info: MediaRouter.RouteInfo,
            ) = cast()

            override fun onRouteChanged(
                r: MediaRouter,
                info: MediaRouter.RouteInfo,
            ) = cast()
        }

    private val recordingChanged: () -> Unit = { update { copy(location = RecordingOps.Kind.LOCATION in recording.state().kinds) } }

    private fun phoneAllowed() = context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED

    /** Rooted and the phone permission missing: PowOS grants it to itself once (pm grant), then reads the SIMs again. */
    private fun grant() {
        if (phoneAllowed()) return
        Executors.newSingleThreadExecutor().execute {
            if (!andro.marchy.RootMode.enabled()) return@execute
            val r = andro.marchy.RootShell.run("pm grant ${context.packageName} ${Manifest.permission.READ_PHONE_STATE}")
            Log.i(TAG, "pm grant READ_PHONE_STATE: ${if (r.code == 0) "ok" else r.output}")
            if (r.code == 0) main.post { resubscribe() }
        }
    }

    // --- the plain states (each a cheap read, on its own broadcast)

    private fun refresh() {
        update {
            copy(
                airplane = runCatching { android.provider.Settings.Global.getInt(context.contentResolver, android.provider.Settings.Global.AIRPLANE_MODE_ON) == 1 }.getOrDefault(false),
                bluetooth = bluetoothState(),
                nfc = runCatching { nfcAdapter?.isEnabled == true }.getOrDefault(false),
                dnd = runCatching { notificationManager.currentInterruptionFilter > NotificationListenerService.INTERRUPTION_FILTER_ALL }.getOrDefault(false),
                ringer = StatusIcons.ringer(audio.ringerMode),
                alarm = runCatching { alarms.nextAlarmClock?.triggerTime }.getOrNull(),
                dataSaver = runCatching { connectivity.restrictBackgroundStatus != ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED }.getOrDefault(false),
                batterySaver = power.isPowerSaveMode,
            ).let { if (it.bluetooth != "connected") it.copy(bluetoothBattery = null) else it }
        }
    }

    @Suppress("MissingPermission")
    private fun bluetoothState(): String {
        val adapter = btAdapter ?: return "off"
        return runCatching {
            if (!adapter.isEnabled) return@runCatching "off"
            val profiles = listOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET, BluetoothProfile.HEARING_AID, BluetoothProfile.LE_AUDIO, BluetoothProfile.HID_DEVICE)
            if (profiles.any { p -> runCatching { adapter.getProfileConnectionState(p) == BluetoothProfile.STATE_CONNECTED }.getOrDefault(false) }) "connected" else "on"
        }.getOrDefault("off")
    }

    private fun bluetoothBattery(intent: Intent) {
        val level = intent.getIntExtra(EXTRA_BATTERY_LEVEL, -1)
        update { copy(bluetoothBattery = level.takeIf { it in 0..100 && bluetooth == "connected" }) }
    }

    private fun wifi(nets: List<NetworkCapabilities>) {
        val caps = nets.firstOrNull { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
        val bars = caps?.let { c -> runCatching { StatusIcons.wifiBars(wifiManager.calculateSignalLevel(c.signalStrength), wifiManager.maxSignalLevel) }.getOrDefault(4) }
        update { copy(wifi = bars, wifiInternet = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) != false) }
    }

    private fun cast() {
        val r = router ?: return
        // A wireless display (cast) selected: the live-video route isn't the phone's own (ROUTE_TYPE_REMOTE_DISPLAY,
        // what SystemUI's cast tile watches, is system API; a remote display is a live-video route too).
        val on =
            runCatching {
                val route = r.getSelectedRoute(MediaRouter.ROUTE_TYPE_LIVE_VIDEO)
                route != null && route != r.defaultRoute && route.playbackType == MediaRouter.RouteInfo.PLAYBACK_TYPE_REMOTE
            }.getOrDefault(false)
        update { copy(cast = on) }
    }

    /** One icon per app with a notification stock would show in its status bar (not the silent/minimised ones). */
    private fun notificationIcons() {
        val listener = MediaListener.connected
        val list = runCatching { listener?.activeNotifications?.toList() }.getOrNull().orEmpty()
        val ranking = runCatching { listener?.currentRanking }.getOrNull()
        val r = NotificationListenerService.Ranking()
        val icons =
            list.sortedByDescending { it.postTime }.filter { it.notification.smallIcon != null }.map { sbn ->
                StatusIcons.NotifIcon(sbn.key, sbn.packageName, NotificationPicture.smallUrl(ShellHost.ORIGIN, sbn.key, sbn.postTime / 1000))
            }
        val shown =
            StatusIcons.notifications(icons) { icon ->
                val ranked = ranking?.getRanking(icon.key, r) == true
                // Stock hides silent (importance <= LOW) notifications' icons from the status bar; ambient = minimised.
                !ranked || (!r.isAmbient && r.importance > NotificationManager.IMPORTANCE_LOW)
            }
        update { copy(notifications = shown) }
    }

    // --- the SIMs

    /** The subscriptions again (a SIM in or out, the phone permission granted, carrier config): callbacks per SIM. */
    @Suppress("MissingPermission")
    private fun resubscribe() {
        val allowed = phoneAllowed()
        val active =
            if (allowed) {
                runCatching { subscriptions?.activeSubscriptionInfoList.orEmpty().map { it.subscriptionId to it.simSlotIndex } }.getOrDefault(emptyList())
            } else {
                emptyList()
            }
        // Without the permission (or no active subscription known): the default subscription's manager, as slot 0.
        val wanted = active.ifEmpty { listOf(SubscriptionManager.getDefaultSubscriptionId() to 0) }
        if (wanted.map { it.first } != subs.keys.toList() || allowed != listenedAllowed) {
            listenedAllowed = allowed
            subs.values.forEach { s -> s.callbacks.forEach { runCatching { s.manager.unregisterTelephonyCallback(it) } } }
            subs.clear()
            for ((id, slot) in wanted) {
                val manager = if (id >= 0) telephony.createForSubscriptionId(id) else telephony
                val sub = Sub(id, slot, manager)
                subs[id] = sub
                listen(sub, allowed)
            }
        }
        for (s in subs.values) {
            s.show4g = allowed && runCatching { context.getSystemService(CarrierConfigManager::class.java)?.getConfigForSubId(s.id)?.getBoolean(CarrierConfigManager.KEY_SHOW_4G_FOR_LTE_DATA_ICON_BOOL) == true }.getOrDefault(false)
            s.carrier = runCatching { s.manager.networkOperatorName?.takeIf { it.isNotBlank() } }.getOrNull()
        }
        cells(allowed)
    }

    private fun listen(
        sub: Sub,
        allowed: Boolean,
    ) {
        val base = SubCallback(sub)
        if (runCatching { sub.manager.registerTelephonyCallback(executor, base) }.isSuccess) sub.callbacks += base
        // The 5G / LTE+ override needs READ_PHONE_STATE; without it the radio's own type stands.
        if (allowed) {
            val display = DisplayCallback(sub)
            if (runCatching { sub.manager.registerTelephonyCallback(executor, display) }.isSuccess) sub.callbacks += display
        }
    }

    private inner class SubCallback(private val sub: Sub) :
        TelephonyCallback(),
        TelephonyCallback.SignalStrengthsListener,
        TelephonyCallback.ServiceStateListener,
        TelephonyCallback.DataActivityListener,
        TelephonyCallback.DataConnectionStateListener {
        override fun onSignalStrengthsChanged(signal: SignalStrength) {
            sub.bars = StatusIcons.bars(signal.level)
            cells()
        }

        override fun onServiceStateChanged(state: ServiceState) {
            sub.service = StatusIcons.service(state.state)
            sub.roaming = state.roaming
            // The packet-switched, cellular registration's radio: needs no permission (getDataNetworkType does).
            sub.network =
                runCatching {
                    state.getNetworkRegistrationInfoList().firstOrNull {
                        it.domain and NetworkRegistrationInfo.DOMAIN_PS != 0 && it.transportType == AccessNetworkConstants.TRANSPORT_TYPE_WWAN
                    }?.accessNetworkTechnology
                }.getOrNull() ?: TelephonyManager.NETWORK_TYPE_UNKNOWN
            cells()
        }

        override fun onDataActivity(direction: Int) {
            sub.activity = StatusIcons.activity(direction)
            cells()
        }

        override fun onDataConnectionStateChanged(
            state: Int,
            networkType: Int,
        ) {
            sub.connected = state == TelephonyManager.DATA_CONNECTED
            cells()
        }
    }

    private inner class DisplayCallback(private val sub: Sub) : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
        override fun onDisplayInfoChanged(info: TelephonyDisplayInfo) {
            sub.override = info.overrideNetworkType
            if (info.networkType != TelephonyManager.NETWORK_TYPE_UNKNOWN) sub.network = info.networkType
            cells()
        }
    }

    private fun cells(allowed: Boolean = phoneAllowed()) {
        val slots = runCatching { telephony.activeModemCount }.getOrDefault(1).coerceAtLeast(1)
        val sims = (0 until slots).map { StatusIcons.sim(runCatching { telephony.getSimState(it) }.getOrDefault(TelephonyManager.SIM_STATE_UNKNOWN)) }
        val dataSub = SubscriptionManager.getDefaultDataSubscriptionId()
        val shown =
            StatusIcons.slots(sims).map { (slot, sim) ->
                val sub = subs.values.firstOrNull { it.slot == slot } ?: subs.values.firstOrNull()?.takeIf { slot == 0 && subs.size == 1 }
                if (sub == null || sim != "ready") return@map Cell(slot, sim)
                val data = sub.id == dataSub || subs.size == 1
                Cell(
                    slot = slot,
                    sim = sim,
                    bars = sub.bars,
                    service = sub.service,
                    type = if (data && sub.service == "in") StatusIcons.type(sub.network, sub.override, sub.show4g) else null,
                    roaming = sub.roaming,
                    activity = if (data && sub.connected) sub.activity else null,
                    data = data,
                    carrier = sub.carrier,
                )
            }
        update { copy(cells = shown, limited = !allowed) }
    }

    private inline fun update(f: Status.() -> Status) {
        status = status.f()
        if (status == sent) return
        // A burst (a SIM change brings several callbacks): one push for it.
        main.removeCallbacks(push)
        main.postDelayed(push, 50)
    }

    private val push =
        Runnable {
            if (status == sent) return@Runnable
            sent = status
            changed(status)
        }

    init {
        @Suppress("DEPRECATION")
        val filter =
            IntentFilter().apply {
                listOf(
                    Intent.ACTION_AIRPLANE_MODE_CHANGED, WIFI_AP_STATE_CHANGED, SIM_STATE_CHANGED,
                    CarrierConfigManager.ACTION_CARRIER_CONFIG_CHANGED,
                    BluetoothAdapter.ACTION_STATE_CHANGED, BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED, BATTERY_LEVEL_CHANGED,
                    NfcAdapter.ACTION_ADAPTER_STATE_CHANGED,
                    NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED, AudioManager.RINGER_MODE_CHANGED_ACTION,
                    AlarmManager.ACTION_NEXT_ALARM_CLOCK_CHANGED, ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED,
                    PowerManager.ACTION_POWER_SAVE_MODE_CHANGED,
                ).forEach(::addAction)
            }
        context.registerReceiver(receiver, filter)
        runCatching { connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), wifiCallback) }
        runCatching { router?.addCallback(MediaRouter.ROUTE_TYPE_LIVE_VIDEO, routerCallback) }
        runCatching { subscriptions?.addOnSubscriptionsChangedListener(executor, subsListener) }
        recording.watch(recordingChanged)
        scope.launch { MediaListener.changes.collect { notificationIcons() } }
        grant()
        refresh()
        resubscribe()
        cast()
        recordingChanged()
        live = this
    }

    fun now(): Status = status

    fun destroy() {
        if (live === this) live = null
        main.removeCallbacks(push)
        scope.cancel()
        recording.unwatch(recordingChanged)
        runCatching { context.unregisterReceiver(receiver) }
        runCatching { connectivity.unregisterNetworkCallback(wifiCallback) }
        runCatching { router?.removeCallback(routerCallback) }
        runCatching { subscriptions?.removeOnSubscriptionsChangedListener(subsListener) }
        subs.values.forEach { s -> s.callbacks.forEach { runCatching { s.manager.unregisterTelephonyCallback(it) } } }
        subs.clear()
    }

    companion object {
        private const val TAG = "PowosStatusIcons"

        // Broadcasts Android sends but names only in hidden/system API: their strings are the contract.
        /** The running instance (the status bar's), told when home's ask got the phone permission ([StatusPermission]). */
        @Volatile private var live: StatusSignals? = null

        fun permissionChanged() {
            live?.let { s -> s.main.post { s.resubscribe() } }
        }

        private const val WIFI_AP_STATE_CHANGED = "android.net.wifi.WIFI_AP_STATE_CHANGED"
        private const val WIFI_AP_STATE_ENABLED = 13
        private const val SIM_STATE_CHANGED = "android.intent.action.SIM_STATE_CHANGED"
        private const val BATTERY_LEVEL_CHANGED = "android.bluetooth.device.action.BATTERY_LEVEL_CHANGED"
        private const val EXTRA_BATTERY_LEVEL = "android.bluetooth.device.extra.BATTERY_LEVEL"
    }
}
