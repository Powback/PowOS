// PowOS Containers plasmoid — manage podman containers from the desktop,
// grouped by compose stack.
//
// Polls `powos containers list --json` (structure) and `powos containers stats
// --json` (live cpu/mem/net/disk) every 5s. Shows every container — running AND
// stopped — so a stopped one never disappears; its Start button is right there.
// Containers that belong to a docker/podman-compose project are grouped under a
// stack header showing the stack's base dir (click it to open in the file
// manager) and aggregated resource use. Standalone containers list at the end.
//
// Actions run `powos containers <action> <name>`:
//   start / stop / restart → podman <action> (never rm; container persists)
//   delete                 → podman rm -f, gated behind a confirm dialog here
// Base dir opens via `xdg-open` (Dolphin on Plasma).
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
    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 12

    property string listCmd: "powos containers list --json"
    property string statsCmd: "powos containers stats --json"
    property bool busy: false
    property string confirmName: ""      // pending delete target (empty = dialog hidden)

    property var rawList: []             // last parsed structural list
    property var statsByName: ({})       // name -> stats object

    ListModel { id: rowModel }           // flat display rows (stack headers + containers)

    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    function refresh() { lister.connectSource(root.listCmd) }
    function refreshStats() { statter.connectSource(root.statsCmd) }

    // ── formatting ──────────────────────────────────────────────
    function fmtBytes(n) {
        n = Number(n) || 0
        if (n < 1000) return n + " B"
        var u = ["kB", "MB", "GB", "TB"], i = -1
        do { n /= 1000; i++ } while (n >= 1000 && i < u.length - 1)
        return (n < 10 ? n.toFixed(1) : Math.round(n)) + " " + u[i]
    }
    function fmtPct(x) { return (Number(x) || 0).toFixed(1) + "%" }

    // Every row carries the same full role set — ListModel fixes its schema from
    // the first item, so stack rows and container rows must share all keys.
    function blankRow() {
        return { rowType: "", project: "", workdir: "", name: "", label: "",
                 grouped: false, image: "", status: "", state: "", running: false,
                 scope: "user", run: 0, total: 0, cpu: 0, mem: 0,
                 net_rx: 0, net_tx: 0, blk_r: 0, blk_w: 0, hasStats: false }
    }

    function parseList(txt) {
        var arr
        try { arr = JSON.parse(txt) } catch (e) { return }
        if (!Array.isArray(arr)) return
        root.rawList = arr
        rebuild()
    }
    function parseStats(txt) {
        var arr
        try { arr = JSON.parse(txt) } catch (e) { return }
        var m = {}
        if (Array.isArray(arr)) for (var i = 0; i < arr.length; i++) m[arr[i].name] = arr[i]
        root.statsByName = m
        rebuild()
    }

    function rebuild() {
        var list = root.rawList || []
        var st = root.statsByName || {}

        // group containers by compose project ("" = standalone)
        var groups = {}, order = []
        for (var i = 0; i < list.length; i++) {
            var c = list[i], p = c.project || ""
            if (!(p in groups)) { groups[p] = { workdir: c.workdir || "", items: [] }; order.push(p) }
            if (!groups[p].workdir && c.workdir) groups[p].workdir = c.workdir
            groups[p].items.push(c)
        }
        // named stacks first (alpha), standalone ("") last
        order.sort(function (a, b) {
            if (a === "") return 1
            if (b === "") return -1
            return a.toLowerCase() < b.toLowerCase() ? -1 : 1
        })

        var rows = []
        for (var g = 0; g < order.length; g++) {
            var key = order[g], grp = groups[key]
            var agg = { cpu: 0, mem: 0, net_rx: 0, net_tx: 0, blk_r: 0, blk_w: 0, run: 0 }
            for (var k = 0; k < grp.items.length; k++) {
                var it = grp.items[k], s = st[it.name]
                if (it.running) agg.run++
                if (s) {
                    agg.cpu += s.cpu; agg.mem += s.mem
                    agg.net_rx += s.net_rx; agg.net_tx += s.net_tx
                    agg.blk_r += s.blk_r; agg.blk_w += s.blk_w
                }
            }
            if (key !== "") {
                var hr = blankRow()
                hr.rowType = "stack"; hr.project = key; hr.workdir = grp.workdir
                hr.run = agg.run; hr.total = grp.items.length
                hr.cpu = agg.cpu; hr.mem = agg.mem
                hr.net_rx = agg.net_rx; hr.net_tx = agg.net_tx
                hr.blk_r = agg.blk_r; hr.blk_w = agg.blk_w
                rows.push(hr)
            }
            for (var j = 0; j < grp.items.length; j++) {
                var ci = grp.items[j], cs = st[ci.name] || null
                var r = blankRow()
                r.rowType = "ctr"; r.name = ci.name
                r.label = (key !== "" && ci.service) ? ci.service : ci.name
                r.grouped = (key !== "")
                r.image = ci.image || ""; r.status = ci.status || ""; r.state = ci.state || ""
                r.running = !!ci.running; r.scope = ci.scope || "user"
                if (cs) {
                    r.cpu = cs.cpu; r.mem = cs.mem
                    r.net_rx = cs.net_rx; r.net_tx = cs.net_tx
                    r.blk_r = cs.blk_r; r.blk_w = cs.blk_w; r.hasStats = true
                }
                rows.push(r)
            }
        }
        // sync into the model in place so scroll position survives the 5s refresh
        for (var x = 0; x < rows.length; x++) {
            if (x < rowModel.count) rowModel.set(x, rows[x])
            else rowModel.append(rows[x])
        }
        while (rowModel.count > rows.length) rowModel.remove(rowModel.count - 1)
    }

    function runAction(name, action) {
        if (root.busy) return
        root.busy = true
        actor.connectSource("powos containers " + action + " " + root.shellQuote(name) + " >/dev/null 2>&1; echo done")
    }
    function openDir(dir) {
        if (!dir) return
        opener.connectSource("xdg-open " + root.shellQuote(dir) + " >/dev/null 2>&1; echo done")
    }
    function confirmDelete() {
        var n = root.confirmName
        root.confirmName = ""
        if (n) root.runAction(n, "delete")
    }

    P5Support.DataSource {
        id: lister; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.parseList((d.stdout || "").trim()) }
    }
    P5Support.DataSource {
        id: statter; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.parseStats((d.stdout || "").trim()) }
    }
    P5Support.DataSource {
        id: actor; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.busy = false; root.refresh(); root.refreshStats() }
    }
    P5Support.DataSource {
        id: opener; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s) }
    }

    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshStats() }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumWidth: Kirigami.Units.gridUnit * 17
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredHeight: Kirigami.Units.gridUnit * 22

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon {
                    source: "container"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PC3.Label { text: "Containers"; font.bold: true; Layout.fillWidth: true }
                PC3.BusyIndicator {
                    running: root.busy; visible: root.busy
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PC3.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: { root.refresh(); root.refreshStats() }
                }
            }

            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: view
                    model: rowModel
                    clip: true
                    spacing: Math.round(Kirigami.Units.smallSpacing / 2)

                    delegate: Item {
                        width: view.width
                        implicitHeight: model.rowType === "stack" ? stackCol.implicitHeight
                                                                  : ctrRow.implicitHeight

                        // ── stack header ──────────────────────────
                        ColumnLayout {
                            id: stackCol
                            visible: model.rowType === "stack"
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: Kirigami.Units.smallSpacing
                                Kirigami.Icon {
                                    source: "folder-stash"
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                }
                                PC3.Label { text: model.project; font.bold: true; elide: Text.ElideRight }
                                PC3.Label {
                                    text: "· " + model.run + "/" + model.total + " up"
                                    opacity: 0.6; font: Kirigami.Theme.smallFont
                                }
                                Item { Layout.fillWidth: true }
                                PC3.Label {
                                    text: root.fmtPct(model.cpu) + " · " + root.fmtBytes(model.mem)
                                    opacity: 0.75; font: Kirigami.Theme.smallFont
                                }
                            }
                            // clickable base dir → opens in the file manager
                            PC3.Label {
                                visible: model.workdir !== ""
                                text: model.workdir
                                color: Kirigami.Theme.linkColor
                                // set sub-properties individually — mixing the
                                // grouped `font:` with `font.underline` is a QML
                                // compile error.
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.underline: dirMouse.containsMouse
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                                MouseArea {
                                    id: dirMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openDir(model.workdir)
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                                PC3.Label {
                                    text: "net ↓" + root.fmtBytes(model.net_rx) + " ↑" + root.fmtBytes(model.net_tx)
                                          + "   disk r " + root.fmtBytes(model.blk_r) + " w " + root.fmtBytes(model.blk_w)
                                    opacity: 0.5; font: Kirigami.Theme.smallFont
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                            }
                        }

                        // ── container row ─────────────────────────
                        RowLayout {
                            id: ctrRow
                            visible: model.rowType === "ctr"
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top
                            spacing: Kirigami.Units.smallSpacing

                            // indent members of a stack
                            Item {
                                Layout.preferredWidth: model.grouped
                                    ? Kirigami.Units.iconSizes.small : 0
                            }
                            Rectangle {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 0.55
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.55
                                radius: width / 2
                                color: model.running ? Kirigami.Theme.positiveTextColor
                                     : (model.state === "exited" ? Kirigami.Theme.neutralTextColor
                                                                 : Kirigami.Theme.disabledTextColor)
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                PC3.Label { text: model.label; elide: Text.ElideRight; Layout.fillWidth: true }
                                PC3.Label {
                                    text: model.running
                                        ? (root.fmtPct(model.cpu) + " · " + root.fmtBytes(model.mem)
                                           + " · net ↓" + root.fmtBytes(model.net_rx) + " ↑" + root.fmtBytes(model.net_tx))
                                        : (model.status + (model.scope === "system" ? "  · system" : ""))
                                    opacity: 0.6; elide: Text.ElideRight; Layout.fillWidth: true
                                    font: Kirigami.Theme.smallFont
                                }
                            }
                            PC3.ToolButton {
                                icon.name: "media-playback-start"
                                enabled: !model.running && !root.busy
                                onClicked: root.runAction(model.name, "start")
                            }
                            PC3.ToolButton {
                                icon.name: "media-playback-stop"
                                enabled: model.running && !root.busy
                                onClicked: root.runAction(model.name, "stop")
                            }
                            PC3.ToolButton {
                                icon.name: "view-refresh"
                                enabled: model.running && !root.busy
                                onClicked: root.runAction(model.name, "restart")
                            }
                            PC3.ToolButton {
                                icon.name: "edit-delete"
                                enabled: !root.busy
                                onClicked: root.confirmName = model.name
                            }
                        }
                    }
                }
            }

            PC3.Label {
                visible: rowModel.count === 0
                text: "No containers found"
                opacity: 0.6
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // ── delete confirmation overlay ─────────────────────────
        Rectangle {
            anchors.fill: parent
            visible: root.confirmName !== ""
            color: Qt.rgba(0, 0, 0, 0.6)
            // swallow clicks on the backdrop
            MouseArea { anchors.fill: parent; onClicked: {} }

            Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 20)
                height: dlg.implicitHeight + Kirigami.Units.largeSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: Kirigami.Theme.backgroundColor
                border.color: Kirigami.Theme.textColor
                border.width: 1

                ColumnLayout {
                    id: dlg
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.largeSpacing * 2
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Icon {
                            source: "dialog-warning"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                        }
                        PC3.Label { text: "Delete container?"; font.bold: true; Layout.fillWidth: true }
                    }
                    PC3.Label {
                        text: root.confirmName
                        opacity: 0.8; elide: Text.ElideMiddle; Layout.fillWidth: true
                    }
                    PC3.Label {
                        text: "Removes the container (podman rm -f). Volumes and images are kept; a compose stack can be recreated from its base dir."
                        opacity: 0.6; wrapMode: Text.Wrap; Layout.fillWidth: true
                        font: Kirigami.Theme.smallFont
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignRight
                        spacing: Kirigami.Units.smallSpacing
                        PC3.Button {
                            text: "Cancel"; icon.name: "dialog-cancel"
                            onClicked: root.confirmName = ""
                        }
                        PC3.Button {
                            text: "Delete"; icon.name: "edit-delete"
                            onClicked: root.confirmDelete()
                        }
                    }
                }
            }
        }
    }
}
