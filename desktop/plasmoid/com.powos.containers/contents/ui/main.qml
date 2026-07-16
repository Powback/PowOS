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
    property var expanded: ({})          // container name -> true when its detail is open
    property var detailTab: ({})         // name -> "logs" | "details" (default "logs")
    property var logsByName: ({})        // name -> last fetched log text
    property var pendingLog: ({})        // in-flight log command -> container name

    ListModel { id: rowModel }           // flat display rows (stack headers + containers + details)

    function toggleExpand(name) {
        if (root.expanded[name]) {
            delete root.expanded[name]
        } else {
            root.expanded[name] = true
            // default to the Logs tab and fetch it as soon as the row opens
            if (!root.detailTab[name]) root.detailTab[name] = "logs"
            if (root.detailTab[name] === "logs") root.fetchLogs(name)
        }
        rebuild()
    }

    // switch a container's detail tab; fetch logs on first view of that tab
    function setDetailTab(name, tab) {
        root.detailTab[name] = tab
        if (tab === "logs" && root.logsByName[name] === undefined) root.fetchLogs(name)
        rebuild()
    }

    // pull the last log lines for one container; keyed back by the exact command
    function fetchLogs(name) {
        var cmd = "powos containers logs " + root.shellQuote(name) + " --lines 300"
        root.pendingLog[cmd] = name
        logger.connectSource(cmd)
    }

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

    // ── ANSI → HTML ─────────────────────────────────────────────
    // Container logs (traefik, most apps) carry ANSI SGR color codes. A plain
    // TextEdit shows them as literal "[32m" noise, so convert the common subset
    // to RichText spans and strip the rest. Colors are picked to stay legible on
    // both light and dark log backgrounds.
    function ansi256(idx) {
        idx = Number(idx)
        if (idx < 16) {
            var base = ["#555","#e53935","#43a047","#c9a227","#1e88e5","#8e24aa","#00acc1","#cfcfcf",
                        "#777","#ff6f60","#76d275","#ffd54f","#6ab7ff","#c158dc","#5ddef4","#ffffff"]
            return base[idx] || ""
        }
        if (idx >= 232) { var g = 8 + (idx - 232) * 10; return Qt.rgba(g/255, g/255, g/255, 1) }
        idx -= 16
        var r = Math.floor(idx / 36), gg = Math.floor((idx % 36) / 6), b = idx % 6
        var conv = function (v) { return v === 0 ? 0 : 55 + v * 40 }
        return Qt.rgba(conv(r)/255, conv(gg)/255, conv(b)/255, 1)
    }
    function ansiToHtml(s) {
        if (s === undefined || s === null) return ""
        s = String(s).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
        // drop OSC (window-title etc.) and every CSI that isn't a color (SGR = final 'm')
        s = s.replace(/\][^]*(?:|\\)/g, "")
        s = s.replace(/\[[0-9;?]*[@-ln-~]/g, "")
        var fg = { "30":"#555","31":"#e53935","32":"#43a047","33":"#c9a227","34":"#1e88e5",
                   "35":"#8e24aa","36":"#00acc1","37":"#cfcfcf","90":"#777","91":"#ff6f60",
                   "92":"#76d275","93":"#ffd54f","94":"#6ab7ff","95":"#c158dc","96":"#5ddef4","97":"#ffffff" }
        function esc(t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
        var re = /\[([0-9;]*)m/g, out = "", last = 0, m, open = false
        var color = "", bold = false
        function span() {
            var st = (color ? "color:" + color + ";" : "") + (bold ? "font-weight:bold;" : "")
            return st ? '<span style="' + st + '">' : ""
        }
        while ((m = re.exec(s)) !== null) {
            out += esc(s.substring(last, m.index)); last = re.lastIndex
            if (open) { out += "</span>"; open = false }
            var codes = (m[1] === "") ? ["0"] : m[1].split(";")
            for (var i = 0; i < codes.length; i++) {
                var c = codes[i]
                if (c === "0" || c === "") { color = ""; bold = false }
                else if (c === "1") bold = true
                else if (c === "22") bold = false
                else if (c === "39") color = ""
                else if (c === "38" || c === "48") {
                    var isFg = (c === "38")
                    if (codes[i + 1] === "5") { if (isFg) color = "" + ansi256(codes[i + 2]); i += 2 }
                    else if (codes[i + 1] === "2") { if (isFg) color = "rgb(" + [codes[i+2],codes[i+3],codes[i+4]].join(",") + ")"; i += 4 }
                } else if (fg[c] !== undefined) color = fg[c]
            }
            var sp = span()
            if (sp) { out += sp; open = true }
        }
        out += esc(s.substring(last))
        if (open) out += "</span>"
        return '<pre style="font-family:monospace; white-space:pre-wrap; margin:0;">' + out + '</pre>'
    }

    // Every row carries the same full role set — ListModel fixes its schema from
    // the first item, so stack rows and container rows must share all keys.
    function blankRow() {
        return { rowType: "", project: "", workdir: "", name: "", label: "",
                 grouped: false, image: "", status: "", state: "", running: false,
                 scope: "user", run: 0, total: 0, cpu: 0, mem: 0,
                 net_rx: 0, net_tx: 0, blk_r: 0, blk_w: 0, hasStats: false,
                 isOpen: false, ports: "", labelsJson: "{}", traefikUrl: "",
                 activeTab: "logs", logText: "" }
    }

    // Extract the first Host(`...`) value from traefik router labels → "http://host"
    function traefikHost(labels) {
        if (!labels) return ""
        var ks = Object.keys(labels)
        for (var i = 0; i < ks.length; i++) {
            if (ks[i].indexOf("traefik.http.routers.") === 0 && ks[i].indexOf(".rule") > 0) {
                var m = String(labels[ks[i]]).match(/Host\(\s*`([^`]+)`\s*\)/)
                if (m) return "http://" + m[1]
            }
        }
        return ""
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
                r.ports = ci.ports || ""
                r.traefikUrl = root.traefikHost(ci.labels)
                r.isOpen = !!root.expanded[ci.name]
                rows.push(r)
                // when expanded, a detail row shows a tabbed panel (Logs / Details)
                if (r.isOpen) {
                    var dr = blankRow()
                    dr.rowType = "detail"; dr.grouped = (key !== ""); dr.ports = ci.ports || ""
                    dr.name = ci.name
                    dr.labelsJson = JSON.stringify(ci.labels || {})
                    dr.activeTab = root.detailTab[ci.name] || "logs"
                    // logsByName is refreshed asynchronously; read the cache here so
                    // the periodic rebuild keeps whatever log text has arrived
                    dr.logText = (root.logsByName[ci.name] !== undefined)
                        ? root.logsByName[ci.name] : ""
                    rows.push(dr)
                }
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
    // xdg-open handles both paths and http(s) URLs → default file manager / browser
    function openUrl(u) {
        if (!u) return
        opener.connectSource("xdg-open " + root.shellQuote(u) + " >/dev/null 2>&1; echo done")
    }
    // http://localhost:<host-port> for the first published port ("80→80/tcp" → 80)
    function portUrl(ports) {
        var m = String(ports || "").match(/^\s*(\d+)/)
        return m ? "http://localhost:" + m[1] : ""
    }
    function isUrl(s) { return /^https?:\/\//.test(String(s || "")) }
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
    P5Support.DataSource {
        id: logger; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            var name = root.pendingLog[s]
            delete root.pendingLog[s]
            if (!name) return
            var out = ((d.stdout || "") + (d.stderr || "")).replace(/\s+$/, "")
            root.logsByName[name] = out === "" ? "(no output)" : out
            root.rebuild()
        }
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
                                      : model.rowType === "detail" ? detailCol.implicitHeight
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
                            // name + stats; click to expand ports/labels detail.
                            // (TapHandler, not an anchored MouseArea — anchoring an
                            // item inside a Layout is undefined behaviour and the
                            // click area ends up zero-sized.)
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing / 2
                                    PC3.Label {
                                        text: model.isOpen ? "▾" : "▸"
                                        opacity: 0.5; font: Kirigami.Theme.smallFont
                                    }
                                    PC3.Label { text: model.label; elide: Text.ElideRight; Layout.fillWidth: true }
                                    // traefik route — clickable → open http://foo.pow
                                    PC3.Label {
                                        visible: model.traefikUrl !== ""
                                        text: model.traefikUrl.replace("http://", "")
                                        color: Kirigami.Theme.linkColor
                                        font: Kirigami.Theme.smallFont
                                        elide: Text.ElideRight
                                        TapHandler { onTapped: root.openUrl(model.traefikUrl) }
                                    }
                                    // published ports — clickable → open http://localhost:<port>
                                    PC3.Label {
                                        visible: model.ports !== "" && model.traefikUrl === ""
                                        text: "⇄ " + model.ports
                                        color: root.portUrl(model.ports) !== "" ? Kirigami.Theme.linkColor
                                                                                : Kirigami.Theme.textColor
                                        opacity: root.portUrl(model.ports) !== "" ? 1.0 : 0.6
                                        font: Kirigami.Theme.smallFont
                                        elide: Text.ElideRight
                                        TapHandler {
                                            enabled: root.portUrl(model.ports) !== ""
                                            onTapped: root.openUrl(root.portUrl(model.ports))
                                        }
                                    }
                                }
                                PC3.Label {
                                    text: model.running
                                        ? (root.fmtPct(model.cpu) + " · " + root.fmtBytes(model.mem)
                                           + " · net ↓" + root.fmtBytes(model.net_rx) + " ↑" + root.fmtBytes(model.net_tx))
                                        : (model.status + (model.scope === "system" ? "  · system" : ""))
                                    opacity: 0.6; elide: Text.ElideRight; Layout.fillWidth: true
                                    font: Kirigami.Theme.smallFont
                                }
                                TapHandler { onTapped: root.toggleExpand(model.name) }
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

                        // ── detail: tabbed panel (Logs / Details) shown when expanded ──
                        // Logs is the default tab (last ~300 log lines); Details keeps
                        // the ports + labels view. labelPairs turns the labels JSON into
                        // [{k, v, url}] so each label renders on its own row.
                        ColumnLayout {
                            id: detailCol
                            visible: model.rowType === "detail"
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.leftMargin: Kirigami.Units.gridUnit * 1.2
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            property bool onLogs: model.activeTab !== "details"

                            property var labelPairs: {
                                var o = {}
                                try { o = JSON.parse(model.labelsJson || "{}") } catch (e) { o = {} }
                                var ks = Object.keys(o).sort(), out = []
                                for (var i = 0; i < ks.length; i++)
                                    out.push({ k: ks[i], v: String(o[ks[i]]), url: root.isUrl(o[ks[i]]) })
                                return out
                            }

                            // ── tab bar ──
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.largeSpacing
                                PC3.Label {
                                    text: "Logs"
                                    font.bold: detailCol.onLogs
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    color: detailCol.onLogs ? Kirigami.Theme.highlightColor
                                                            : Kirigami.Theme.textColor
                                    opacity: detailCol.onLogs ? 1.0 : 0.7
                                    TapHandler { onTapped: root.setDetailTab(model.name, "logs") }
                                }
                                PC3.Label {
                                    text: "Details"
                                    font.bold: !detailCol.onLogs
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    color: !detailCol.onLogs ? Kirigami.Theme.highlightColor
                                                             : Kirigami.Theme.textColor
                                    opacity: !detailCol.onLogs ? 1.0 : 0.7
                                    TapHandler { onTapped: root.setDetailTab(model.name, "details") }
                                }
                                Item { Layout.fillWidth: true }
                                PC3.ToolButton {
                                    visible: detailCol.onLogs
                                    icon.name: "view-refresh"
                                    display: PC3.AbstractButton.IconOnly
                                    implicitHeight: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
                                    onClicked: root.fetchLogs(model.name)
                                    PC3.ToolTip.text: "Refresh logs"
                                    PC3.ToolTip.visible: hovered
                                    PC3.ToolTip.delay: 600
                                }
                            }

                            // ── Logs tab ──
                            Rectangle {
                                visible: detailCol.onLogs
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 9
                                radius: Kirigami.Units.smallSpacing
                                color: Kirigami.Theme.alternateBackgroundColor
                                border.width: 1
                                border.color: Qt.rgba(Kirigami.Theme.textColor.r,
                                                      Kirigami.Theme.textColor.g,
                                                      Kirigami.Theme.textColor.b, 0.15)

                                PC3.ScrollView {
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.smallSpacing
                                    clip: true
                                    contentWidth: availableWidth

                                    TextEdit {
                                        readOnly: true
                                        selectByMouse: true
                                        wrapMode: TextEdit.Wrap
                                        // render ANSI colors as rich text; the loading
                                        // placeholder stays plain so it dims correctly
                                        textFormat: model.logText !== "" ? TextEdit.RichText
                                                                         : TextEdit.PlainText
                                        text: model.logText !== "" ? root.ansiToHtml(model.logText)
                                                                    : "loading…"
                                        color: model.logText !== "" ? Kirigami.Theme.textColor
                                                                    : Qt.rgba(Kirigami.Theme.textColor.r,
                                                                              Kirigami.Theme.textColor.g,
                                                                              Kirigami.Theme.textColor.b, 0.5)
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                }
                            }

                            // ── Details tab: ports + labels ──
                            ColumnLayout {
                                visible: !detailCol.onLogs
                                Layout.fillWidth: true
                                spacing: 1

                                // clickable published ports → open http://localhost:<port>
                                PC3.Label {
                                    visible: model.ports !== ""
                                    text: "Ports: " + model.ports + (root.portUrl(model.ports) !== "" ? "  ↗" : "")
                                    color: root.portUrl(model.ports) !== "" ? Kirigami.Theme.linkColor
                                                                            : Kirigami.Theme.textColor
                                    font: Kirigami.Theme.smallFont
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    TapHandler {
                                        enabled: root.portUrl(model.ports) !== ""
                                        onTapped: root.openUrl(root.portUrl(model.ports))
                                    }
                                }
                                Repeater {
                                    model: detailCol.labelPairs
                                    delegate: PC3.Label {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        wrapMode: Text.WrapAnywhere
                                        font.family: "monospace"
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.underline: modelData.url
                                        color: modelData.url ? Kirigami.Theme.linkColor : Kirigami.Theme.textColor
                                        opacity: modelData.url ? 1.0 : 0.7
                                        text: modelData.k + " = " + modelData.v
                                        TapHandler {
                                            enabled: modelData.url
                                            onTapped: root.openUrl(modelData.v)
                                        }
                                    }
                                }
                                PC3.Label {
                                    visible: detailCol.labelPairs.length === 0 && model.ports === ""
                                    text: "no ports or labels"
                                    font: Kirigami.Theme.smallFont; opacity: 0.5
                                }
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
