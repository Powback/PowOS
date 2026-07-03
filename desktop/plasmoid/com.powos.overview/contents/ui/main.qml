// PowOS Overview plasmoid — renders `powos overview --json` + `powos services --json`
// as a desktop panel. Polls every 30s via the executable dataengine; read-only.
// Falls back to sourcing ~/PowOS/lib when the installed powos predates `overview`.
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
    Layout.minimumHeight: Kirigami.Units.gridUnit * 14

    // ── state ────────────────────────────────────────────────────
    property var ov: ({})        // overview json
    property var svc: ({})       // services json
    property string err: ""

    readonly property string dataCmd:
        "if powos overview --json >/dev/null 2>&1; then " +
        "  powos overview --json; echo __POWOS_SEP__; powos services --json; " +
        "else " +
        "  source \"$HOME/PowOS/lib/overview.sh\" 2>/dev/null; " +
        "  source \"$HOME/PowOS/lib/services.sh\" 2>/dev/null; " +
        "  ov_json; echo __POWOS_SEP__; svc_json; " +
        "fi"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            disconnectSource(source)
            try {
                var parts = (data.stdout || "").split("__POWOS_SEP__")
                root.ov  = JSON.parse(parts[0])
                root.svc = parts.length > 1 ? JSON.parse(parts[1]) : {}
                root.err = ""
            } catch (e) {
                root.err = "no data (is ~/PowOS or powos overview available?)"
            }
        }
    }
    Timer {
        interval: 30000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: exec.connectSource(root.dataCmd)
    }

    // ── helpers ──────────────────────────────────────────────────
    function field(o, k, dflt) { return (o && o[k] !== undefined && o[k] !== null && o[k] !== "") ? o[k] : (dflt || "—") }

    fullRepresentation: Item {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2

        ColumnLayout {
            id: content
            anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
            spacing: Kirigami.Units.smallSpacing

            // header
            RowLayout {
                Kirigami.Icon { source: "computer-symbolic"; Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium; Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium }
                Kirigami.Heading { level: 3; text: "PowOS"; Layout.fillWidth: true }
                PC3.Label { text: field(root.ov, "driver_channel"); color: Kirigami.Theme.positiveTextColor; font.bold: true }
            }
            PC3.Label {
                visible: root.err !== ""
                text: root.err; color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap; Layout.fillWidth: true
            }

            // base image
            PC3.Label {
                text: field(root.ov, "base_image") + "  (" + field(root.ov, "version") + ")"
                elide: Text.ElideMiddle; opacity: 0.8; font.pointSize: Kirigami.Theme.smallFont.pointSize
                Layout.fillWidth: true
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // GPU block
            RowLayout {
                Kirigami.Icon { source: "show-gpu-effects-symbolic"; Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: Kirigami.Units.iconSizes.small }
                ColumnLayout {
                    spacing: 0; Layout.fillWidth: true
                    PC3.Label { text: field(root.ov, "gpu"); font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                    PC3.Label {
                        text: "driver " + field(root.ov, "driver") + " · CUDA " + field(root.ov, "cuda_runtime")
                              + " · toolkit " + field(root.ov, "cuda_toolkit")
                        opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    PC3.Label {
                        readonly property var g: root.svc && root.svc.gpu ? root.svc.gpu : null
                        visible: g !== null && g.mem_used !== undefined
                        text: g ? ("vram " + g.mem_used + " / " + g.mem_total + " · util " + g.util) : ""
                        opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // deployments + storage
            GridLayout {
                columns: 2; columnSpacing: Kirigami.Units.largeSpacing; Layout.fillWidth: true
                PC3.Label { text: "Deployments"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "deployments") + "  (incl. rollback)" }
                PC3.Label { text: "Storage"; opacity: 0.6 }
                PC3.Label { text: field(root.ov, "var_usage"); elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // containers
            PC3.Label {
                readonly property int n: root.svc && root.svc.containers ? root.svc.containers.length : 0
                text: "Containers (" + n + ")"; opacity: 0.6
            }
            Repeater {
                model: root.svc && root.svc.containers ? root.svc.containers : []
                delegate: RowLayout {
                    Layout.fillWidth: true
                    Rectangle {
                        width: Kirigami.Units.smallSpacing * 2; height: width; radius: width / 2
                        color: Kirigami.Theme.positiveTextColor
                    }
                    PC3.Label { text: modelData.name; font.bold: true }
                    PC3.Label {
                        text: (modelData.gpu ? "gpu · " : "") + modelData.status
                        opacity: 0.7; font.pointSize: Kirigami.Theme.smallFont.pointSize
                        elide: Text.ElideRight; Layout.fillWidth: true
                    }
                }
            }
            PC3.Label {
                visible: !root.svc || !root.svc.containers || root.svc.containers.length === 0
                text: "none running"; opacity: 0.5
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
            Item { Layout.fillHeight: true }
        }
    }
}
