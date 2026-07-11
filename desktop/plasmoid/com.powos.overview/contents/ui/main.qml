// PowOS Overview plasmoid — identity + inventory panel: base image/channel,
// GPU/driver/CUDA, deployments, storage bar, containers (with live stats),
// top processes. The live graphs live in the separate "PowOS Monitor" widget.
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
    property var svc: ({})
    property string err: ""
    property real diskUsed: 0;  property real diskTotal: 0     // GiB
    property var topProcs: []                                   // [{name,cpu,mem,count}] grouped by name
    property int procCount: 0                                   // total processes (before grouping)
    property var ctrStats: ({})                                 // name -> {cpu,mem,net}
    property var topIO: []                                      // [{name,mbs}]

    readonly property string dataCmd:
        "if powos overview --json >/dev/null 2>&1; then " +
        "  powos overview --json; echo __POWOS_SEP__; powos services --json; " +
        "else " +
        "  source \"$HOME/PowOS/lib/overview.sh\" 2>/dev/null; " +
        "  source \"$HOME/PowOS/lib/services.sh\" 2>/dev/null; " +
        "  ov_json; echo __POWOS_SEP__; svc_json; " +
        "fi"
    // disk | __PS__ | ALL processes (cpu-sorted) | __CTR__ | podman stats | __IO__ | top disk I/O
    // Per-process I/O (/proc/PID/io) is only readable for YOUR processes without
    // root — that covers apps + rootless containers, not system daemons. 1s sample.
    readonly property string mediumCmd:
        "df -k --output=used,size /var 2>/dev/null | tail -1; " +
        "echo __PS__; " +
        "ps -eo comm,%cpu,%mem --sort=-%cpu --no-headers; " +
        "echo __CTR__; " +
        "podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' 2>/dev/null; " +
        "echo __IO__; " +
        "T1=$(mktemp); T2=$(mktemp); " +
        // grep -s (NOT awk on the files directly): gawk FATALS on the first
        // unreadable/vanished /proc file (root-owned pids, exit races), which
        // silently produced nothing. grep -s skips them and never aborts.
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T1; " +
        "sleep 1; " +
        "grep -sH -E '^(read_bytes|write_bytes)' /proc/[0-9]*/io | awk -F: '{s[$1]+=$3} END{for(f in s) print f, s[f]}' > $T2; " +
        "awk 'NR==FNR{a[$1]=$2; next} ($1 in a) && ($2>a[$1]) {d=$2-a[$1]; split($1,p,\"/\"); pid=p[3]; cf=\"/proc/\"pid\"/comm\"; c=\"?\"; if((getline c < cf)>0) close(cf); print d, c}' $T1 $T2 | sort -rn | head -5 | awk '{printf \"%s %.2f\\n\", $2, $1/1048576}'; " +
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
                var parts = out.trim().split("__POWOS_SEP__")
                root.ov  = JSON.parse(parts[0])
                root.svc = parts.length > 1 ? JSON.parse(parts[1]) : {}
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
        var rest = seg[1].split("__CTR__")
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
            if (!agg[nm]) agg[nm] = { name: nm, cpu: 0, mem: 0, count: 0 }
            agg[nm].cpu += cpu; agg[nm].mem += mem; agg[nm].count++
            total++
        })
        var procs = Object.keys(agg).map(function (k) { return agg[k] })
        procs.sort(function (a, b) { return b.cpu - a.cpu || b.mem - a.mem })
        procCount = total
        topProcs = procs
        var stats = {}
        var io = []
        if (rest.length > 1) {
            var tail = rest[1].split("__IO__")
            tail[0].trim().split("\n").forEach(function(ln) {
                var f = ln.split("|")
                if (f.length >= 4 && f[0]) stats[f[0]] = { cpu: f[1], mem: f[2], net: f[3] }
            })
            if (tail.length > 1) {
                tail[1].trim().split("\n").forEach(function(ln) {
                    var f = ln.trim().split(/\s+/)
                    if (f.length >= 2) io.push({ name: f.slice(0, f.length - 1).join(" "),
                                                 mbs: parseFloat(f[f.length - 1]) || 0 })
                })
            }
        }
        ctrStats = stats
        topIO = io
    }

    function field(o, k, dflt) { return (o && o[k] !== undefined && o[k] !== null && o[k] !== "") ? o[k] : (dflt || "—") }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
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
                readonly property int n: root.svc && root.svc.containers ? root.svc.containers.length : 0
                text: "Containers (" + n + ")"; opacity: 0.6
            }
            Repeater {
                model: root.svc && root.svc.containers ? root.svc.containers : []
                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Rectangle { width: Kirigami.Units.smallSpacing * 2; height: width; radius: width / 2; color: Kirigami.Theme.positiveTextColor }
                        PC3.Label { text: modelData.name; font.bold: true }
                        PC3.Label {
                            text: (modelData.gpu ? "gpu · " : "") + modelData.status
                            opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PC3.Label {
                        readonly property var st: root.ctrStats[modelData.name]
                        visible: st !== undefined
                        text: st ? ("cpu " + st.cpu + " · mem " + st.mem + " · net " + st.net) : ""
                        opacity: 0.6; font.pointSize: Kirigami.Theme.smallFont.pointSize
                        leftPadding: Kirigami.Units.largeSpacing
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
            }
            PC3.Label {
                visible: !root.svc || !root.svc.containers || root.svc.containers.length === 0
                text: "none running"; opacity: 0.5; font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Kirigami.Separator { Layout.fillWidth: true }

            PC3.Label {
                text: "Processes (" + root.procCount + " in " + root.topProcs.length + " groups)"
                opacity: 0.6
            }
            // all processes grouped by name, cpu-sorted, in a bounded scroll area
            // (ListView virtualises, so hundreds of rows stay cheap).
            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(root.topProcs.length * procList.rowH,
                                                 Kirigami.Units.gridUnit * 12)
                ListView {
                    id: procList
                    readonly property int rowH: Math.round(Kirigami.Theme.smallFont.pixelSize * 1.35)
                    model: root.topProcs
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: RowLayout {
                        width: procList.width
                        spacing: Kirigami.Units.largeSpacing
                        PC3.Label {
                            text: (modelData.name || "")
                                  + (modelData.count > 1 ? " ×" + modelData.count : "")
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.bold: true; opacity: 0.9
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        PC3.Label {
                            text: "cpu " + (modelData.cpu || 0).toFixed(1) + "%"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize; opacity: 0.65
                        }
                        PC3.Label {
                            text: "mem " + (modelData.mem || 0).toFixed(1) + "%"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize; opacity: 0.65
                        }
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true; visible: root.topIO.length > 0 }
            PC3.Label { visible: root.topIO.length > 0; text: "Top disk I/O"; opacity: 0.6 }
            Repeater {
                model: root.topIO
                delegate: RowLayout {
                    Layout.fillWidth: true
                    PC3.Label { text: modelData.name; font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize; elide: Text.ElideRight; Layout.fillWidth: true }
                    PC3.Label { text: modelData.mbs.toFixed(2) + " MB/s"; opacity: 0.65; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                }
            }
            Item { Layout.fillHeight: true }
        }
    }
}
