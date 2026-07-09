// PowOS Containers plasmoid — start/stop/restart podman containers from the
// desktop. Polls `powos containers list --json` every 5s and shows every
// container (running AND stopped), so a stopped one never disappears — its
// Start button is right there. Actions run `powos containers <action> <name>`,
// which uses `podman <action>` (never rm), so containers persist.
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
    Layout.minimumHeight: Kirigami.Units.gridUnit * 10

    property string listCmd: "powos containers list --json"
    property bool busy: false

    ListModel { id: ctModel }

    function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function refresh() { lister.connectSource(root.listCmd) }

    function parseList(txt) {
        var arr
        try { arr = JSON.parse(txt) } catch (e) { return }
        if (!Array.isArray(arr)) return
        // Merge in place so we don't reset scroll/selection every 5s.
        for (var i = 0; i < arr.length; i++) {
            var c = arr[i]
            if (i < ctModel.count) {
                ctModel.set(i, { name: c.name || "", image: c.image || "",
                    state: c.state || "", status: c.status || "",
                    running: !!c.running, scope: c.scope || "user" })
            } else {
                ctModel.append({ name: c.name || "", image: c.image || "",
                    state: c.state || "", status: c.status || "",
                    running: !!c.running, scope: c.scope || "user" })
            }
        }
        while (ctModel.count > arr.length) ctModel.remove(ctModel.count - 1)
    }

    function runAction(name, action) {
        if (root.busy) return
        root.busy = true
        actor.connectSource("powos containers " + action + " " + root.shellQuote(name) + " >/dev/null 2>&1; echo done")
    }

    P5Support.DataSource {
        id: lister
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            root.parseList((data.stdout || "").trim())
        }
    }
    P5Support.DataSource {
        id: actor
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            root.busy = false
            root.refresh()
        }
    }

    Timer {
        interval: 5000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refresh()
    }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10
        Layout.preferredHeight: Kirigami.Units.gridUnit * 16

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
                PC3.ToolButton { icon.name: "view-refresh"; onClicked: root.refresh() }
            }

            PC3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: view
                    model: ctModel
                    clip: true
                    spacing: Kirigami.Units.smallSpacing

                    delegate: RowLayout {
                        width: view.width
                        spacing: Kirigami.Units.smallSpacing

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
                            PC3.Label {
                                text: model.name; elide: Text.ElideRight; Layout.fillWidth: true
                            }
                            PC3.Label {
                                text: model.status + (model.scope === "system" ? "  · system" : "")
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
                    }
                }
            }

            PC3.Label {
                visible: ctModel.count === 0
                text: "No containers found"
                opacity: 0.6
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
