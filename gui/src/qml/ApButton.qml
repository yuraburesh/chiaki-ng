// AnyPlay: кнопка нового дизайну.
// Головна: суцільна світла, темний текст. ghost: прозора з тонкою рамкою. small: менша, для рядків і вікон.
import QtQuick
import QtQuick.Controls

Button {
    id: b
    property bool ghost: false
    property bool small: false
    property bool danger: false          // червоний текст (наприклад, «Вийти з гри»)
    property real minWidth: 0
    property bool wrap: false            // довгий напис у вузькій колонці — у два рядки замість «…»
    AnyPlayStyle { id: ap }

    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    leftPadding: small ? 12 : (ghost ? 20 : 30)
    rightPadding: leftPadding
    topPadding: small ? 6 : (ghost ? 11 : 14)
    bottomPadding: topPadding
    implicitWidth: Math.max(minWidth, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: implicitContentHeight + topPadding + bottomPadding
    font.family: ap.display
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.pixelSize: small ? 13 : (ghost ? 15 : 18)
    font.letterSpacing: small ? 1.2 : (ghost ? 1.6 : 2.4)

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    contentItem: Text {
        text: b.text
        font: b.font
        color: b.ghost ? (b.danger ? ap.bad : ap.ink) : (b.danger ? "#8a2330" : ap.dark)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        wrapMode: b.wrap ? Text.Wrap : Text.NoWrap
        maximumLineCount: b.wrap ? 2 : 1
    }
    background: Rectangle {
        radius: ap.radius
        opacity: b.enabled ? (b.down ? 0.82 : 1) : 0.45
        color: b.ghost ? (b.hovered ? "#14ffffff" : "#0affffff") : (b.hovered ? "#ffffff" : ap.ink)
        border.width: b.ghost || b.visualFocus ? (b.visualFocus ? 2 : 1) : 0
        border.color: b.visualFocus ? ap.cyan : (b.hovered ? ap.ink : (b.danger ? "#80ff9a9a" : ap.edge))
    }
}
