// PowOS Monitor plasmoid — live graphs only: GPU util, VRAM, temps, power,
// CPU, RAM, network. One process spawn per 3s tick; CPU% and net rates are
// computed from /proc deltas in QML. The identity/containers panel is the
// separate "PowOS Overview" widget.
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
    Layout.minimumHeight: Kirigami.Units.gridUnit * 10

    property int maxSamples: 100                 // 100 × 3s = 5 min window
    // GPU
    property var histUtil: [];  property var histVram: []
    property real vramTotal: 0
    property real curUtil: 0;   property real curVram: 0
    property real curTemp: 0;   property real curPower: 0
    property var histGpuTemp: []; property var histPower: []
    // CPU
    property var histCpu: [];   property var histCpuTempS: []
    property real curCpu: 0;    property real curCpuTemp: 0
    property real curFreq: 0;   property real load1: 0
    property real prevCpuTotal: 0; property real prevCpuIdle: 0
    // RAM
    property var histRam: []
    property real ramTotal: 0;  property real curRam: 0        // GiB
    // NET (MB/s)
    property var histRx: [];    property var histTx: []
    property real curRx: 0;     property real curTx: 0
    property real prevRxB: -1;  property real prevTxB: -1
    property double prevNetMs: 0
    // DISK I/O (MB/s, whole-disk totals from /proc/diskstats sectors × 512)
    property var histDr: [];    property var histDw: []
    property real curDr: 0;     property real curDw: 0
    property real prevDrS: -1;  property real prevDwS: -1
    property double prevDiskMs: 0

    // Top offenders (10s poll): [{name,val}] each
    property var topCpu: [];  property var topMem: [];  property var topIo: []
    property var topNet: []   // by connection count (bandwidth needs root)

    // 7 fixed lines: cpu-stat | mem | net | gpu-csv | Tctl | freq | load1
    readonly property string fastCmd:
        "head -1 /proc/stat; " +
        "awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo; " +
        "awk 'NR>2 {gsub(/:/,\" \"); rx+=$2; tx+=$10} END{print rx, tx}' /proc/net/dev; " +
        "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 || echo na; " +
        "sensors 2>/dev/null | awk '/^Tctl:/{gsub(/[+°C]/,\"\"); print $2; exit}' || echo 0; " +
        "awk '/^cpu MHz/{s+=$4; n++} END{if(n) printf \"%.2f\\n\", s/n/1000; else print 0}' /proc/cpuinfo; " +
        "cut -d' ' -f1 /proc/loadavg; " +
        "awk '$3 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+)$/ {r+=$6; w+=$10} END{print r, w}' /proc/diskstats"
    // Top offenders per resource. Disk sampler uses grep -s (gawk fatals on
    // unreadable/vanished /proc files); per-process io = own processes only.
    readonly property string mediumCmd:
        "ps -eo comm,%cpu --sort=-%cpu --no-headers | head -3; " +
        "echo __M__; " +
        "ps -eo comm,%mem --sort=-%mem --no-headers | head -3; " +
        "echo __D__; " +
        "T1=$(mktemp); T2=$(mktemp); " +
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T1; " +
        "sleep 1; " +
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T2; " +
        "awk 'NR==FNR{a[$1]=$2; next} ($1 in a) && ($2>a[$1]) {d=$2-a[$1]; split($1,p,\"/\"); pid=p[3]; cf=\"/proc/\"pid\"/comm\"; c=\"?\"; if((getline c < cf)>0) close(cf); print d, c}' $T1 $T2 | sort -rn | head -3 | awk '{printf \"%s %.2f\\n\", $2, $1/1048576}'; " +
        "rm -f $T1 $T2; " +
        // Per-process net BANDWIDTH needs root (nethogs); unprivileged proxy is
        // socket ownership — who's actively talking, by connection count.
        "echo __N__; " +
        "ss -tunp 2>/dev/null | grep -oP 'users:\\(\\(\"\\K[^\"]+' | sort | uniq -c | sort -rn | head -3 | awk '{print $2, $1}'"

    function pushHist(arr, v) { var a = arr.slice(); a.push(v); if (a.length > maxSamples) a.shift(); return a }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            if (source === root.mediumCmd) root.parseMedium(data.stdout || "")
            else root.parseFast(data.stdout || "")
        }
    }
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.fastCmd) }
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.mediumCmd) }

    function parseOffenders(txt, unit) {
        var out = []
        txt.trim().split("\n").forEach(function(ln) {
            var f = ln.trim().split(/\s+/)
            if (f.length >= 2) out.push({ name: f.slice(0, f.length - 1).join(" "),
                                          val: (parseFloat(f[f.length - 1]) || 0).toFixed(1) + unit })
        })
        return out
    }
    function parseMedium(out) {
        var seg = out.split("__M__")
        topCpu = parseOffenders(seg[0], "%")
        if (seg.length < 2) return
        var rest = seg[1].split("__D__")
        topMem = parseOffenders(rest[0], "%")
        if (rest.length < 2) return
        var tail = rest[1].split("__N__")
        topIo = parseOffenders(tail[0], " MB/s")
        topNet = tail.length > 1 ? parseOffenders(tail[1], " conns") : []
    }

    // Charts repaint themselves via onSeriesChanged — never reference chart ids
    // from here (fullRepresentation is a separate component scope).
    function parseFast(out) {
        var L = out.split("\n")
        if (L.length < 7) return
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
        var m = L[1].trim().split(/\s+/).map(Number)
        if (m.length >= 2 && m[0] > 0) {
            ramTotal = m[0] / 1048576
            curRam = (m[0] - m[1]) / 1048576
            histRam = pushHist(histRam, curRam)
        }
        var n = L[2].trim().split(/\s+/).map(Number)
        if (n.length >= 2) {
            var now = Date.now()
            if (prevRxB >= 0 && now > prevNetMs) {
                var dt = (now - prevNetMs) / 1000
                curRx = Math.max(0, (n[0] - prevRxB) / dt / 1048576)
                curTx = Math.max(0, (n[1] - prevTxB) / dt / 1048576)
                histRx = pushHist(histRx, curRx)
                histTx = pushHist(histTx, curTx)
            }
            prevRxB = n[0]; prevTxB = n[1]; prevNetMs = now
        }
        var g = L[3].trim()
        if (g !== "na" && g.indexOf(",") > 0) {
            var f = g.split(",").map(function(s){ return parseFloat(s.trim()) })
            if (f.length >= 5 && !isNaN(f[0])) {
                curUtil = f[0]; curVram = f[1]; vramTotal = f[2]; curTemp = f[3]; curPower = f[4]
                histUtil = pushHist(histUtil, f[0])
                histVram = pushHist(histVram, f[1])
                histGpuTemp = pushHist(histGpuTemp, f[3])
                histPower = pushHist(histPower, f[4])
            }
        }
        var t = parseFloat(L[4]); if (!isNaN(t) && t > 0) { curCpuTemp = t; histCpuTempS = pushHist(histCpuTempS, t) }
        var fq = parseFloat(L[5]); if (!isNaN(fq)) curFreq = fq
        var ld = parseFloat(L[6]); if (!isNaN(ld)) load1 = ld
        // 8) DISK: cumulative sectors read/written across whole disks
        if (L.length >= 8) {
            var dk = L[7].trim().split(/\s+/).map(Number)
            if (dk.length >= 2) {
                var dnow = Date.now()
                if (prevDrS >= 0 && dnow > prevDiskMs) {
                    var ddt = (dnow - prevDiskMs) / 1000
                    curDr = Math.max(0, (dk[0] - prevDrS) * 512 / ddt / 1048576)   // MB/s
                    curDw = Math.max(0, (dk[1] - prevDwS) * 512 / ddt / 1048576)
                    histDr = pushHist(histDr, curDr)
                    histDw = pushHist(histDw, curDw)
                }
                prevDrS = dk[0]; prevDwS = dk[1]; prevDiskMs = dnow
            }
        }
    }

    function fmtGiB(mib) { return (mib / 1024).toFixed(1) }
    function fmtRate(mbs) { return mbs >= 1 ? mbs.toFixed(1) + " MB/s" : (mbs * 1024).toFixed(0) + " KB/s" }

    component Spark: Canvas {
        id: cv
        property var series: []
        property var series2: []
        property real maxValue: 100
        property color lineColor: Kirigami.Theme.highlightColor
        property color lineColor2: Kirigami.Theme.neutralTextColor
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 3.8
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
            if (mx <= 0) {
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
    // one-line "worst offenders" strip under a graph: "name val · name val · …"
    component Offenders: PC3.Label {
        property var list: []
        visible: list.length > 0
        text: "› " + list.map(function(p){ return p.name + " " + p.val }).join("  ·  ")
        opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize
        elide: Text.ElideRight
        Layout.fillWidth: true
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

        ColumnLayout {
            id: content
            anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Kirigami.Icon { source: "office-chart-line-stacked"; Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium; Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium }
                Kirigami.Heading { level: 3; text: "Monitor"; Layout.fillWidth: true }
            }

            GraphHeader { label: "GPU " + root.curUtil.toFixed(0) + "%"; value: root.curTemp.toFixed(0) + "°C · " + root.curPower.toFixed(0) + " W" }
            Spark { series: root.histUtil; maxValue: 100 }
            GraphHeader { label: "VRAM " + fmtGiB(root.curVram) + " GiB"; value: root.vramTotal > 0 ? "of " + fmtGiB(root.vramTotal) + " GiB" : "" }
            Spark { series: root.histVram; maxValue: root.vramTotal > 0 ? root.vramTotal : 1; lineColor: Kirigami.Theme.positiveTextColor }
            GraphHeader { label: "TEMP gpu " + root.curTemp.toFixed(0) + "°C"; value: "cpu " + root.curCpuTemp.toFixed(0) + "°C" }
            Spark { series: root.histGpuTemp; series2: root.histCpuTempS; maxValue: 100
                    lineColor: Kirigami.Theme.negativeTextColor; lineColor2: Kirigami.Theme.neutralTextColor }
            GraphHeader { label: "POWER " + root.curPower.toFixed(0) + " W"; value: "gpu board draw" }
            Spark { series: root.histPower; maxValue: 0 }

            Kirigami.Separator { Layout.fillWidth: true }

            GraphHeader {
                label: "CPU " + root.curCpu.toFixed(0) + "%" + (root.curFreq > 0 ? " · " + root.curFreq.toFixed(2) + " GHz" : "")
                value: "load " + root.load1.toFixed(2) + (root.curCpuTemp > 0 ? " · " + root.curCpuTemp.toFixed(0) + "°C" : "")
            }
            Spark { series: root.histCpu; maxValue: 100; lineColor: Kirigami.Theme.textColor }
            Offenders { list: root.topCpu }
            GraphHeader { label: "RAM " + root.curRam.toFixed(1) + " GiB"; value: root.ramTotal > 0 ? "of " + root.ramTotal.toFixed(0) + " GiB" : "" }
            Spark { series: root.histRam; maxValue: root.ramTotal > 0 ? root.ramTotal : 1; lineColor: Kirigami.Theme.positiveTextColor }
            Offenders { list: root.topMem }
            GraphHeader { label: "NET ↓ " + fmtRate(root.curRx); value: "↑ " + fmtRate(root.curTx) }
            Spark { series: root.histRx; series2: root.histTx; maxValue: 0
                    lineColor: Kirigami.Theme.highlightColor; lineColor2: Kirigami.Theme.neutralTextColor }
            Offenders { list: root.topNet }
            GraphHeader { label: "DISK r " + fmtRate(root.curDr); value: "w " + fmtRate(root.curDw) }
            Spark { series: root.histDr; series2: root.histDw; maxValue: 0
                    lineColor: Kirigami.Theme.positiveTextColor; lineColor2: Kirigami.Theme.negativeTextColor }
            Offenders { list: root.topIo }
            Item { Layout.fillHeight: true }
        }
    }
}
