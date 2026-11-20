// AnyPlay: спосіб оплати — кнопка з назвою і сірим підписом під нею («З балансу» / «Переказом»).
// Обраний — світла рамка й підкладка; недоступний — блідий.
import QtQuick
import QtQuick.Controls

AbstractButton {
    id: m
    property string sub: ""
    AnyPlayStyle { id: ap }

    checkable: false            // обраний стан задає панель через checked
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    leftPadding: 10; rightPadding: 10
    topPadding: 9; bottomPadding: 9
    implicitWidth: 160
    implicitHeight: col.implicitHeight + topPadding + bottomPadding
    opacity: enabled ? 1 : 0.45
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    contentItem: Column {
        id: col
        spacing: 2
        Text {
            width: parent.width
            text: m.text
            wrapMode: Text.WordWrap
            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
            color: ap.ink
        }
        Text {
            visible: m.sub !== ""
            width: parent.width
            text: m.sub
            wrapMode: Text.WordWrap
            font.family: ap.body; font.pixelSize: 11
            color: m.checked ? ap.mute : ap.faint
        }
    }
    background: Rectangle {
        radius: ap.radius
        color: m.checked ? "#1fffffff" : (m.hovered && m.enabled ? "#14ffffff" : "#0affffff")
        border.width: m.visualFocus ? 2 : 1
        border.color: m.visualFocus ? ap.cyan : (m.checked || (m.hovered && m.enabled) ? ap.ink : ap.edge)
    }
}
