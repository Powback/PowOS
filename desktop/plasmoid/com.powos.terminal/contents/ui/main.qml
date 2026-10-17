// PowOS Terminal - a terminal on the desktop, running PowOS's terminal command (powos-tmux-shell): the same tmux
// sessions as Konsole, SSH and the phone launcher's terminal tile, so one session can be open in all of them at once
// (tmux shares it between clients). The picker lists them most recent first; Esc gives a plain shell.
//
// Needs QMLTermWidget (qmltermwidget: the terminal component of cool-retro-term).
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami
import QMLTermWidget

PlasmoidItem {
    id: root

    preferredRepresentation: fullRepresentation
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.minimumHeight: Kirigami.Units.gridUnit * 10
    Layout.preferredWidth: Kirigami.Units.gridUnit * 28
    Layout.preferredHeight: Kirigami.Units.gridUnit * 18

    fullRepresentation: Item {
        QMLTermWidget {
            id: terminal

            anchors.fill: parent
            font.family: Kirigami.Theme.fixedWidthFont.family
            font.pointSize: Kirigami.Theme.fixedWidthFont.pointSize
            colorScheme: "BreezeModified"

            session: QMLTermSession {
                id: session
                initialWorkingDirectory: "$HOME"
                shellProgram: "/usr/lib/powos/powos-tmux-shell"
                // A finished session (detached, shell exited) starts again: the widget always has a terminal.
                onFinished: Qt.callLater(session.startShellProgram)
            }

            Component.onCompleted: {
                session.startShellProgram();
                terminal.forceActiveFocus();
            }

            QMLTermScrollbar {
                terminal: terminal
                width: Kirigami.Units.smallSpacing * 2
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Kirigami.Theme.textColor
                    opacity: 0.4
                }
            }

            // A tap gives it the keyboard (on the phone: the Android keyboard comes up for it).
            TapHandler {
                onTapped: terminal.forceActiveFocus()
            }
        }
    }
}
