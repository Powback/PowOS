import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// The first KDE (Kirigami) app on PowOS Linux/Wasm - the same components Plasma and KDE's apps are built from.
Kirigami.ApplicationWindow {
    id: root
    visible: true
    visibility: Window.FullScreen
    title: "PowOS"
    property int clicks: 0

    Component.onCompleted: console.log("KIRIGAMIHELLO READY")

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: "PowOS on Linux/Wasm"

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading { text: "KDE Kirigami, compiled to WebAssembly"; level: 1 }
            Controls.Label { text: "Running on the canvas - no emulation, no streaming."; wrapMode: Text.WordWrap }

            Kirigami.FormLayout {
                Layout.fillWidth: true
                Controls.TextField {
                    id: input
                    Kirigami.FormData.label: "Name:"
                    placeholderText: "Type here"
                    focus: true
                    onTextChanged: console.log("KIRIGAMIHELLO TEXT " + text)
                }
                Controls.Button {
                    text: "Click me"
                    onClicked: { root.clicks++; console.log("KIRIGAMIHELLO CLICKED " + root.clicks) }
                }
                Controls.Label {
                    Kirigami.FormData.label: "Status:"
                    text: root.clicks ? "Clicked " + root.clicks + " time(s)" : "Not clicked yet"
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: true
                type: Kirigami.MessageType.Positive
                text: "Kirigami components render with Qt Quick's software scene graph."
            }
        }
    }
}
