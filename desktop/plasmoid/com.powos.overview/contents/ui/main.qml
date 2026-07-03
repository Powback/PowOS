// PowOS Overview plasmoid — renders `powos overview --json` + `powos services --json`
// as a desktop panel, with live GPU graphs (util + VRAM) on a fast 3s poll.
// Read-only. Falls back to sourcing ~/PowOS/lib when the installed powos
// predates `overview`.
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
    Layout.minimumHeight: Kirigami.Units.gridUnit * 18

    // ── state ────────────────────────────────────────────────────
    property var ov: ({})        // overview json (slow poll)
    property var svc: ({})       // services json (slow poll)
    property string err: ""

    // GPU time series (fast poll). Arrays of numbers, newest last.
    property int maxSamples: 100                 // 100 × 3s = 5 min window
    property var histUtil: []                    // %
    property var histVram: []                    // MiB used
    property real vramTotal: 0                   // MiB
    property real curUtil: 0
    property real curVram: 0
    property real curTemp: 0
    property real curPower: 0

    readonly property string dataCmd:
        "if powos overview --json >/dev/null 2>&1; then " +
        "  powos overview --json; echo __POWOS_SEP__; powos services --json; " +
        "else " +
        "  source \"$HOME/PowOS/lib/overview.sh\" 2>/dev/null; " +
        "  source \"$HOME/PowOS/lib/services.sh\" 2>/dev/null; " +
        "  ov_json; echo __POWOS_SEP__; svc_json; " +
        "fi"
    readonly property string gpuCmd:
        "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw " +
        "--format=csv,noheader,nounits 2>/dev/null | head -1"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            var out = (data.stdout || "").trim()
            if (source === root.gpuCmd) {
                // "34, 2101, 32607, 45, 87.32"
                var f = out.split(",").map(function(s){ return parseFloat(s.trim()) })
                if (f.length >= 5 && !isNaN(f[0])) {
                    root.curUtil = f[0]; root.curVram = f[1]; root.vramTotal = f[2]
                    root.curTemp = f[3]; root.curPower = f[4]
                    var u = root.histUtil.slice(); u.push(f[0])
                    var v = root.histVram.slice(); v.push(f[1])
                    if (u.length > root.maxSamples) u.shift()
                    if (v.length > root.maxSamples) v.shift()
                    root.histUtil = u; root.histVram = v
                    utilChart.requestPaint(); vramChart.requestPaint()
                }
                return
            }
            try {
                var parts = out.split("__POWOS_SEP__")
                root.ov  = JSON.parse(parts[0])
                root.svc = parts.length > 1 ? JSON.parse(parts[1]) : {}
                root.err = ""
            } catch (e) {
                root.err = "no data (is ~/PowOS or powos overview available?)"
            }
        }
    }
    Timer {   // slow: identity/containers/storage
        interval: 30000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: exec.connectSource(root.dataCmd)
    }
    Timer {   // fast: GPU series for the graphs
        interval: 3000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: exec.connectSource(root.gpuCmd)
    }

    function field(o, k, dflt) { return (o && o[k] !== undefined && o[k] !== null && o[k] !== "") ? o[k] : (dflt || "—") }
    function fmtGiB(mib) { return (mib / 1024).toFixed(1) }

    // Reusable sparkline painter: filled line chart over a fixed-max scale.
    component Spark: Canvas {
        id: cv
        property var series: []
        property real maxValue: 100
        property color lineColor: Kirigami.Theme.highlightColor
        Layout.fillWidth: true
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.6
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height, s = series
            // subtle baseline grid
            ctx.strokeStyle = Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            ctx.lineWidth = 1
            ctx.beginPath()
            for (var gy = 1; gy <= 3; gy++) { ctx.moveTo(0, h * gy / 4); ctx.lineTo(w, h * gy / 4) }
            ctx.stroke()
            if (!s || s.length < 2 || maxValue <= 0) return
            var n = root.maxSamples
            var step = w / (n - 1)
            var x0 = w - (s.length - 1) * step   // right-aligned: newest at right edge
            ctx.beginPath()
            for (var i = 0; i < s.length; i++) {
                var x = x0 + i * step
                var y = h - Math.min(1, s[i] / maxValue) * (h - 2) - 1
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
            ctx.strokeStyle = lineColor
            ctx.lineWidth = 1.5
            ctx.stroke()
            // fill under the line
            ctx.lineTo(x0 + (s.length - 1) * step, h)
            ctx.lineTo(x0, h)
            ctx.closePath()
            ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.25)
            ctx.fill()
        }
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

        ColumnLayout {
            id: content
            anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
            spacing: Kirigami.Units.smallSpacing

            // header
            RowLayout {
                Kirigami.Icon { source: "computer-symbolic"; Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium; Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium }
                Kirigami.Heading { level: 3; text: "PowOS"; Layout.fillWidth: true }
                PC3.Label { text: field(root.ov, "driver_channel"); color: Kirigami.Theme.positiveTextColor; font.bold: true }
            }
            PC3.Label {
                visible: root.err !== ""
                text: root.err; color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            PC3.Label {
                text: field(root.ov, "base_image") + "  (" + field(root.ov, "version") + ")"
                elide: Text.ElideMiddle; opacity: 0.8; font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.fillWidth: true
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // GPU identity line
            PC3.Label { text: field(root.ov, "gpu"); font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            PC3.Label {
                text: "driver " + field(root.ov, "driver") + " · CUDA " + field(root.ov, "cuda_runtime")
                      + " · toolkit " + field(root.ov, "cuda_toolkit")
                opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                elide: Text.ElideRight; Layout.fillWidth: true
            }

            // ── GPU graphs ───────────────────────────────────────
            RowLayout {
                PC3.Label { text: "GPU " + root.curUtil.toFixed(0) + "%"; font.bold: true }
                Item { Layout.fillWidth: true }
                PC3.Label {
                    text: root.curTemp.toFixed(0) + "°C · " + root.curPower.toFixed(0) + " W"
                    opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
            Spark { id: utilChart; series: root.histUtil; maxValue: 100; lineColor: Kirigami.Theme.highlightColor }

            RowLayout {
                PC3.Label { text: "VRAM " + fmtGiB(root.curVram) + " GiB"; font.bold: true }
                Item { Layout.fillWidth: true }
                PC3.Label {
                    text: root.vramTotal > 0 ? "of " + fmtGiB(root.vramTotal) + " GiB" : ""
                    opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }
            Spark { id: vramChart; series: root.histVram; maxValue: root.vramTotal > 0 ? root.vramTotal : 1; lineColor: Kirigami.Theme.positiveTextColor }

            Kirigami.Separator { Layout.fillWidth: true }

            // deployments + storage
            GridLayout {
                columns: 2; columnSpacing: Kirigami.Units.largeSpacing; Layout.fillWidth: true
                PC3.Label { text: "Deployments"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "deployments") + "  (incl. rollback)" }
                PC3.Label { text: "Storage"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "var_usage"); elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // containers
            PC3.Label {
                readonly property int n: root.svc && root.svc.containers ? root.svc.containers.length : 0
                text: "Containers (" + n + ")"; opacity: 0.6
            }
            Repeater {
                model: root.svc && root.svc.containers ? root.svc.containers : []
                delegate: RowLayout {
                    Layout.fillWidth: true
                    Rectangle {
                        width: Kirigami.Units.smallSpacing * 2; height: width; radius: width / 2
                        color: Kirigami.Theme.positiveTextColor
                    }
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
                text: "none running"; opacity: 0.5
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Item { Layout.fillHeight: true }
        }
    }
}
