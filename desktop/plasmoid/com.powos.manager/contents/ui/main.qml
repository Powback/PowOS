// PowOS Manager plasmoid — talk to the standing PowOS manager from the desktop.
//
// Two panes:
//   LEFT sidebar  — your projects (~/Projects/*, ● = has a live manager thread)
//                   and the agent roster (with unread-inbox badges). Picking a
//                   project switches the manager to THAT project's thread
//                   (per-directory memory: see lib/ai/manager/manager.py).
//   RIGHT chat    — the live conversation. Each turn runs
//                   `powos ai manager --json-events --once …`, whose normalized
//                   event stream is rendered as chat bubbles + tool panels
//                   (⚙ tool_use, ↳ tool_result, ✉ inbox).
//
// Sidebar data comes from `powos ai manager --list-json` (one clean JSON blob,
// no ANSI to parse), refreshed on a timer. All shell-outs go through the
// standard Plasma executable DataSource, like the other PowOS plasmoids.
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
    Layout.minimumWidth: Kirigami.Units.gridUnit * 30
    Layout.minimumHeight: Kirigami.Units.gridUnit * 22

    property string powos: "/usr/bin/powos"
    property string currentProject: ""       // absolute path, "" = default (widget's cwd)
    property string currentProjectName: "default"
    property bool busy: false
    property string lastError: ""
    property var projects: []                // [{name, path, hasSession}]
    property var agents: []                  // [{name, pending}]

    ListModel { id: chatModel }              // {role, text, name, ok}

    // Single-quote a string for safe use in a shell command.
    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ── sidebar ────────────────────────────────────────────────────────────
    function refreshSidebar() { sidebarSource.connectSource(root.powos + " ai manager --list-json") }

    function applySidebar(text) {
        try {
            var d = JSON.parse(text)
            root.projects = d.projects || []
            root.agents = d.agents || []
        } catch (e) { /* transient — keep last good data */ }
    }

    function selectProject(path, name) {
        if (root.currentProject === path) return
        root.currentProject = path
        root.currentProjectName = name
        chatModel.clear()
        chatModel.append({ role: "system", text: "Switched to " + name +
            " — the manager resumed this project's thread. Say hello.",
            name: "", ok: true })
    }

    // ── chat ───────────────────────────────────────────────────────────────
    function send(text) {
        if (!text || !text.trim() || root.busy) return
        chatModel.append({ role: "user", text: text, name: "", ok: true })
        root.busy = true
        var cwd = root.currentProject ? (" --cwd " + shellQuote(root.currentProject)) : ""
        // Pipe the message in as stdin (base64) so nothing about the text needs
        // shell-escaping beyond the base64 alphabet.
        var b64 = Qt.btoa(text)
        var cmd = "printf %s " + shellQuote(b64) + " | base64 -d | " +
                  root.powos + " ai manager --json-events --once-stdin" + cwd
        chatSource.connectSource(cmd)
    }

    function pushEvents(out) {
        var lines = String(out).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line) continue
            var ev
            try { ev = JSON.parse(line) } catch (e) { continue }
            switch (ev.kind) {
            case "assistant":
                chatModel.append({ role: "manager", text: ev.text, name: "", ok: true }); break
            case "tool_use":
                chatModel.append({ role: "tool_use", text: ev.hint || "", name: ev.name, ok: true }); break
            case "tool_result":
                chatModel.append({ role: "tool_result", text: ev.text || "", name: "", ok: !!ev.ok }); break
            case "inbox":
                chatModel.append({ role: "inbox", text: ev.text, name: "", ok: true }); break
            // 'user' already shown; 'session'/'turn_done' are meta — ignore.
            }
        }
        chatView.positionViewAtEnd()
    }

    P5Support.DataSource {
        id: sidebarSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.applySidebar((d.stdout || "").trim()) }
    }
    P5Support.DataSource {
        id: chatSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s); root.busy = false
            if ((d.stderr || "").trim()) root.lastError = (d.stderr || "").trim()
            root.pushEvents(d.stdout || "")
        }
    }

    Timer { interval: 5000; running: true; repeat: true; onTriggered: root.refreshSidebar() }
    Component.onCompleted: refreshSidebar()

    fullRepresentation: RowLayout {
        anchors.fill: parent
        spacing: 0

        // ── LEFT: projects + agents ─────────────────────────────────────────
        Rectangle {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 11
            Layout.fillHeight: true
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.04)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Kirigami.Icon { source: "folder-symbolic"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small }
                    Kirigami.Heading { level: 4; text: "Projects"; Layout.fillWidth: true }
                }

                PC3.ScrollView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        model: root.projects
                        clip: true
                        delegate: PC3.ItemDelegate {
                            width: ListView.view.width
                            highlighted: modelData.path === root.currentProject
                            onClicked: root.selectProject(modelData.path, modelData.name)
                            contentItem: RowLayout {
                                PC3.Label {
                                    text: (modelData.hasSession ? "● " : "○ ") + modelData.name
                                    color: modelData.hasSession ? Kirigami.Theme.positiveTextColor
                                                                : Kirigami.Theme.textColor
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                RowLayout {
                    Kirigami.Icon { source: "system-users-symbolic"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small }
                    Kirigami.Heading { level: 4; text: "Agents"; Layout.fillWidth: true }
                }

                Repeater {
                    model: root.agents
                    delegate: PC3.ItemDelegate {
                        Layout.fillWidth: true
                        onClicked: root.selectAgentMention(modelData.name)
                        contentItem: RowLayout {
                            PC3.Label { text: modelData.name; elide: Text.ElideRight; Layout.fillWidth: true }
                            Rectangle {
                                visible: modelData.pending > 0
                                radius: height / 2
                                color: Kirigami.Theme.negativeBackgroundColor
                                implicitHeight: badge.implicitHeight + 2
                                implicitWidth: Math.max(implicitHeight, badge.implicitWidth + 8)
                                PC3.Label { id: badge; anchors.centerIn: parent
                                    text: modelData.pending; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }   // push content up
            }
        }

        Kirigami.Separator { Layout.fillHeight: true; Layout.preferredWidth: 1 }

        // ── RIGHT: live chat ────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                Kirigami.Icon { source: "system-run"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium }
                Kirigami.Heading { level: 3; text: "Manager"; }
                PC3.Label { text: "· " + root.currentProjectName; opacity: 0.7 }
                Item { Layout.fillWidth: true }
                PC3.BusyIndicator { running: root.busy; visible: root.busy
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small }
            }

            PC3.ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true
                ListView {
                    id: chatView
                    model: chatModel
                    clip: true
                    spacing: Kirigami.Units.smallSpacing
                    delegate: Item {
                        width: ListView.view.width
                        implicitHeight: bubble.implicitHeight + Kirigami.Units.smallSpacing

                        // colors / alignment per role
                        property bool isUser: model.role === "user"
                        property bool isTool: model.role === "tool_use" || model.role === "tool_result"
                        property bool isInbox: model.role === "inbox"
                        property bool isSystem: model.role === "system"

                        Rectangle {
                            id: bubble
                            anchors.right: isUser ? parent.right : undefined
                            anchors.left: isUser ? undefined : parent.left
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            width: Math.min(parent.width * (isTool || isInbox || isSystem ? 0.98 : 0.82),
                                            content.implicitWidth + Kirigami.Units.largeSpacing)
                            implicitHeight: content.implicitHeight + Kirigami.Units.smallSpacing * 2
                            radius: Kirigami.Units.smallSpacing
                            color: {
                                if (isUser) return Kirigami.Theme.highlightColor
                                if (model.role === "tool_use") return Qt.rgba(0.8, 0.6, 0, 0.14)
                                if (model.role === "tool_result") return Qt.rgba(0, 0.6, 0.2, 0.12)
                                if (isInbox) return Qt.rgba(0.6, 0.2, 0.8, 0.14)
                                if (isSystem) return "transparent"
                                return Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.07)   // manager
                            }

                            ColumnLayout {
                                id: content
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: 2
                                PC3.Label {
                                    visible: model.role === "tool_use"
                                    text: "⚙ " + (model.name || "") + (model.text ? "  " + model.text : "")
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                }
                                PC3.Label {
                                    visible: model.role === "tool_result"
                                    text: (model.ok ? "↳ " : "↳ ⚠ ") + model.text
                                    color: model.ok ? Kirigami.Theme.positiveTextColor
                                                    : Kirigami.Theme.negativeTextColor
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                }
                                PC3.Label {
                                    visible: isInbox
                                    text: "✉ " + model.text
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    wrapMode: Text.Wrap; Layout.fillWidth: true; opacity: 0.9
                                }
                                PC3.Label {
                                    visible: isUser || model.role === "manager" || isSystem
                                    text: model.text
                                    color: isUser ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                                    opacity: isSystem ? 0.6 : 1.0
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                }
            }

            PC3.Label {
                visible: root.lastError !== ""
                text: root.lastError; color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.Wrap; Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                PC3.TextField {
                    id: input
                    Layout.fillWidth: true
                    placeholderText: root.busy ? "Manager is working…" : "Message the PowOS manager…"
                    enabled: !root.busy
                    onAccepted: { var t = text; text = ""; root.send(t) }
                }
                PC3.Button {
                    text: "Send"; icon.name: "document-send-symbolic"
                    enabled: !root.busy && input.text.trim() !== ""
                    onClicked: { var t = input.text; input.text = ""; root.send(t) }
                }
            }
        }
    }

    // Clicking an agent drops a mention into the input so you can delegate to it.
    function selectAgentMention(name) {
        input.text = (input.text.trim() ? input.text.trim() + " " : "") +
                     "Ask the " + name + " agent to "
        input.forceActiveFocus()
    }
}
