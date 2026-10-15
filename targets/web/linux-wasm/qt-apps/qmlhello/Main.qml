import QtQuick

// The first Qt Quick scene on PowOS Linux/Wasm. Logs through console.log - which Qt prints on stderr - with the
// QMLHELLO markers the browser test waits for.
Window {
    id: root
    visible: true
    visibility: Window.FullScreen
    color: "#1b1e24"
    property int clicks: 0

    Component.onCompleted: console.log("QMLHELLO READY")

    Rectangle {
        id: spinner
        width: 120; height: 120; radius: 24
        x: parent.width - width - 60; y: 60
        gradient: Gradient {
            GradientStop { position: 0; color: "#3daee9" }
            GradientStop { position: 1; color: "#9b59b6" }
        }
        RotationAnimation on rotation { from: 0; to: 360; duration: 3000; loops: Animation.Infinite }
    }

    Column {
        x: 60; y: 60; spacing: 24

        Text { text: "PowOS on Linux/Wasm"; color: "white"; font.pixelSize: 48; font.bold: true }
        Text { text: "Qt Quick (QML), compiled to WebAssembly, on the canvas"; color: "#b0b8c4"; font.pixelSize: 22 }

        Rectangle {
            width: 520; height: 52; radius: 8; color: "#2a2e36"; border.color: input.activeFocus ? "#3daee9" : "#444b57"
            TextInput {
                id: input
                anchors.fill: parent; anchors.margins: 12
                color: "white"; font.pixelSize: 22; focus: true
                onTextChanged: console.log("QMLHELLO TEXT " + text)
            }
        }

        Rectangle {
            width: 520; height: 64; radius: 8
            color: area.pressed ? "#2a8bc0" : (area.containsMouse ? "#4cbaf2" : "#3daee9")
            Text { anchors.centerIn: parent; text: "Click me"; color: "white"; font.pixelSize: 24 }
            MouseArea {
                id: area
                anchors.fill: parent; hoverEnabled: true
                onClicked: { root.clicks++; console.log("QMLHELLO CLICKED " + root.clicks) }
            }
        }

        Text { text: root.clicks ? "Clicked " + root.clicks + " time(s)" : "Not clicked yet"; color: "#b0b8c4"; font.pixelSize: 22 }
    }
}
