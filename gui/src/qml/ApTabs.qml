// AnyPlay: вкладки у верхній смузі — великі літери, біле підкреслення 2 px під поточною.
// model: [{ id: "home", text: "Гра" }, …]; current — id поточної; activated(id) — натиснули вкладку.
import QtQuick

Row {
    id: tabs
    property var model: []
    property string current: ""
    property bool compact: false         // вузьке вікно: менші відступи
    signal activated(string id)
    AnyPlayStyle { id: ap }
    spacing: 2

    Repeater {
        model: tabs.model
        Item {
            id: tab
            required property var modelData
            readonly property bool on: tabs.current === modelData.id
            implicitWidth: label.implicitWidth + (tabs.compact ? 18 : 28)
            implicitHeight: label.implicitHeight + 20
            activeFocusOnTab: true
            Keys.onReturnPressed: tabs.activated(modelData.id)
            Keys.onSpacePressed: tabs.activated(modelData.id)
            Text {
                id: label
                anchors.centerIn: parent
                text: tab.modelData.text
                font.family: ap.display
                font.weight: Font.Medium
                font.pixelSize: tabs.compact ? 14 : 15
                font.letterSpacing: 1.6
                font.capitalization: Font.AllUppercase
                color: ap.ink
                opacity: tab.on || mouse.containsMouse || tab.activeFocus ? 1 : 0.62
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 2
                color: tab.activeFocus && !tab.on ? ap.cyan : ap.ink
                visible: tab.on || tab.activeFocus
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tabs.activated(tab.modelData.id)
            }
        }
    }
}
