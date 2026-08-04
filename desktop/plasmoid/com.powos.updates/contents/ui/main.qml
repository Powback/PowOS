// PowOS Updates plasmoid — a system-tray notifier for the bootc image.
//
// Everything it reads is UNPRIVILEGED:
//   • `powos version`        → running version + source commit
//   • `bootc status --json`  → booted image ref/digest + a rollback deployment
//   • `skopeo inspect`       → the remote digest for that same ref; a mismatch
//                              means an update is waiting (the sanctioned
//                              registry-digest check, no root, no `bootc
//                              upgrade --check` which needs a booted host + root)
//   • `git log` in /var/lib/powos/src → the changelog of what's shipped
//
// The two actions that DO need root (apply / roll back) are launched in a
// Konsole window so the user sees progress and enters their password there —
// the widget never tries to hold privileges itself.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation   // live in the tray as an icon

    property string srcDir: "/var/lib/powos/src"

    // ── parsed state ────────────────────────────────────────────
    property string curVersion: ""
    property string curCommit: ""
    property string curRef: ""
    property string curDigest: ""
    property string deployVersion: ""
    property string deployStamp: ""
    property string remoteDigest: ""
    property bool   hasRollback: false
    property string rollbackVersion: ""
    property var    changelog: []          // [{hash, subject, type}]

    // local source (/var/lib/powos/src) state, split two ways — these are
    // DIFFERENT things and the widget must never add them together:
    //   srcDirty — uncommitted edits, the only `powos update self` territory
    //   srcAhead — commits ahead of the running image, an OS-update signal
    //              (`powos update os` / upgrade), NOT `update self`
    property var    srcDirty: []           // uncommitted edits: [{status, path}]
    property var    srcAhead: []           // commits ahead of image: [{hash, subject, type}]

    property bool   checking: false
    property bool   ranOnce: false
    property string lastError: ""

    // remote check only meaningful when we got both digests
    readonly property bool checkOk: curDigest !== "" && remoteDigest !== ""
    readonly property bool updateAvailable: checkOk && curDigest !== remoteDigest
    // Two DISTINCT source signals — never conflate them (this split is the whole
    // point of the fix; adding them together is what produced the alarming
    // "109 changes to apply"):
    //  • localEdits — genuine uncommitted edits in /var/lib/powos/src. THIS is
    //    the only thing `powos update self` is for: a dev pushing their own live
    //    edits into the running system (reverts on reboot).
    //  • srcAheadOfImage — src has advanced past the commit the running image
    //    was built from (typically many upstream commits after a `git pull`).
    //    That means a newer IMAGE is due; the fix is `powos update os` / upgrade,
    //    NOT `update self`. Applying 100+ upstream commits transiently is wrong.
    readonly property bool localEdits: srcDirty.length > 0
    readonly property bool srcAheadOfImage: srcAhead.length > 0

    // one exec gathers everything; sentinels split the sections. The remote
    // digest is looked up inside the script (it already has the ref from bootc),
    // so the whole check is a single round-trip.
    readonly property string statusCmd:
        "echo __VER__; powos version 2>/dev/null; " +
        "echo __BOOTC__; BJ=$(bootc status --json 2>/dev/null); printf '%s' \"$BJ\"; echo; " +
        "echo __REMOTE__; REF=$(printf '%s' \"$BJ\" | jq -r '.status.booted.image.image.image // empty' 2>/dev/null); " +
        "[ -n \"$REF\" ] && skopeo inspect --format '{{.Digest}}' \"docker://$REF\" 2>/dev/null; echo; " +
        // local source state: uncommitted edits + commits ahead of the commit
        // the running image was built from (/usr/lib/powos/.powos-src-commit).
        // GIT_OPTIONAL_LOCKS=0 keeps the read-only status from writing the index.
        "G=\"env GIT_OPTIONAL_LOCKS=0 git -C " + srcDir + " -c safe.directory=" + srcDir + "\"; " +
        "MK=$(cat /usr/lib/powos/.powos-src-commit 2>/dev/null || cat /var/lib/powos/.powos-src-commit 2>/dev/null); " +
        "echo __DIRTY__; $G status --porcelain 2>/dev/null; " +
        "echo __AHEAD__; [ -n \"$MK\" ] && $G log --pretty=format:'%h%x1f%s' \"${MK}..HEAD\" 2>/dev/null; echo; " +
        "echo __LOG__; $G log --pretty=format:'%h%x1f%s' -n 30 2>/dev/null"

    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function check() {
        if (root.checking) return
        root.checking = true
        poller.connectSource(root.statusCmd)
    }

    // section between two sentinels (sentinels are on their own lines)
    function section(txt, a, b) {
        var i = txt.indexOf(a); if (i < 0) return ""
        i += a.length
        var j = b ? txt.indexOf(b, i) : -1
        return (j < 0 ? txt.substring(i) : txt.substring(i, j)).trim()
    }

    // strip a leading "[Task: …] " chore prefix and read the conventional-commit
    // type ("feat", "fix", …) so the changelog can colour it.
    function cleanSubject(s) {
        return String(s).replace(/^\[Task:[^\]]*\]\s*/i, "").trim()
    }
    function commitType(subject) {
        var m = String(subject).match(/^([a-z]+)(\([^)]*\))?!?:/)
        return m ? m[1] : ""
    }

    function parse(out) {
        root.lastError = ""
        // version
        var ver = section(out, "__VER__", "__BOOTC__")
        var mv = ver.match(/version\s+(\S+)/i);      root.curVersion = mv ? mv[1] : "?"
        var mc = ver.match(/commit:\s*(\S+)/i);      root.curCommit  = mc ? mc[1] : ""

        // bootc deployment json
        var bj = section(out, "__BOOTC__", "__REMOTE__")
        var ref = "", dig = "", dv = "", ds = "", hasRb = false, rbv = ""
        try {
            var j = JSON.parse(bj)
            var b = j && j.status && j.status.booted
            if (b && b.image) {
                if (b.image.image && b.image.image.image) ref = b.image.image.image
                dig = b.image.imageDigest || ""
                dv  = b.image.version || ""
                ds  = b.image.timestamp || ""
            }
            var rb = j && j.status && j.status.rollback
            if (rb && rb.image) { hasRb = true; rbv = rb.image.version || "" }
        } catch (e) { /* no host / not bootc → leave blank, UI copes */ }
        root.curRef = ref; root.curDigest = dig
        root.deployVersion = dv; root.deployStamp = ds
        root.hasRollback = hasRb; root.rollbackVersion = rbv

        // remote digest
        root.remoteDigest = section(out, "__REMOTE__", "__DIRTY__")

        // local uncommitted edits (git porcelain: "XY path")
        var dirty = section(out, "__DIRTY__", "__AHEAD__")
        var dRows = []
        if (dirty !== "") {
            var dl = dirty.split("\n")
            for (var k = 0; k < dl.length; k++) {
                var ln = dl[k]
                if (ln.trim() === "") continue
                dRows.push({ status: ln.substring(0, 2).trim(), path: ln.substring(3) })
            }
        }
        root.srcDirty = dRows

        // commits in the src tree ahead of the running image
        root.srcAhead = parseCommitLines(section(out, "__AHEAD__", "__LOG__"))
        // full changelog of what's shipped
        root.changelog = parseCommitLines(section(out, "__LOG__", null))
    }

    // "hash <US> subject" lines → [{hash, subject, type}]
    function parseCommitLines(blob) {
        var rows = []
        if (!blob || blob === "") return rows
        var lines = blob.split("\n")
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].split(String.fromCharCode(31))
            if (parts.length < 2) continue
            var subj = cleanSubject(parts[1])
            rows.push({ hash: parts[0], subject: subj, type: commitType(subj) })
        }
        return rows
    }

    // colour for a conventional-commit type badge
    function typeColor(t) {
        if (t === "feat") return Kirigami.Theme.positiveTextColor
        if (t === "fix")  return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.disabledTextColor
    }

    // short "sha256:abcd…1234" for compact digest display
    function shortDigest(d) {
        d = String(d || ""); if (d === "") return "—"
        var h = d.replace(/^sha256:/, "")
        return h.length > 12 ? h.substring(0, 8) + "…" + h.substring(h.length - 4) : h
    }
    // "2026-07-01T12:00:00Z" → "2026-07-01 12:00"
    function fmtStamp(s) {
        s = String(s || ""); var m = s.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/)
        return m ? m[1] + " " + m[2] : s
    }

    // launch a privileged command in Konsole so the user sees it + can auth
    function runInKonsole(cmd) {
        var wrapped = cmd + "; echo; echo '── done. Press Enter to close ──'; read _"
        runner.connectSource("konsole -e bash -lc " + shellQuote(wrapped) + " >/dev/null 2>&1 &")
    }
    function applyUpdate()  { runInKonsole("sudo powos upgrade") }
    function rollBack()     { runInKonsole("sudo bootc rollback && echo 'Rollback staged — reboot to switch versions.'") }
    // push the bundled /var/lib/powos/src edits into the running system (transient)
    function applyLocal()   { runInKonsole("sudo powos update self") }

    P5Support.DataSource {
        id: poller; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            root.checking = false; root.ranOnce = true
            root.parse((d.stdout || "").toString())
            if ((d.stderr || "") !== "" && (d.stdout || "") === "")
                root.lastError = String(d.stderr).substring(0, 200)
        }
    }
    P5Support.DataSource {
        id: runner; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s) }
    }

    // updates don't move fast — poll every 30 min, and whenever the popup opens
    Timer { interval: 30 * 60 * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.check() }
    onExpandedChanged: if (expanded) root.check()

    // ── tray icon ───────────────────────────────────────────────
    compactRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.iconSizes.small
        Layout.minimumHeight: Kirigami.Units.iconSizes.small

        Kirigami.Icon {
            id: trayIcon
            anchors.fill: parent
            source: root.updateAvailable ? "software-update-available"
                                         : "system-software-update"
            active: mouse.containsMouse
            opacity: root.updateAvailable ? 1.0 : 0.85
        }
        // small accent dot when an update is waiting
        Rectangle {
            visible: root.updateAvailable
            width: Math.round(parent.width * 0.32); height: width; radius: width / 2
            anchors.right: parent.right; anchors.top: parent.top
            color: Kirigami.Theme.highlightColor
            border.width: 1; border.color: Kirigami.Theme.backgroundColor
        }
        PC3.BusyIndicator {
            anchors.fill: parent
            running: root.checking && !root.ranOnce
            visible: running
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
        }
        PC3.ToolTip.text: {
            var base = root.updateAvailable ? "PowOS update available"
                     : root.checkOk ? "PowOS is up to date"
                     : "PowOS Updates"
            if (root.localEdits) return base + " · uncommitted local edits"
            if (root.srcAheadOfImage) return base + " · source ahead of running image"
            return base
        }
        PC3.ToolTip.visible: mouse.containsMouse
        PC3.ToolTip.delay: 600
    }

    // ── popup ───────────────────────────────────────────────────
    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            // header
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon {
                    source: "system-software-update"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PC3.Label { text: "PowOS Updates"; font.bold: true; Layout.fillWidth: true }
                PC3.BusyIndicator {
                    running: root.checking; visible: root.checking
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PC3.ToolButton {
                    icon.name: "view-refresh"
                    enabled: !root.checking
                    onClicked: root.check()
                    PC3.ToolTip.text: "Check now"
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: 600
                }
            }

            // status banner
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: bannerCol.implicitHeight + Kirigami.Units.largeSpacing
                radius: Kirigami.Units.smallSpacing
                color: root.updateAvailable
                    ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                              Kirigami.Theme.highlightColor.b, 0.15)
                    : Kirigami.Theme.alternateBackgroundColor

                RowLayout {
                    id: bannerCol
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: root.updateAvailable ? "software-update-available"
                               : root.checkOk ? "vcs-normal" : "dialog-question"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        PC3.Label {
                            text: root.updateAvailable ? "Update available"
                                : root.checkOk ? "Up to date"
                                : (root.ranOnce ? "Couldn’t reach the registry" : "Checking…")
                            font.bold: true
                        }
                        PC3.Label {
                            text: root.updateAvailable
                                    ? ("local " + root.shortDigest(root.curDigest) + " → remote " + root.shortDigest(root.remoteDigest))
                                    : root.checkOk ? ("digest " + root.shortDigest(root.curDigest))
                                    : (root.curRef === "" ? "not a bootc deployment" : "remote digest unavailable")
                            opacity: 0.7; font: Kirigami.Theme.smallFont
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    PC3.Button {
                        visible: root.updateAvailable
                        text: "Install"
                        icon.name: "cloud-download"
                        onClicked: root.applyUpdate()
                    }
                }
            }

            // current version card
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                RowLayout {
                    Layout.fillWidth: true
                    PC3.Label { text: "Version"; opacity: 0.6; font: Kirigami.Theme.smallFont }
                    Item { Layout.fillWidth: true }
                    PC3.Label {
                        text: root.curVersion + (root.deployVersion !== "" ? "  ·  " + root.deployVersion : "")
                        font: Kirigami.Theme.smallFont
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.curCommit !== ""
                    PC3.Label { text: "Commit"; opacity: 0.6; font: Kirigami.Theme.smallFont }
                    Item { Layout.fillWidth: true }
                    PC3.Label { text: root.curCommit; font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.deployStamp !== ""
                    PC3.Label { text: "Deployed"; opacity: 0.6; font: Kirigami.Theme.smallFont }
                    Item { Layout.fillWidth: true }
                    PC3.Label { text: root.fmtStamp(root.deployStamp); font: Kirigami.Theme.smallFont }
                }
                // rollback deployment (previous version you can switch back to)
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.hasRollback
                    PC3.Label { text: "Previous"; opacity: 0.6; font: Kirigami.Theme.smallFont }
                    PC3.Label {
                        text: root.rollbackVersion !== "" ? root.rollbackVersion : "available"
                        font: Kirigami.Theme.smallFont; elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    PC3.Button {
                        text: "Roll back"; icon.name: "edit-undo"
                        onClicked: root.rollBack()
                    }
                }
            }

            // ── running image is behind the source tree ─────────────────────
            // src carries commits the running image was NOT built with (usually
            // many, after a `git pull`) → a newer image is due. Informational
            // ONLY: the sanctioned fix is an OS update — `powos update os` /
            // upgrade, or the "Install" action in the banner above once a build
            // is published. This is NOT `update self`, so there is no apply
            // button here: transiently pushing 100+ upstream commits into the
            // running system is exactly the action we're steering the user away
            // from.
            Rectangle {
                visible: root.srcAheadOfImage
                Layout.fillWidth: true
                Layout.preferredHeight: aheadCol.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: Kirigami.Theme.alternateBackgroundColor

                ColumnLayout {
                    id: aheadCol
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "vcs-update-required"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PC3.Label { text: "Running image is behind the source"; font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                            PC3.Label {
                                text: {
                                    var n = root.srcAhead.length
                                    return "source tree is " + n + " commit" + (n > 1 ? "s" : "")
                                         + " ahead of the running image — " + (root.updateAvailable
                                              ? "install the update above to catch up"
                                              : "run powos update os to catch up")
                                }
                                opacity: 0.7; font: Kirigami.Theme.smallFont
                                wrapMode: Text.Wrap; Layout.fillWidth: true
                            }
                        }
                    }

                    // a short preview of the newest commits the image is missing
                    Repeater {
                        model: root.srcAhead.slice(0, 3)
                        delegate: PC3.Label {
                            required property var modelData
                            Layout.fillWidth: true
                            text: "• " + modelData.subject
                            opacity: 0.75; font.pointSize: Kirigami.Theme.smallFont.pointSize
                            elide: Text.ElideRight
                        }
                    }
                    PC3.Label {
                        visible: root.srcAhead.length > 3
                        text: "…and " + (root.srcAhead.length - 3) + " more"
                        opacity: 0.5; font: Kirigami.Theme.smallFont
                    }
                }
            }

            // ── uncommitted local edits: what `powos update self` applies ──
            // Scoped to genuine porcelain changes ONLY — a dev's own live edits
            // to the bundled source, pushed transiently into the running system
            // (reverts on reboot). Commits already merged upstream are NOT here;
            // those belong to the "Running image is behind" note above.
            Rectangle {
                visible: root.localEdits
                Layout.fillWidth: true
                Layout.preferredHeight: localCol.implicitHeight + Kirigami.Units.smallSpacing * 2
                radius: Kirigami.Units.smallSpacing
                color: Qt.rgba(Kirigami.Theme.neutralTextColor.r, Kirigami.Theme.neutralTextColor.g,
                               Kirigami.Theme.neutralTextColor.b, 0.15)

                ColumnLayout {
                    id: localCol
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "document-edit"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PC3.Label { text: "Uncommitted local edits"; font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                            PC3.Label {
                                text: root.srcDirty.length + " uncommitted edit" + (root.srcDirty.length > 1 ? "s" : "") + " in the source tree"
                                opacity: 0.7; font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                        }
                        PC3.Button {
                            text: "Apply"
                            icon.name: "system-run"
                            onClicked: root.applyLocal()
                            PC3.ToolTip.text: "sudo powos update self — apply your uncommitted edits to the running system (reverts on reboot)"
                            PC3.ToolTip.visible: hovered
                            PC3.ToolTip.delay: 600
                        }
                    }

                    // a short preview of the changed files
                    Repeater {
                        model: root.srcDirty.slice(0, 3)
                        delegate: PC3.Label {
                            required property var modelData
                            Layout.fillWidth: true
                            text: (modelData.status || "M") + "  " + modelData.path
                            opacity: 0.6; font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize
                            elide: Text.ElideMiddle
                        }
                    }
                    PC3.Label {
                        visible: root.srcDirty.length > 3
                        text: "…and " + (root.srcDirty.length - 3) + " more"
                        opacity: 0.5; font: Kirigami.Theme.smallFont
                    }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            PC3.Label {
                text: "Recent changes"
                font.bold: true; font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.7
            }

            // changelog
            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ListView {
                    model: root.changelog
                    spacing: Math.round(Kirigami.Units.smallSpacing / 2)
                    delegate: RowLayout {
                        required property var modelData
                        width: ListView.view ? ListView.view.width : 0
                        spacing: Kirigami.Units.smallSpacing
                        PC3.Label {
                            text: modelData.hash
                            font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: 0.5
                        }
                        PC3.Label {
                            visible: modelData.type !== ""
                            text: modelData.type
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.bold: true
                            color: root.typeColor(modelData.type)
                        }
                        PC3.Label {
                            text: modelData.subject
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                }
            }

            PC3.Label {
                visible: root.changelog.length === 0 && root.ranOnce
                text: root.lastError !== "" ? root.lastError : "No changelog (source tree not found)"
                opacity: 0.6; wrapMode: Text.Wrap; Layout.fillWidth: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}
