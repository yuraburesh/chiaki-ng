import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    property var consoleIndex
    title: qsTr("Задати PIN консолі")
    buttonText: qsTr("Задати")
    buttonEnabled: pin.acceptableInput
    onAccepted: {
        Chiaki.setConsolePin(consoleIndex, pin.text.trim());
        stack.pop();
    }
    Item {
        GridLayout {
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 20
            }
            columns: 2
            rowSpacing: 10
            columnSpacing: 20
                        Label {
                            Layout.alignment: Qt.AlignRight
                            text: qsTr("PIN Remote Play (4 цифри):")
                        }

                        TextField {
                            id: pin
                            validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
                            echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                            Layout.preferredWidth: 400
                        }
        }

    }
}