package dev.omalauncher.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imeAnimationTarget
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.omalauncher.linux.LinuxState
import dev.omalauncher.widgets.WidgetEngine
import dev.omalauncher.widgets.WidgetSpec
import dev.omalauncher.widgets.lang.text
import dev.omalauncher.widgets.render.WidgetContent
import dev.omalauncher.widgets.render.WidgetScreen
import dev.omalauncher.widgets.runtime.WidgetInstance

@Composable
internal fun WidgetTile(
    spec: WidgetSpec,
    instance: WidgetInstance?,
    cells: Pair<Int, Int>?,
    focused: Boolean,
    modifier: Modifier,
    onTap: () -> Unit,
    needs: List<String>,
    install: WidgetEngine.Install?,
    onInstall: () -> Unit,
    onFix: (String) -> Unit,
    /** Where Linux stands, if the widget needs it and it isn't running: a placeholder keeps its cells. */
    waitsForLinux: LinuxState? = null,
    onInstallLinux: () -> Unit = {},
) {
    Box(
        modifier
            .tile(focused)
            .pointerInput(spec) { detectTapGestures(onTap = { onTap() }) },
    ) {
        if (waitsForLinux != null) {
            // While an installed Linux starts up the tile stays empty; it only offers an install when there's none.
            if (waitsForLinux != LinuxState.Checking && waitsForLinux != LinuxState.Installed) {
                LinuxPlaceholder(spec.name, installing = waitsForLinux is LinuxState.Installing, onInstallLinux)
            }
        } else if (instance != null && needs.isNotEmpty()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                BasicText(spec.name, style = Mono.copy(color = Palette.muted))
                BasicText("needs ${needs.joinToString(", ")}", style = Mono)
                when (install) {
                    WidgetEngine.Install.Running -> BasicText("installing…", style = Mono.copy(color = Palette.accent))
                    is WidgetEngine.Install.Failed -> {
                        BasicText(install.log.lines().lastOrNull { it.isNotBlank() }.orEmpty(), style = Mono.copy(color = Palette.red, fontSize = TextSize.Small), maxLines = 2)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            TileButton("retry", Palette.accent, onInstall)
                            TileButton("fix with agent", Palette.muted) { onFix(install.log) }
                        }
                    }
                    null -> TileButton("install", Palette.accent, onInstall)
                }
            }
        } else if (instance == null) {
            Column(Modifier.padding(12.dp)) {
                BasicText(spec.file.name, style = Mono.copy(color = Palette.red))
                BasicText(spec.error.orEmpty(), style = Mono.copy(color = Palette.muted, fontSize = TextSize.Small))
            }
        } else {
            WidgetContent(instance, Modifier.fillMaxSize(), cells)
        }
    }
}

/** A widget that runs Linux commands, before Linux is installed: its name and an offer to install. */
@Composable
private fun LinuxPlaceholder(
    name: String,
    installing: Boolean,
    onInstall: () -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        BasicText(name, style = Mono.copy(color = Palette.muted), maxLines = 1)
        Spacer(Modifier.weight(1f))
        BasicText("needs Linux", style = Mono.copy(color = Palette.accent))
        BasicText(
            "runs commands in the optional Arch Linux",
            style = Mono.copy(color = Palette.muted, fontSize = TextSize.Small),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        TileButton(if (installing) "installing…" else "install", Palette.accent, onInstall)
    }
}

@Composable
private fun TileButton(
    label: String,
    color: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
) {
    BasicText(
        label,
        Modifier
            .frame(1.dp, color, radius = 8.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        style = Mono.copy(color = color),
    )
}

/**
 * A widget's screen { }, full screen over home in an Omarchy window titled by its `title` or the widget's name. A
 * terminal's screen is the terminal alone, edge to edge, its [extraKeys] always below it, above the keyboard while it's
 * up and above the navigation bar when it's down - sized
 * once per keyboard change, from where the keyboard is going (its animation target): following its slide frame by
 * frame would resize (re-wrap) the terminal every frame, and waiting for it to settle lagged.
 */
@Composable
internal fun WidgetScreenPanel(
    spec: WidgetSpec,
    instance: WidgetInstance,
    onDismiss: () -> Unit,
    extraKeys: @Composable (Modifier) -> Unit = {},
) {
    val title = instance.program.screenTitle?.let { instance.eval(it, instance.root, "title").text() } ?: spec.name
    if (!instance.program.terminal) {
        OverlayPanel(title, onDismiss) {
            WidgetScreen(instance, Modifier.weight(1f).fillMaxWidth())
        }
        return
    }
    val density = LocalDensity.current
    @OptIn(ExperimentalLayoutApi::class)
    val target = WindowInsets.imeAnimationTarget.getBottom(density)
    val nav = WindowInsets.navigationBars.getBottom(density)
    var keysPx by remember { mutableIntStateOf(0) }
    // The extra keys sit above the keyboard, or above the navigation bar when it's down.
    val clear = with(density) { (maxOf(target, nav) + keysPx).toDp() }
    // Edge to edge, no title: it's plainly a terminal, and every column counts. Back closes it (the launcher's
    // back handler), as any widget screen.
    Box(Modifier.fillMaxSize().background(Palette.overlay)) {
        Box(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.statusBars.union(WindowInsets.displayCutout).only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
                .padding(bottom = clear)
                .background(Palette.background)
                // Its touches stay its own: none reach home behind it.
                .pointerInput(Unit) { detectTapGestures { } },
        ) {
            WidgetScreen(instance, Modifier.fillMaxSize())
        }
        extraKeys(
            Modifier
                .align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars).only(WindowInsetsSides.Bottom))
                .onSizeChanged { keysPx = it.height },
        )
    }
}
