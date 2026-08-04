// PowOS Overview plasmoid — identity + inventory panel: base image/channel,
// GPU/driver/CUDA, deployments, storage bar, and a "what's eating the box"
// process table (cpu / mem / disk I/O, click a column to sort by it).
// Containers deliberately live in the separate "PowOS Containers" widget;
// the live graphs live in "PowOS Monitor".
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
    Layout.minimumHeight: Kirigami.Units.gridUnit * 8

    // ── state ────────────────────────────────────────────────────
    property var ov: ({})
    property string err: ""
    property real diskUsed: 0;  property real diskTotal: 0     // GiB
    property var topProcs: []                                   // [{name,cpu,mem,io,count}] grouped by name
    property int procCount: 0                                   // total processes (before grouping)

    // which column the table is sorted by: "cpu" | "mem" | "io"
    property string sortKey: "cpu"

    readonly property var sortedProcs: {
        var k = root.sortKey
        var l = root.topProcs.slice()
        l.sort(function (a, b) { return (b[k] || 0) - (a[k] || 0) })
        return l
    }

    readonly property string dataCmd:
        "if powos overview --json >/dev/null 2>&1; then " +
        "  powos overview --json; " +
        "else " +
        "  source \"$HOME/PowOS/lib/overview.sh\" 2>/dev/null; " +
        "  ov_json; " +
        "fi"
    // disk | __PS__ | ALL processes | __IO__ | per-name disk I/O MB/s
    // Per-process I/O (/proc/PID/io) is only readable for YOUR processes without
    // root — that covers apps + rootless containers, not system daemons. 1s sample.
    readonly property string mediumCmd:
        "df -k --output=used,size /var 2>/dev/null | tail -1; " +
        "echo __PS__; " +
        "ps -eo comm,%cpu,%mem --sort=-%cpu --no-headers; " +
        "echo __IO__; " +
        "T1=$(mktemp); T2=$(mktemp); " +
        // grep -s (NOT awk on the files directly): gawk FATALS on the first
        // unreadable/vanished /proc file (root-owned pids, exit races), which
        // silently produced nothing. grep -s skips them and never aborts.
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T1; " +
        "sleep 1; " +
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T2; " +
        // aggregate the delta by process NAME (same 15-char comm key `ps` uses)
        // so it merges straight into the grouped process rows.
        "awk 'NR==FNR{a[$1]=$2; next} ($1 in a) && ($2>a[$1]) {d=$2-a[$1]; split($1,p,\"/\"); pid=p[3]; cf=\"/proc/\"pid\"/comm\"; c=\"?\"; if((getline c < cf)>0) close(cf); s[c]+=d} END{for(n in s) printf \"%s %.2f\\n\", n, s[n]/1048576}' $T1 $T2; " +
        "rm -f $T1 $T2"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            var out = (data.stdout || "")
            if (source === root.mediumCmd) { root.parseMedium(out); return }
            try {
                root.ov  = JSON.parse(out.trim())
                root.err = ""
            } catch (e) { root.err = "no data (is ~/PowOS or powos overview available?)" }
        }
    }
    Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.dataCmd) }
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: exec.connectSource(root.mediumCmd) }

    function parseMedium(out) {
        var seg = out.split("__PS__")
        // disk: "usedKB totalKB"
        var d = seg[0].trim().split(/\s+/).map(Number)
        if (d.length >= 2 && d[1] > 0) { diskUsed = d[0] / 1048576; diskTotal = d[1] / 1048576 }
        if (seg.length < 2) return
        var rest = seg[1].split("__IO__")

        // disk I/O first, so it can be folded into each process group below.
        // Key is the same 15-char comm name `ps -o comm` reports.
        var ioByName = {}
        if (rest.length > 1) {
            rest[1].trim().split("\n").forEach(function(ln) {
                var f = ln.trim().split(/\s+/)
                if (f.length < 2) return
                var nm = f.slice(0, f.length - 1).join(" ")
                ioByName[nm] = (ioByName[nm] || 0) + (parseFloat(f[f.length - 1]) || 0)
            })
        }

        // group processes by name → one accumulated entry per family (e.g. the
        // handful of "steam"/"claude" procs collapse into "steam ×5" with summed
        // cpu/mem). procCount keeps the true total across all processes.
        var agg = {}, total = 0
        rest[0].trim().split("\n").forEach(function(ln) {
            var f = ln.trim().split(/\s+/)
            if (f.length < 3) return
            var nm = f.slice(0, f.length - 2).join(" ")
            var cpu = parseFloat(f[f.length - 2]) || 0
            var mem = parseFloat(f[f.length - 1]) || 0
            if (!agg[nm]) agg[nm] = { name: nm, cpu: 0, mem: 0, io: ioByName[nm] || 0, count: 0 }
            agg[nm].cpu += cpu; agg[nm].mem += mem; agg[nm].count++
            total++
        })
        procCount = total
        topProcs = Object.keys(agg).map(function (k) { return agg[k] })
    }

    function field(o, k, dflt) { return (o && o[k] !== undefined && o[k] !== null && o[k] !== "") ? o[k] : (dflt || "—") }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2
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
            PC3.Label { text: field(root.ov, "gpu"); font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            PC3.Label {
                text: "driver " + field(root.ov, "driver") + " · CUDA " + field(root.ov, "cuda_runtime") + " · toolkit " + field(root.ov, "cuda_toolkit")
                opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            Kirigami.Separator { Layout.fillWidth: true }

            RowLayout {
                PC3.Label { text: "Deployments"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "deployments") + "  (incl. rollback)"; Layout.fillWidth: true }
            }
            RowLayout {
                Layout.fillWidth: true
                PC3.Label { text: "Storage " + root.diskUsed.toFixed(0) + " GiB"; font.bold: true }
                Item { Layout.fillWidth: true }
                PC3.Label {
                    text: root.diskTotal > 0 ? "of " + (root.diskTotal / 1024).toFixed(1) + " TiB" : ""
                    opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
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
                text: "Heaviest processes (" + root.procCount + " in " + root.topProcs.length + " groups)"
                opacity: 0.6
            }
            // Sortable header — click a column to rank by it. This is the
            // "what's stealing my machine" view: cpu, memory, or disk I/O.
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                readonly property int metricW: Kirigami.Units.gridUnit * 3

                PC3.Label {
                    text: "process"; opacity: 0.5
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
                Repeater {
                    model: [ { key: "cpu", label: "cpu%" },
                             { key: "mem", label: "mem%" },
                             { key: "io",  label: "disk" } ]
                    delegate: PC3.Label {
                        readonly property bool active: root.sortKey === modelData.key
                        text: (active ? "▼ " : "") + modelData.label
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        font.bold: active
                        opacity: active ? 0.9 : 0.5
                        color: active ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: parent.metricW
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.sortKey = modelData.key
                        }
                    }
                }
            }
            // all processes grouped by name, sorted by the active column, in a
            // bounded scroll area (ListView virtualises, so hundreds of rows
            // stay cheap).
            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(root.sortedProcs.length * procList.rowH,
                                                 Kirigami.Units.gridUnit * 12)
                ListView {
                    id: procList
                    readonly property int rowH: Math.round(Kirigami.Theme.smallFont.pixelSize * 1.35)
                    readonly property int metricW: Kirigami.Units.gridUnit * 3
                    model: root.sortedProcs
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: RowLayout {
                        width: procList.width
                        spacing: Kirigami.Units.smallSpacing
                        PC3.Label {
                            text: (modelData.name || "")
                                  + (modelData.count > 1 ? " ×" + modelData.count : "")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.bold: true; opacity: 0.9
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        PC3.Label {
                            text: (modelData.cpu || 0).toFixed(1)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: root.sortKey === "cpu" ? 0.95 : 0.6
                            font.bold: root.sortKey === "cpu"
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: procList.metricW
                        }
                        PC3.Label {
                            text: (modelData.mem || 0).toFixed(1)
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: root.sortKey === "mem" ? 0.95 : 0.6
                            font.bold: root.sortKey === "mem"
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: procList.metricW
                        }
                        PC3.Label {
                            text: (modelData.io || 0) > 0 ? (modelData.io).toFixed(2) : "—"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: root.sortKey === "io" ? 0.95 : 0.6
                            font.bold: root.sortKey === "io"
                            horizontalAlignment: Text.AlignRight
                            Layout.preferredWidth: procList.metricW
                        }
                    }
                }
            }
            Item { Layout.fillHeight: true }
        }
    }
}
