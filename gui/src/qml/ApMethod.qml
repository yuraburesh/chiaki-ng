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
    leftPadding: 14; rightPadding: 14
    topPadding: 12; bottomPadding: 12
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
            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 14
            color: ap.ink
        }
        Text {
            visible: m.sub !== ""
            width: parent.width
            text: m.sub
            wrapMode: Text.WordWrap
            font.family: ap.body; font.pixelSize: 12
            color: m.checked ? ap.mute : ap.faint
        }
    }
    transform: Translate { y: m.down ? 1 : (m.hovered && m.enabled ? -ap.lift : 0); Behavior on y { NumberAnimation { duration: ap.tHover } } }
    background: Rectangle {
        radius: ap.radius
        color: m.checked ? "#2bffffff" : (m.hovered && m.enabled ? ap.glassHi : ap.glass)
        border.width: m.visualFocus || m.checked ? 2 : 1
        border.color: m.visualFocus ? ap.cyan : (m.checked ? ap.accent : (m.hovered && m.enabled ? ap.edgeHi : ap.edge))
        Behavior on color { ColorAnimation { duration: ap.tHover } }
    }
}
