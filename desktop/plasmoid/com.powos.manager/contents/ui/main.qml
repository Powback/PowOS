// PowOS Manager plasmoid — talk to the standing PowOS manager from the desktop.
//
// Two panes:
//   LEFT sidebar  — your projects (~/Projects/*, ● = has a live manager thread)
//                   and the agent roster (with unread-inbox badges). Picking a
//                   project switches the manager to THAT project's thread
//                   (per-directory memory: see lib/ai/manager/manager.py) AND
//                   reloads that project's saved chat transcript.
//   RIGHT chat    — the live conversation. Each turn runs
//                   `powos ai manager --json-events --once … | tee <tmp>`, and
//                   we POLL <tmp> so tool_use/tool_result/assistant events show
//                   up as they happen — Plasma's executable DataSource only
//                   delivers stdout once at process exit, so the file poll is
//                   what makes the output live. A final consume at completion is
//                   the safety net (worst case = everything at the end).
//
// Sidebar data comes from `powos ai manager --list-json` (one clean JSON blob),
// refreshed on a timer. All shell-outs go through the Plasma executable
// DataSource, like the other PowOS plasmoids.
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

    // Streaming-turn state
    property string tmpBase: "/tmp/powos-mgr"
    property int seq: 0
    property string turnFile: ""             // current turn's tee'd output file
    property int turnLine: 0                 // complete JSONL lines already consumed
    property bool turnDone: false            // process exited (final consume pending)
    property int turnEvents: 0               // renderable events seen this turn
    // Transcript load state
    property string pendingLoadName: "default"

    ListModel { id: chatModel }              // {role, text, name, ok}

    // Single-quote a string for safe use in a shell command.
    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    // base64 of a UTF-8 string (Qt.btoa alone mangles non-Latin1); pairs with `base64 -d`.
    function b64(s) { return Qt.btoa(unescape(encodeURIComponent(String(s)))) }
    // Filesystem-safe key for a project path (mirrors manager.py encode_cwd).
    function encodeKey(path) {
        if (!path) return "default"
        var k = String(path).replace(/\//g, "-").replace(/^-+/, "").replace(/[^A-Za-z0-9._-]/g, "_")
        return k || "default"
    }
    // Shell expressions (double-quoted so $HOME expands; key is sanitized safe).
    function transcriptDirExpr() { return "\"${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai/manager/transcripts\"" }
    function transcriptFileExpr(path) {
        return "\"${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai/manager/transcripts/" + encodeKey(path) + ".jsonl\""
    }

    // ── sidebar ────────────────────────────────────────────────────────────
    function refreshSidebar() { sidebarSource.connectSource(root.powos + " ai manager --list-json") }

    function applySidebar(text) {
        try {
            var d = JSON.parse(text)
            root.projects = d.projects || []
            root.agents = d.agents || []
        } catch (e) { /* transient — keep last good data */ }
    }

    // ── transcript persistence (per project) ─────────────────────────────────
    function saveTranscript() {
        var rows = []
        for (var i = 0; i < chatModel.count; i++) {
            var it = chatModel.get(i)
            if (it.role === "system") continue          // hints are not real history
            rows.push(JSON.stringify({ role: it.role, text: it.text, name: it.name, ok: it.ok }))
        }
        var content = rows.join("\n")
        var cmd = "mkdir -p " + transcriptDirExpr() + " && printf %s " + shellQuote(b64(content)) +
                  " | base64 -d > " + transcriptFileExpr(root.currentProject)
        ioSource.connectSource(cmd)
    }

    function loadTranscript(path, name) {
        root.pendingLoadName = name
        loadSource.connectSource("cat " + transcriptFileExpr(path) + " 2>/dev/null")
    }

    function applyTranscript(text) {
        chatModel.clear()
        var lines = String(text).split("\n")
        var any = false
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (!ln) continue
            try {
                var it = JSON.parse(ln)
                chatModel.append({ role: it.role, text: it.text || "",
                                   name: it.name || "", ok: it.ok === undefined ? true : it.ok })
                any = true
            } catch (e) { /* skip a corrupt line */ }
        }
        if (!any) {
            chatModel.append({ role: "system", name: "", ok: true,
                text: "Talking to the manager in " + root.pendingLoadName +
                      " — its thread here resumes. Say hello." })
        }
        chatView.positionViewAtEnd()
    }

    function selectProject(path, name) {
        if (root.currentProject === path) return
        if (root.busy) return                            // don't switch mid-turn
        saveTranscript()                                 // persist the project we're leaving
        root.currentProject = path
        root.currentProjectName = name
        loadTranscript(path, name)                       // repopulate from the target's transcript
    }

    // ── chat (streaming turn) ────────────────────────────────────────────────
    function send(text) {
        if (!text || !text.trim() || root.busy) return
        chatModel.append({ role: "user", text: text, name: "", ok: true })
        saveTranscript()
        root.busy = true
        root.lastError = ""
        root.seq += 1
        root.turnFile = root.tmpBase + "-" + root.seq + ".jsonl"
        root.turnLine = 0
        root.turnDone = false
        root.turnEvents = 0
        var cwd = root.currentProject ? (" --cwd " + shellQuote(root.currentProject)) : ""
        // Pipe the message in as base64 (no shell-escaping of the text needed),
        // and tee the event stream to a temp file we poll for live rendering.
        var cmd = "printf %s " + shellQuote(b64(text)) + " | base64 -d | " +
                  root.powos + " ai manager --json-events --once-stdin" + cwd +
                  " | tee " + shellQuote(root.turnFile)
        chatSource.connectSource(cmd)
        pollTimer.start()
    }

    // Consume any NEW complete JSONL lines from `text` (the growing file or the
    // final stdout). turnLine tracks how many complete lines we've rendered, so
    // the live poll and the completion consume never double-render.
    function consume(text) {
        var lines = String(text).split("\n")
        var complete = lines.length - 1              // last element is partial (or "")
        for (var i = root.turnLine; i < complete; i++) {
            var ln = lines[i].trim()
            if (!ln) continue
            var ev
            try { ev = JSON.parse(ln) } catch (e) { continue }
            appendEvent(ev)
        }
        if (complete > root.turnLine) root.turnLine = complete
        chatView.positionViewAtEnd()
    }

    function appendEvent(ev) {
        switch (ev.kind) {
        case "assistant":
            chatModel.append({ role: "manager", text: ev.text, name: "", ok: true }); root.turnEvents++; break
        case "tool_use":
            chatModel.append({ role: "tool_use", text: ev.hint || "", name: ev.name, ok: true }); root.turnEvents++; break
        case "tool_result":
            chatModel.append({ role: "tool_result", text: ev.text || "", name: "", ok: !!ev.ok }); root.turnEvents++; break
        case "inbox":
            chatModel.append({ role: "inbox", text: ev.text, name: "", ok: true }); root.turnEvents++; break
        // 'user' already shown; 'session'/'turn_done' are meta — ignore.
        }
    }

    function finalizeTurn(stderrText) {
        pollTimer.stop()
        root.busy = false
        // Only surface stderr as an error if the turn produced nothing at all —
        // otherwise it's just noise (e.g. a harmless agent-config warning).
        var err = String(stderrText || "").trim()
        root.lastError = (root.turnEvents === 0 && err) ? err : ""
        saveTranscript()
        if (root.turnFile) { ioSource.connectSource("rm -f " + shellQuote(root.turnFile)); root.turnFile = "" }
    }

    P5Support.DataSource {
        id: sidebarSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.applySidebar((d.stdout || "").trim()) }
    }
    // Runs the turn; its stdout (the tee) arrives once at process exit = the
    // completion signal + final consume + stderr.
    P5Support.DataSource {
        id: chatSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            root.turnDone = true
            root.consume(d.stdout || "")
            root.finalizeTurn(d.stderr || "")
        }
    }
    // Live poll of the growing tee file.
    P5Support.DataSource {
        id: pollSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.consume(d.stdout || "") }
    }
    // Transcript loads (per project).
    P5Support.DataSource {
        id: loadSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.applyTranscript(d.stdout || "") }
    }
    // Fire-and-forget writes/cleanup (saveTranscript, rm temp).
    P5Support.DataSource {
        id: ioSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s) }
    }

    Timer {
        id: pollTimer; interval: 250; repeat: true; running: false
        onTriggered: if (root.turnFile) pollSource.connectSource("cat " + root.shellQuote(root.turnFile) + " 2>/dev/null")
    }
    Timer { interval: 5000; running: true; repeat: true; onTriggered: root.refreshSidebar() }
    Component.onCompleted: { refreshSidebar(); loadTranscript(root.currentProject, root.currentProjectName) }

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
