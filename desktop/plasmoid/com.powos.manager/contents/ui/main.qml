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
    property bool turnFinalized: false       // finalizeTurn already ran for this turn
    property int turnEvents: 0               // renderable events seen this turn
    property var queue: []                   // [{text, project, name}] typed while a turn is in flight
    // The project the IN-FLIGHT turn belongs to. Not always the one on screen:
    // you can switch chats mid-answer, and the turn keeps running in the
    // background with its output going to its own transcript.
    property string turnProject: ""
    property string turnProjectName: ""
    readonly property bool busyHere: root.busy && root.turnProject === root.currentProject
    // Transcript load state
    property string pendingLoadName: "default"
    property string pendingLoadPath: ""

    // Rows: {role, text, name, ok, group, count, open}
    //   group — 0 = standalone. Non-zero ties a "tool_group" header row to the
    //           tool_use/tool_result rows it folds up.
    //   count — number of folded rows (header only).
    //   open  — expansion state, mirrored onto EVERY row of the group so a
    //           setProperty on it notifies each delegate. A plain JS map on root
    //           would not: mutating a `property var` emits no change signal, so
    //           the rows would never re-evaluate their visibility.
    // Every append MUST carry all seven: ListModel locks its roles to the shape
    // of the first row appended and silently drops unknown keys afterwards.
    ListModel { id: chatModel }
    property int groupSeq: 0

    function pushRow(role, text, name, ok) {
        chatModel.append({ role: role, text: text || "", name: name || "",
                           ok: ok === undefined ? true : ok,
                           group: 0, count: 0, open: false })
    }

    // Fold the run of tool rows sitting at the end of the model into one
    // collapsible header. Called when the manager speaks (the chain produced its
    // answer) and again at finalizeTurn for a turn that ends on tool calls.
    // While the chain is still running the rows stay individually visible —
    // that live feedback is the point of streaming them.
    function closeToolRun() {
        var end = chatModel.count
        var i = end - 1
        while (i >= 0) {
            var r = chatModel.get(i).role
            if (r !== "tool_use" && r !== "tool_result") break
            i--
        }
        var start = i + 1
        var n = end - start
        if (n < 2) return              // a lone tool call reads fine as-is
        root.groupSeq += 1
        var gid = root.groupSeq
        var names = [], seen = {}
        for (var j = start; j < end; j++) {
            var row = chatModel.get(j)
            if (row.role === "tool_use" && row.name && !seen[row.name]) {
                seen[row.name] = true; names.push(row.name)
            }
            chatModel.setProperty(j, "group", gid)
            chatModel.setProperty(j, "open", false)
        }
        var summary = names.slice(0, 4).join(", ") + (names.length > 4 ? ", …" : "")
        chatModel.insert(start, { role: "tool_group", text: summary, name: "",
                                  ok: true, group: gid, count: n, open: false })
    }

    function toggleGroup(gid) {
        var want = null
        for (var i = 0; i < chatModel.count; i++) {
            var it = chatModel.get(i)
            if (it.group !== gid) continue
            if (want === null) want = !it.open
            chatModel.setProperty(i, "open", want)
        }
    }

    // Single-quote a string for safe use in a shell command.
    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    // base64 of a UTF-8 string (Qt.btoa alone mangles non-Latin1); pairs with `base64 -d`.
    function b64(s) { return Qt.btoa(unescape(encodeURIComponent(String(s)))) }
    // …and back. EVERY read path below pipes its output through `base64 -w0` and
    // decodes here, because Plasma's executable DataSource hands stdout back
    // already decoded with the wrong codec: a UTF-8 em-dash arrives as "â\u0080\u0094",
    // which we then re-encode on save. Each save/load cycle stacks another layer
    // (the live transcripts here had reached FOUR: "ÃÂÃÂ¢ÃÂ"), so it looks
    // like the mojibake breeds. Base64 is pure ASCII — no codec can touch it.
    function unb64(s) {
        var t = String(s || "").replace(/\s+/g, "")
        if (!t) return ""
        try { return decodeURIComponent(escape(Qt.atob(t))) } catch (e) { return Qt.atob(t) }
    }
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
    function refreshSidebar() { sidebarSource.connectSource(root.powos + " ai manager --list-json | base64 -w0") }

    function applySidebar(text) {
        try {
            var d = JSON.parse(text)
            root.projects = d.projects || []
            root.agents = d.agents || []
        } catch (e) { /* transient — keep last good data */ }
    }

    // ── transcript persistence (per project) ─────────────────────────────────
    // WHICH project the rows currently in chatModel belong to. Empty = limbo: a
    // load is in flight, the model is about to be replaced and does NOT
    // represent anybody. This one property is what stops the model and the files
    // from cross-contaminating when you switch back and forth quickly:
    // saveCmd refuses to write a model it doesn't own, so a half-switched model
    // can never be flushed over a healthy transcript. That is how whole
    // exchanges were disappearing — not hidden, actually overwritten on disk.
    property string modelProject: ""
    property var pendingLoads: ({})   // load command -> {path, name}
    property int loadSeq: 0

    // Returns the write as a shell command instead of running it, so a caller
    // that must not race it (selectProject) can chain it ahead of the read in
    // ONE shell. Two DataSources are two processes with no ordering between
    // them, and the `cat` regularly won — you switched project and came back to
    // a transcript saved before your last message.
    function saveCmd(path) {
        var target = path === undefined ? root.currentProject : path
        // Only ever persist a model we own. Mid-switch (or before the first load
        // lands) the rows on screen belong to someone else, or to nobody.
        if (root.modelProject !== target) return ""
        var rows = []
        for (var i = 0; i < chatModel.count; i++) {
            var it = chatModel.get(i)
            if (it.role === "system") continue          // hints are not real history
            rows.push(JSON.stringify({ role: it.role, text: it.text, name: it.name, ok: it.ok,
                                       group: it.group, count: it.count, open: it.open }))
        }
        var content = rows.join("\n")
        return "mkdir -p " + transcriptDirExpr() + " && printf %s " + shellQuote(b64(content)) +
               " | base64 -d > " + transcriptFileExpr(target)
    }

    function saveTranscript() { var c = saveCmd(); if (c) ioSource.connectSource(c) }

    // Rows produced by a turn whose chat is not on screen. Held in memory, never
    // written incrementally: saveTranscript rewrites a transcript wholesale from
    // the model, so a second writer appending to the same file would be silently
    // truncated by the next save. One writer per file, always — these flush in a
    // single append when the turn ends, or fold into the model if you come back
    // to that chat first.
    property var bgRows: []

    function flushBg(path) {
        if (root.bgRows.length === 0) return
        var lines = [], keep = []
        for (var i = 0; i < root.bgRows.length; i++) {
            var r = root.bgRows[i]
            if (r.path !== path) { keep.push(r); continue }   // someone else's buffer
            lines.push(JSON.stringify({ role: r.role, text: r.text, name: r.name, ok: r.ok,
                                        group: r.group, count: r.count, open: r.open }))
        }
        root.bgRows = keep
        if (lines.length === 0) return
        ioSource.connectSource("mkdir -p " + transcriptDirExpr() + " && printf %s " +
                               shellQuote(b64(lines.join("\n") + "\n")) +
                               " | base64 -d >> " + transcriptFileExpr(path))
    }

    // Route a turn's row to wherever that turn's chat currently lives.
    function emitRow(role, text, name, ok) {
        if (root.turnProject === root.currentProject &&
            root.modelProject === root.currentProject) { pushRow(role, text, name, ok); return }
        root.bgRows.push({ path: root.turnProject, role: role, text: text || "", name: name || "",
                           ok: ok === undefined ? true : ok,
                           group: 0, count: 0, open: false })
    }

    function loadTranscript(path, name, pre) {
        root.pendingLoadName = name
        root.pendingLoadPath = path
        root.modelProject = ""                           // limbo until this lands
        // `pre` (a saveCmd) runs first in the SAME shell — sequential, so the
        // read can never overtake the write it depends on. The trailing `#` is a
        // shell comment that just makes every command string unique, so two
        // loads of the same project are two distinct DataSource sources and the
        // engine can't collapse them into one.
        root.loadSeq += 1
        var cmd = (pre ? "{ " + pre + " ; } >/dev/null 2>&1 ; " : "") +
                  "base64 -w0 " + transcriptFileExpr(path) + " 2>/dev/null  # " + root.loadSeq
        root.pendingLoads[cmd] = { path: path, name: name }
        loadSource.connectSource(cmd)
    }

    function applyTranscript(text) {
        chatModel.clear()
        root.groupSeq = 0
        var lines = String(text).split("\n")
        var any = false
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim()
            if (!ln) continue
            try {
                var it = JSON.parse(ln)
                chatModel.append({ role: it.role, text: it.text || "",
                                   name: it.name || "", ok: it.ok === undefined ? true : it.ok,
                                   group: it.group || 0, count: it.count || 0, open: !!it.open })
                // Keep the counter above every restored id, or the next fold
                // would reuse one and toggle two unrelated groups at once.
                if ((it.group || 0) > root.groupSeq) root.groupSeq = it.group
                any = true
            } catch (e) { /* skip a corrupt line */ }
        }
        // Walked back into a chat that is still being answered: the rows buffered
        // while you were away belong at the end of it.
        // Rows buffered for THIS project while it wasn't on screen (a turn that
        // kept answering, or something you typed during the switch) belong at the
        // end of it. Keyed by path — matching on turnProject alone dropped
        // anything buffered for a project that wasn't the one answering.
        var restBg = [], mine = []
        for (var b = 0; b < root.bgRows.length; b++) {
            if (root.bgRows[b].path === root.pendingLoadPath) mine.push(root.bgRows[b])
            else restBg.push(root.bgRows[b])
        }
        if (mine.length > 0) {
            for (var m = 0; m < mine.length; m++) {
                var r = mine[m]
                chatModel.append({ role: r.role, text: r.text, name: r.name, ok: r.ok,
                                   group: 0, count: 0, open: false })
            }
            root.bgRows = restBg
            any = true
        }
        if (!any) {
            pushRow("system",
                "Talking to the manager in " + root.pendingLoadName +
                " — its thread here resumes. Say hello.", "", true)
        }
        root.modelProject = root.pendingLoadPath          // the model is this project's again
        if (mine.length > 0) saveTranscript()             // fold the buffered rows into the file
        // Scrolling is the ListView's own job — see `onCountChanged` on chatView.
        // Reaching for `chatView` from here throws ReferenceError: this function
        // lives on PlasmoidItem, while chatView is inside fullRepresentation,
        // which is a Component and therefore a separate QML context (and is not
        // instantiated at all until the popup first opens).
    }

    // Markdown-ify for display: CommonMark folds a single newline into a space,
    // which turns a multi-line answer into one paragraph. Every chat UI breaks
    // on newline instead, so append the two-space hard break to each line —
    // skipping fenced code blocks, where newlines are already literal.
    function mdBreaks(t) {
        var lines = String(t || "").split("\n")
        var fenced = false
        for (var i = 0; i < lines.length; i++) {
            if (/^\s*(```|~~~)/.test(lines[i])) { fenced = !fenced; continue }
            if (fenced || lines[i].trim() === "") continue
            lines[i] = lines[i].replace(/\s+$/, "") + "  "
        }
        return lines.join("\n")
    }

    function selectProject(path, name) {
        if (root.currentProject === path) return
        // Switching mid-turn is fine. The running turn is NOT cancelled and NOT
        // blocked — it belongs to root.turnProject, and while that isn't the
        // project on screen its rows are appended straight to that project's
        // transcript (appendBg) instead of into the visible model. Come back and
        // loadTranscript replays them; if it's still running, live rows resume.
        var pre = saveCmd()                              // persist the project we're leaving…
        root.currentProject = path
        root.currentProjectName = name
        loadTranscript(path, name, pre)                  // …then repopulate, in that order
    }

    // ── chat (streaming turn) ────────────────────────────────────────────────
    // Typing is NEVER blocked. A message sent while a turn is in flight is shown
    // immediately and queued; the queue drains in finalizeTurn. Turns can't be
    // overlapped for real — they share one manager session per cwd — so this
    // queues rather than spawning a second `--once-stdin`.
    property int sendTick: 0     // bumped on send → chatView jumps to the bottom

    function send(text) {
        if (!text || !text.trim()) return
        // Mid-switch the model belongs to nobody and is about to be cleared by
        // the load in flight — buffer instead, and applyTranscript folds it in.
        if (root.modelProject === root.currentProject) {
            pushRow("user", text, "", true)
            root.sendTick++
            saveTranscript()
        } else {
            root.bgRows.push({ path: root.currentProject, role: "user", text: text,
                               name: "", ok: true, group: 0, count: 0, open: false })
        }
        // Queue entries remember which chat they were typed in, so a message
        // typed here still runs against THIS project's manager session even if
        // you have wandered off to another chat before it gets its turn.
        root.queue.push({ text: text, project: root.currentProject, name: root.currentProjectName })
        pumpQueue()
    }

    function pumpQueue() {
        if (root.busy || root.queue.length === 0) return
        var it = root.queue.shift()
        startTurn(it.text, it.project, it.name)
    }

    function startTurn(text, project, name) {
        root.turnProject = project === undefined ? root.currentProject : project
        root.turnProjectName = name === undefined ? root.currentProjectName : name
        root.busy = true
        root.turnFinalized = false
        root.lastError = ""
        root.seq += 1
        root.turnFile = root.tmpBase + "-" + root.seq + ".jsonl"
        root.turnLine = 0
        root.turnEvents = 0
        var cwd = root.turnProject ? (" --cwd " + shellQuote(root.turnProject)) : ""
        // Pipe the message in as base64 (no shell-escaping of the text needed),
        // and tee the event stream to a temp file we poll for live rendering.
        var cmd = "printf %s " + shellQuote(b64(text)) + " | base64 -d | " +
                  root.powos + " ai manager --json-events --once-stdin" + cwd +
                  " | tee " + shellQuote(root.turnFile) + " | base64 -w0"
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
        // Auto-scroll handled by chatView.onCountChanged (see above).
    }

    function appendEvent(ev) {
        switch (ev.kind) {
        case "assistant":
            // The chain that led here is finished — fold it before the answer.
            // Only meaningful for the visible model; a background turn's rows go
            // to disk unfolded (folding them would fold whatever chat is on
            // screen instead, which belongs to a different project entirely).
            if (root.turnProject === root.currentProject) closeToolRun()
            emitRow("manager", ev.text, "", true); root.turnEvents++; saveTimer.restart(); break
        case "tool_use":
            emitRow("tool_use", ev.hint || "", ev.name, true); root.turnEvents++; saveTimer.restart(); break
        case "tool_result":
            emitRow("tool_result", ev.text || "", "", !!ev.ok); root.turnEvents++; saveTimer.restart(); break
        case "inbox":
            emitRow("inbox", ev.text, "", true); root.turnEvents++; saveTimer.restart(); break
        case "turn_done":
            // THE completion signal. The backend emits this as its last line, so
            // the 250ms poller sees it even if the process-exit callback on
            // chatSource never arrives (popup closed mid-turn, plasmashell
            // dropping a long-lived source, …). Relying on process exit alone
            // left `busy` stuck on forever AND skipped the finalizeTurn save,
            // which is why assistant replies vanished on reload while the user's
            // own messages — saved eagerly in send() — survived.
            finalizeTurn("")
            break
        // 'user' already shown; 'session' is meta — ignore.
        }
    }

    // Idempotent: reachable from the turn_done event and from process exit,
    // whichever lands first.
    function finalizeTurn(stderrText) {
        if (root.turnFinalized) return
        root.turnFinalized = true
        pollTimer.stop()
        root.busy = false
        if (root.turnProject === root.currentProject) closeToolRun()  // turn ended on tool calls
        // Only surface stderr as an error if the turn produced nothing at all —
        // otherwise it's just noise (e.g. a harmless agent-config warning).
        var err = String(stderrText || "").trim()
        root.lastError = (root.turnEvents === 0 && err) ? err : ""
        saveTranscript()                                  // the chat on screen
        flushBg(root.turnProject)                         // …and the one that was answering
        if (root.turnFile) { ioSource.connectSource("rm -f " + shellQuote(root.turnFile)); root.turnFile = "" }
        // Deferred, NOT a direct pumpQueue(): finalizeTurn is reached from
        // inside consume()'s loop (turn_done is the last line it parses), and
        // starting the next turn there would reset turnLine to 0 mid-loop, only
        // for consume's trailing `turnLine = complete` to clobber it with the
        // OLD file's line count — silently swallowing the next turn's first
        // events. Let the stack unwind first.
        queueTimer.restart()
    }

    P5Support.DataSource {
        id: sidebarSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s); root.applySidebar(root.unb64(d.stdout).trim()) }
    }
    // Runs the turn; its stdout (the tee) arrives once at process exit = the
    // completion signal + final consume + stderr.
    P5Support.DataSource {
        id: chatSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            // Stale-turn guard. turn_done (seen by the 250ms poller) can finalize
            // a turn BEFORE this process-exit callback is delivered, and the 0ms
            // queueTimer then starts the next queued turn in between. Without this
            // check the late callback would consume turn N's stdout against turn
            // N+1's turnLine (re-rendering everything), then finalizeTurn would
            // tear down the turn now in flight — pollTimer stopped, tee file
            // deleted, busy cleared. The queued message went out and simply never
            // came back, which reads exactly like "queueing doesn't work".
            if (!root.turnFile || s.indexOf(root.turnFile) === -1) return
            root.consume(root.unb64(d.stdout))
            root.finalizeTurn(d.stderr || "")
        }
    }
    // Live poll of the growing tee file.
    P5Support.DataSource {
        id: pollSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            // Same guard: a cat issued for the previous turn can land after the
            // next one started, replaying old lines into the new turn.
            if (!root.turnFile || s.indexOf(root.turnFile) === -1) return
            root.consume(root.unb64(d.stdout))
        }
    }
    // Transcript loads (per project).
    P5Support.DataSource {
        id: loadSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) {
            disconnectSource(s)
            var w = root.pendingLoads[s]
            delete root.pendingLoads[s]
            // A load for a project you have already left. Applying it would
            // wipe the chat you are looking at and — via the debounced save —
            // write the wrong project's history into its file.
            if (!w || w.path !== root.currentProject) return
            root.pendingLoadPath = w.path
            root.pendingLoadName = w.name
            root.applyTranscript(root.unb64(d.stdout))
        }
    }
    // Fire-and-forget writes/cleanup (saveTranscript, rm temp).
    P5Support.DataSource {
        id: ioSource; engine: "executable"; connectedSources: []
        onNewData: function (s, d) { disconnectSource(s) }
    }

    // Debounced transcript write. Every rendered event restarts it, so history
    // is on disk within a second even if the turn never finalizes cleanly (popup
    // closed mid-turn, widget reloaded, backend killed). finalizeTurn still
    // saves synchronously; this is the belt to that pair of braces.
    Timer {
        id: saveTimer; interval: 700; repeat: false; running: false
        onTriggered: root.saveTranscript()
    }
    // Starts the next queued turn once the current call stack has unwound.
    Timer {
        id: queueTimer; interval: 0; repeat: false; running: false
        onTriggered: root.pumpQueue()
    }
    Timer {
        id: pollTimer; interval: 250; repeat: true; running: false
        onTriggered: if (root.turnFile) pollSource.connectSource("base64 -w0 " + root.shellQuote(root.turnFile) + " 2>/dev/null")
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
                                // A turn still running for a chat you are not
                                // looking at — otherwise it would answer silently.
                                PC3.BusyIndicator {
                                    visible: root.busy && root.turnProject === modelData.path
                                    running: visible
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
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
                PC3.BusyIndicator { running: root.busyHere; visible: root.busyHere
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
                    // Own the auto-scroll here rather than having callers poke
                    // chatView.positionViewAtEnd(): those callers live on
                    // PlasmoidItem, outside this Component's scope, so the id
                    // was never resolvable and every append threw a silent
                    // ReferenceError — leaving the newest message off-screen.
                    // Reacting to the model instead works for every producer,
                    // and cannot run before the view exists.
                    // Following the bottom needs BOTH triggers. onCountChanged
                    // alone positions against heights that are still settling:
                    // a long tool_result wraps to its real height AFTER the
                    // position is computed, so every append leaves the view a
                    // little short of the true bottom and the drift accumulates
                    // until the newest message — including one you just sent —
                    // is off-screen below. Folding a chain moves the bottom the
                    // other way (rows collapse to height 0) with no count change
                    // at all. Re-positioning on contentHeight catches both.
                    property bool stickToEnd: true
                    onCountChanged: if (stickToEnd) Qt.callLater(positionViewAtEnd)
                    onContentHeightChanged: if (stickToEnd) Qt.callLater(positionViewAtEnd)
                    Component.onCompleted: Qt.callLater(positionViewAtEnd)
                    // Scrolling up to read means stop following; coming back to
                    // the bottom resumes it. Only the user's own movement flips
                    // this, never an append.
                    onMovementEnded: stickToEnd = atYEnd
                    onFlickEnded: stickToEnd = atYEnd
                    // Sending always yanks you to the bottom — you wrote it, you
                    // want to see it land. root.sendTick is the only way to reach
                    // in: send() lives on PlasmoidItem, outside this Component's
                    // scope, so it cannot touch chatView by id.
                    Connections {
                        target: root
                        function onSendTickChanged() {
                            chatView.stickToEnd = true
                            Qt.callLater(chatView.positionViewAtEnd)
                        }
                    }
                    delegate: Item {
                        width: ListView.view.width
                        // A folded member contributes NO height — setting only
                        // `visible` would leave the ListView reserving its row.
                        visible: model.group === 0 || model.role === "tool_group" || model.open
                        implicitHeight: visible ? bubble.implicitHeight + Kirigami.Units.smallSpacing : 0
                        height: implicitHeight

                        // colors / alignment per role
                        property bool isUser: model.role === "user"
                        property bool isTool: model.role === "tool_use" || model.role === "tool_result"
                        property bool isGroup: model.role === "tool_group"
                        property bool isInbox: model.role === "inbox"
                        property bool isSystem: model.role === "system"

                        Rectangle {
                            id: bubble
                            anchors.right: isUser ? parent.right : undefined
                            anchors.left: isUser ? undefined : parent.left
                            anchors.rightMargin: Kirigami.Units.smallSpacing
                            anchors.leftMargin: Kirigami.Units.smallSpacing
                            width: Math.min(parent.width * (isTool || isGroup || isInbox || isSystem ? 0.98 : 0.82),
                                            content.implicitWidth + Kirigami.Units.largeSpacing)
                            implicitHeight: content.implicitHeight + Kirigami.Units.smallSpacing * 2
                            radius: Kirigami.Units.smallSpacing
                            color: {
                                if (isUser) return Kirigami.Theme.highlightColor
                                if (isGroup) return Qt.rgba(0.8, 0.6, 0, 0.10)
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
                                // Collapsed-chain header. Click anywhere on it
                                // to fold/unfold every step it stands for.
                                PC3.Label {
                                    visible: isGroup
                                    text: (model.open ? "▾ " : "▸ ") + "⚙ " + model.count
                                          + " tool step" + (model.count === 1 ? "" : "s")
                                          + (model.text ? "  ·  " + model.text : "")
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    opacity: 0.75
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                }
                                // SelectableLabel, not Label: Label is a Text and
                                // Text has no selection at all. This is a chat —
                                // commands, paths and error strings are meant to
                                // be copied out. Right-click gives Copy; drag
                                // selects; the wheel still scrolls the list.
                                Kirigami.SelectableLabel {
                                    visible: model.role === "tool_use"
                                    text: "⚙ " + (model.name || "") + (model.text ? "  " + model.text : "")
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                }
                                Kirigami.SelectableLabel {
                                    visible: model.role === "tool_result"
                                    text: (model.ok ? "↳ " : "↳ ⚠ ") + model.text
                                    color: model.ok ? Kirigami.Theme.positiveTextColor
                                                    : Kirigami.Theme.negativeTextColor
                                    font.family: "monospace"
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                }
                                Kirigami.SelectableLabel {
                                    visible: isInbox
                                    text: "✉ " + model.text
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap; Layout.fillWidth: true; opacity: 0.9
                                }
                                Kirigami.SelectableLabel {
                                    visible: isUser || model.role === "manager" || isSystem
                                    text: model.role === "manager" ? root.mdBreaks(model.text) : model.text
                                    color: isUser ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                                    opacity: isSystem ? 0.6 : 1.0
                                    wrapMode: Text.Wrap; Layout.fillWidth: true
                                    // The manager writes markdown; render it. What you
                                    // typed stays literal — PlainText — so a stray
                                    // `*` or `_` in your own message is never eaten.
                                    textFormat: model.role === "manager" ? Text.MarkdownText
                                                                         : Text.PlainText
                                    onLinkActivated: function (l) { Qt.openUrlExternally(l) }
                                }
                            }

                            // TapHandler, not a MouseArea: a MouseArea filling
                            // every bubble would swallow wheel events and kill
                            // scrolling in the chat list.
                            TapHandler {
                                enabled: isGroup
                                onTapped: root.toggleGroup(model.group)
                            }
                            HoverHandler {
                                enabled: isGroup
                                cursorShape: Qt.PointingHandCursor
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
                    // Never disabled: you can always type, and a message sent
                    // mid-turn queues instead of being swallowed.
                    placeholderText: root.busyHere ? "Manager is working — type ahead…"
                                  : root.busy ? "Answering in " + root.turnProjectName + " — type ahead…"
                                              : "Message the PowOS manager…"
                    onAccepted: { var t = text; text = ""; root.send(t) }
                }
                PC3.Button {
                    text: "Send"; icon.name: "document-send-symbolic"
                    enabled: input.text.trim() !== ""
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
