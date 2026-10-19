package dev.omalauncher.widgets.recon

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetProviderInfo
import android.content.Context
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews

/**
 * The launcher's own AppWidgetHost, used only for recon ([WidgetRecon]): it binds a provider's widget for the
 * seconds a capture takes and deletes it again. Not the home screen's host - our home screen draws OWL widgets.
 */
internal class ReconHost(
    context: Context,
) : AppWidgetHost(context, HOST_ID) {
    override fun onCreateView(
        context: Context,
        appWidgetId: Int,
        appWidget: AppWidgetProviderInfo?,
    ): AppWidgetHostView = ReconHostView(context)

    companion object {
        /** Any id unique within this app; the system keys our widget ids by (package, host id). */
        const val HOST_ID = 0x504f57
    }
}

/** An AppWidgetHostView that keeps every RemoteViews the provider sends, and when, for the recon's update log. */
internal class ReconHostView(
    context: Context,
) : AppWidgetHostView(context) {
    private val created = SystemClock.uptimeMillis()

    /** (ms since the view was created, the RemoteViews) for each update while [recording]. */
    val updates = ArrayList<Pair<Long, RemoteViews?>>()

    /** The newest RemoteViews from the provider. */
    var latest: RemoteViews? = null
        private set

    var lastUpdateAt = 0L
        private set

    /** Off while the recon draws previews into this view, which aren't the provider's updates. */
    var recording = true

    /** Whether Android had to show its "can't load widget" view: the RemoteViews failed to apply. */
    var failed = false
        private set

    override fun updateAppWidget(remoteViews: RemoteViews?) {
        if (recording) {
            lastUpdateAt = SystemClock.uptimeMillis()
            updates += (lastUpdateAt - created) to remoteViews
            if (remoteViews != null) latest = remoteViews
        }
        super.updateAppWidget(remoteViews)
    }

    override fun getErrorView(): View {
        failed = true
        return super.getErrorView()
    }
}
