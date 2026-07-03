// PowOS Overview plasmoid — `powos overview/services --json` as a desktop panel,
// with live graphs (GPU util, VRAM, CPU, RAM, network) on a single fast 3s poll.
// CPU% and net rates are computed from /proc deltas here in QML — one cheap
// process spawn per tick total. Read-only. Falls back to sourcing ~/PowOS/lib
// when the installed powos predates `overview`.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root
    preferredRepresentation: fullRepresentation
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.minimumHeight: Kirigami.Units.gridUnit * 26

    // ── state ────────────────────────────────────────────────────
    property var ov: ({})
    property var svc: ({})
    property string err: ""

    property int maxSamples: 100                 // 100 × 3s = 5 min window
    // GPU
    property var histUtil: [];  property var histVram: []
    property real vramTotal: 0
    property real curUtil: 0;   property real curVram: 0
    property real curTemp: 0;   property real curPower: 0
    // CPU
    property var histCpu: []
    property real curCpu: 0;    property real curCpuTemp: 0
    property real prevCpuTotal: 0; property real prevCpuIdle: 0
    // RAM
    property var histRam: []
    property real ramTotal: 0;  property real curRam: 0        // GiB
    // NET (MB/s)
    property var histRx: [];    property var histTx: []
    property real curRx: 0;     property real curTx: 0
    property real prevRxB: -1;  property real prevTxB: -1
    property double prevNetMs: 0
    // STORAGE (/var)
    property real diskUsed: 0;  property real diskTotal: 0     // GiB

    readonly property string dataCmd:
        "if powos overview --json >/dev/null 2>&1; then " +
        "  powos overview --json; echo __POWOS_SEP__; powos services --json; " +
        "else " +
        "  source \"$HOME/PowOS/lib/overview.sh\" 2>/dev/null; " +
        "  source \"$HOME/PowOS/lib/services.sh\" 2>/dev/null; " +
        "  ov_json; echo __POWOS_SEP__; svc_json; " +
        "fi"
    // One process per tick; 5 fixed lines: cpu-stat | mem | net | gpu-csv | cpu-temp
    readonly property string fastCmd:
        "head -1 /proc/stat; " +
        "awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo; " +
        "awk 'NR>2 {gsub(/:/,\" \"); rx+=$2; tx+=$10} END{print rx, tx}' /proc/net/dev; " +
        "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 || echo na; " +
        "sensors 2>/dev/null | awk '/^Tctl:/{gsub(/[+°C]/,\"\"); print $2; exit}' || echo 0; " +
        "df -k --output=used,size /var 2>/dev/null | tail -1"

    function pushHist(arr, v) { var a = arr.slice(); a.push(v); if (a.length > maxSamples) a.shift(); return a }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            var out = (data.stdout || "")
            if (source === root.fastCmd) { root.parseFast(out); return }
            try {
                var parts = out.trim().split("__POWOS_SEP__")
                root.ov  = JSON.parse(parts[0])
                root.svc = parts.length > 1 ? JSON.parse(parts[1]) : {}
                root.err = ""
            } catch (e) { root.err = "no data (is ~/PowOS or powos overview available?)" }
        }
    }
    Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.dataCmd) }
    Timer { interval: 3000;  running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.fastCmd) }

    // NOTE: never reference chart ids here — they live inside fullRepresentation
    // (separate component scope) and are NOT visible from the root. That was the
    // "utilChart is not defined" bug that kept graphs empty. Charts repaint
    // themselves via onSeriesChanged instead.
    function parseFast(out) {
        var L = out.split("\n")
        if (L.length < 5) return
        // 1) CPU: "cpu user nice system idle iowait irq softirq steal ..."
        var c = L[0].trim().split(/\s+/).slice(1).map(Number)
        if (c.length >= 5) {
            var total = c.reduce(function(a,b){ return a+b }, 0)
            var idle = c[3] + (c[4] || 0)
            if (prevCpuTotal > 0 && total > prevCpuTotal) {
                var dT = total - prevCpuTotal, dI = idle - prevCpuIdle
                curCpu = Math.max(0, Math.min(100, 100 * (dT - dI) / dT))
                histCpu = pushHist(histCpu, curCpu)
            }
            prevCpuTotal = total; prevCpuIdle = idle
        }
        // 2) MEM: "totalKB availKB"
        var m = L[1].trim().split(/\s+/).map(Number)
        if (m.length >= 2 && m[0] > 0) {
            ramTotal = m[0] / 1048576
            curRam = (m[0] - m[1]) / 1048576
            histRam = pushHist(histRam, curRam)
        }
        // 3) NET: "rxBytes txBytes" (cumulative)
        var n = L[2].trim().split(/\s+/).map(Number)
        if (n.length >= 2) {
            var now = Date.now()
            if (prevRxB >= 0 && now > prevNetMs) {
                var dt = (now - prevNetMs) / 1000
                curRx = Math.max(0, (n[0] - prevRxB) / dt / 1048576)   // MB/s
                curTx = Math.max(0, (n[1] - prevTxB) / dt / 1048576)
                histRx = pushHist(histRx, curRx)
                histTx = pushHist(histTx, curTx)
            }
            prevRxB = n[0]; prevTxB = n[1]; prevNetMs = now
        }
        // 4) GPU csv
        var g = L[3].trim()
        if (g !== "na" && g.indexOf(",") > 0) {
            var f = g.split(",").map(function(s){ return parseFloat(s.trim()) })
            if (f.length >= 5 && !isNaN(f[0])) {
                curUtil = f[0]; curVram = f[1]; vramTotal = f[2]; curTemp = f[3]; curPower = f[4]
                histUtil = pushHist(histUtil, f[0])
                histVram = pushHist(histVram, f[1])
            }
        }
        // 5) CPU temp (Tctl)
        var t = parseFloat(L[4]); if (!isNaN(t) && t > 0) curCpuTemp = t
        // 6) STORAGE: "usedKB totalKB" (df /var)
        if (L.length >= 6) {
            var d = L[5].trim().split(/\s+/).map(Number)
            if (d.length >= 2 && d[1] > 0) { diskUsed = d[0] / 1048576; diskTotal = d[1] / 1048576 }
        }
    }

    function field(o, k, dflt) { return (o && o[k] !== undefined && o[k] !== null && o[k] !== "") ? o[k] : (dflt || "—") }
    function fmtGiB(mib) { return (mib / 1024).toFixed(1) }
    function fmtRate(mbs) { return mbs >= 1 ? mbs.toFixed(1) + " MB/s" : (mbs * 1024).toFixed(0) + " KB/s" }

    // Sparkline painter; optional second series. maxValue<=0 → autoscale.
    component Spark: Canvas {
        id: cv
        property var series: []
        property var series2: []
        property real maxValue: 100
        property color lineColor: Kirigami.Theme.highlightColor
        property color lineColor2: Kirigami.Theme.neutralTextColor
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.4
        // Self-repainting: data arrives as new arrays on root properties, so
        // these fire on every sample. (Charts are NOT reachable by id from the
        // root parser — different component scope.)
        onSeriesChanged: requestPaint()
        onSeries2Changed: requestPaint()
        onMaxValueChanged: requestPaint()
        onWidthChanged: requestPaint()
        Component.onCompleted: requestPaint()
        function drawSeries(ctx, s, col, mx, w, h) {
            if (!s || s.length < 2) return
            var step = w / (root.maxSamples - 1)
            var x0 = w - (s.length - 1) * step
            ctx.beginPath()
            for (var i = 0; i < s.length; i++) {
                var x = x0 + i * step
                var y = h - Math.min(1, s[i] / mx) * (h - 2) - 1
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
            ctx.strokeStyle = col; ctx.lineWidth = 1.5; ctx.stroke()
            ctx.lineTo(x0 + (s.length - 1) * step, h); ctx.lineTo(x0, h); ctx.closePath()
            ctx.fillStyle = Qt.rgba(col.r, col.g, col.b, 0.22); ctx.fill()
        }
        onPaint: {
            var ctx = getContext("2d"); ctx.reset()
            var w = width, h = height
            ctx.strokeStyle = Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            ctx.lineWidth = 1; ctx.beginPath()
            for (var gy = 1; gy <= 3; gy++) { ctx.moveTo(0, h * gy / 4); ctx.lineTo(w, h * gy / 4) }
            ctx.stroke()
            var mx = maxValue
            if (mx <= 0) {   // autoscale over both series
                mx = 0.001
                var all = (series || []).concat(series2 || [])
                for (var i = 0; i < all.length; i++) if (all[i] > mx) mx = all[i]
            }
            drawSeries(ctx, series, lineColor, mx, w, h)
            drawSeries(ctx, series2, lineColor2, mx, w, h)
        }
    }
    component GraphHeader: RowLayout {
        property alias label: l.text
        property alias value: r.text
        Layout.fillWidth: true
        PC3.Label { id: l; font.bold: true }
        Item { Layout.fillWidth: true }
        PC3.Label { id: r; opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize }
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

        ColumnLayout {
            id: content
            anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Kirigami.Icon { source: "computer-symbolic"; Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium; Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium }
                Kirigami.Heading { level: 3; text: "PowOS"; Layout.fillWidth: true }
                PC3.Label { text: field(root.ov, "driver_channel"); color: Kirigami.Theme.positiveTextColor; font.bold: true }
            }
            PC3.Label { visible: root.err !== ""; text: root.err; color: Kirigami.Theme.negativeTextColor; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            PC3.Label {
                text: field(root.ov, "base_image") + "  (" + field(root.ov, "version") + ")"
                elide: Text.ElideMiddle; opacity: 0.8; font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.fillWidth: true
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // GPU
            PC3.Label { text: field(root.ov, "gpu"); font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            PC3.Label {
                text: "driver " + field(root.ov, "driver") + " · CUDA " + field(root.ov, "cuda_runtime") + " · toolkit " + field(root.ov, "cuda_toolkit")
                opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            GraphHeader { label: "GPU " + root.curUtil.toFixed(0) + "%"; value: root.curTemp.toFixed(0) + "°C · " + root.curPower.toFixed(0) + " W" }
            Spark { id: utilChart; series: root.histUtil; maxValue: 100 }
            GraphHeader { label: "VRAM " + fmtGiB(root.curVram) + " GiB"; value: root.vramTotal > 0 ? "of " + fmtGiB(root.vramTotal) + " GiB" : "" }
            Spark { id: vramChart; series: root.histVram; maxValue: root.vramTotal > 0 ? root.vramTotal : 1; lineColor: Kirigami.Theme.positiveTextColor }

            Kirigami.Separator { Layout.fillWidth: true }

            // CPU / RAM / NET
            GraphHeader { label: "CPU " + root.curCpu.toFixed(0) + "%"; value: root.curCpuTemp > 0 ? root.curCpuTemp.toFixed(0) + "°C" : "" }
            Spark { id: cpuChart; series: root.histCpu; maxValue: 100; lineColor: Kirigami.Theme.textColor }
            GraphHeader { label: "RAM " + root.curRam.toFixed(1) + " GiB"; value: root.ramTotal > 0 ? "of " + root.ramTotal.toFixed(0) + " GiB" : "" }
            Spark { id: ramChart; series: root.histRam; maxValue: root.ramTotal > 0 ? root.ramTotal : 1; lineColor: Kirigami.Theme.positiveTextColor }
            GraphHeader { label: "NET ↓ " + fmtRate(root.curRx); value: "↑ " + fmtRate(root.curTx) }
            Spark { id: netChart; series: root.histRx; series2: root.histTx; maxValue: 0
                    lineColor: Kirigami.Theme.highlightColor; lineColor2: Kirigami.Theme.neutralTextColor }

            Kirigami.Separator { Layout.fillWidth: true }

            RowLayout {
                PC3.Label { text: "Deployments"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "deployments") + "  (incl. rollback)"; Layout.fillWidth: true }
            }
            GraphHeader {
                label: "Storage " + root.diskUsed.toFixed(0) + " GiB"
                value: root.diskTotal > 0 ? "of " + (root.diskTotal / 1024).toFixed(1) + " TiB" : ""
            }
            // usage bar for /var (the writable everything-partition)
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.smallSpacing * 2
                radius: height / 2
                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: root.diskTotal > 0 ? Math.max(parent.height, parent.width * root.diskUsed / root.diskTotal) : 0
                    radius: parent.radius
                    color: (root.diskTotal > 0 && root.diskUsed / root.diskTotal > 0.9)
                           ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            PC3.Label {
                readonly property int n: root.svc && root.svc.containers ? root.svc.containers.length : 0
                text: "Containers (" + n + ")"; opacity: 0.6
            }
            Repeater {
                model: root.svc && root.svc.containers ? root.svc.containers : []
                delegate: RowLayout {
                    Layout.fillWidth: true
                    Rectangle { width: Kirigami.Units.smallSpacing * 2; height: width; radius: width / 2; color: Kirigami.Theme.positiveTextColor }
                    PC3.Label { text: modelData.name; font.bold: true }
                    PC3.Label {
                        text: (modelData.gpu ? "gpu · " : "") + modelData.status
                        opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
            }
            PC3.Label {
                visible: !root.svc || !root.svc.containers || root.svc.containers.length === 0
                text: "none running"; opacity: 0.5; font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Item { Layout.fillHeight: true }
        }
    }
}
