// PowOS Camera Indicator — a tray widget that shows when the camera is in use
// AND names the application(s) using it.
//
// KDE's stock privacy indicator only says "the camera is in use" — it can't
// tell you *what* has it open. This does, by scanning /proc/<pid>/fd for open
// handles to /dev/video* and reading /proc/<pid>/comm for the process name.
//
// It's unprivileged on purpose: a normal user can only readlink the fds of
// their OWN processes, which is exactly where camera use lives (browser, Zoom,
// OBS, …). Root-owned openers stay invisible — an acceptable trade for needing
// no privileges. Each poll emits "pid|comm|device" lines; the UI groups them by
// process so one app holding capture + metadata nodes shows once.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root
    preferredRepresentation: compactRepresentation

    property var apps: []          // [{pid, comm, devs: [..]}]
    property bool ranOnce: false
    readonly property bool inUse: apps.length > 0

    // one line per open handle: "pid|comm|/dev/videoN". readlink on another
    // user's fd fails → continue, so we naturally see only our own processes.
    readonly property string scanCmd:
        "for l in /proc/[0-9]*/fd/*; do " +
        "t=$(readlink \"$l\" 2>/dev/null) || continue; " +
        "case \"$t\" in /dev/video*) " +
        "p=${l#/proc/}; p=${p%%/*}; " +
        "c=$(cat /proc/$p/comm 2>/dev/null) || c='?'; " +
        "echo \"$p|$c|$t\";; esac; done | sort -u"

    function scan() { scanner.connectSource(root.scanCmd) }

    // nicer label for a raw comm ("chrome" → "Chrome", known apps spelled out)
    function pretty(comm) {
        var known = {
            "chrome": "Google Chrome", "chromium": "Chromium", "firefox": "Firefox",
            "firefox-bin": "Firefox", "zoom": "Zoom", "obs": "OBS Studio",
            "Discord": "Discord", "teams": "Teams", "slack": "Slack",
            "cheese": "Cheese", "guvcview": "guvcview", "webcamoid": "Webcamoid"
        }
        if (known[comm]) return known[comm]
        return comm.charAt(0).toUpperCase() + comm.slice(1)
    }

    function parse(out) {
        root.ranOnce = true
        var byPid = {}, order = []
        var lines = String(out || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (ln === "") continue
            var f = ln.split("|")
            if (f.length < 3) continue
            var pid = f[0], comm = f[1], dev = f[2]
            if (!(pid in byPid)) { byPid[pid] = { pid: pid, comm: comm, devs: [] }; order.push(pid) }
            if (byPid[pid].devs.indexOf(dev) < 0) byPid[pid].devs.push(dev)
        }
        var list = []
        for (var j = 0; j < order.length; j++) list.push(byPid[order[j]])
        root.apps = list
    }

    P5Support.DataSource {
        id: scanner; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.parse(d.stdout || "") }
    }

    // camera state can change any moment (a call starts) — poll fairly briskly
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.scan() }
    onExpandedChanged: if (expanded) root.scan()

    // ── tray icon ───────────────────────────────────────────────
    compactRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.iconSizes.small
        Layout.minimumHeight: Kirigami.Units.iconSizes.small

        Kirigami.Icon {
            anchors.fill: parent
            source: "camera-web"
            active: cmouse.containsMouse
            // dim when idle so it reads as "nothing happening"
            opacity: root.inUse ? 1.0 : 0.45
        }
        // red "recording" dot when the camera is live
        Rectangle {
            visible: root.inUse
            width: Math.round(parent.width * 0.34); height: width; radius: width / 2
            anchors.right: parent.right; anchors.top: parent.top
            color: "#e53935"
            border.width: 1; border.color: Kirigami.Theme.backgroundColor
        }
        MouseArea {
            id: cmouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
        }
        PC3.ToolTip.text: root.inUse
            ? ("Camera in use: " + root.apps.map(function (a) { return root.pretty(a.comm) }).join(", "))
            : "Camera not in use"
        PC3.ToolTip.visible: cmouse.containsMouse
        PC3.ToolTip.delay: 500
    }

    // ── popup ───────────────────────────────────────────────────
    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.preferredHeight: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 9

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Icon {
                    source: "camera-web"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PC3.Label { text: "Camera"; font.bold: true; Layout.fillWidth: true }
                Rectangle {
                    visible: root.inUse
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    radius: width / 2; color: "#e53935"
                }
                PC3.ToolButton {
                    icon.name: "view-refresh"
                    onClicked: root.scan()
                    PC3.ToolTip.text: "Refresh"
                    PC3.ToolTip.visible: hovered
                    PC3.ToolTip.delay: 600
                }
            }

            // status line
            PC3.Label {
                Layout.fillWidth: true
                text: root.inUse
                    ? (root.apps.length === 1 ? "1 application is using the camera"
                                              : root.apps.length + " applications are using the camera")
                    : (root.ranOnce ? "The camera is not in use" : "Checking…")
                color: root.inUse ? "#e53935" : Kirigami.Theme.textColor
                opacity: root.inUse ? 1.0 : 0.7
                font: Kirigami.Theme.smallFont
            }

            Kirigami.Separator { Layout.fillWidth: true; visible: root.inUse }

            // per-app list
            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                visible: root.inUse

                ListView {
                    model: root.apps
                    spacing: Kirigami.Units.smallSpacing
                    delegate: RowLayout {
                        required property var modelData
                        width: ListView.view ? ListView.view.width : 0
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: "camera-web"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PC3.Label {
                                text: root.pretty(modelData.comm)
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                            PC3.Label {
                                text: "pid " + modelData.pid + "  ·  " + modelData.devs.join(", ")
                                opacity: 0.6; font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight; Layout.fillWidth: true
                            }
                        }
                    }
                }
            }

            // idle filler so the popup isn't awkwardly empty
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                visible: !root.inUse
                Kirigami.Icon {
                    anchors.centerIn: parent
                    source: "camera-web"
                    opacity: 0.25
                    width: Kirigami.Units.iconSizes.large; height: width
                }
            }
        }
    }
}
