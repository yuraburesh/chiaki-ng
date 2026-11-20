// AnyPlay: рядок списку — назва, сірий підпис під нею, праворуч фішка чи кнопка, тонка лінія знизу.
// Вміст праворуч кладемо всередину: ApRow { title: …; ApChip { … } }.
import QtQuick
import QtQuick.Layouts

Item {
    id: r
    property string title
    property string subtitle
    property bool clickable: false
    property bool hairline: true
    property bool rich: false
    property color titleColor: ap.ink
    default property alias trailing: trail.data
    signal clicked()
    AnyPlayStyle { id: ap }

    Layout.fillWidth: true
    implicitWidth: 320
    implicitHeight: Math.max(52, Math.max(texts.implicitHeight, trail.implicitHeight) + 16)
    activeFocusOnTab: clickable
    Keys.onReturnPressed: if (clickable) clicked()
    Keys.onEnterPressed: if (clickable) clicked()
    Keys.onSpacePressed: if (clickable) clicked()

    Column {
        id: texts
        anchors { left: parent.left; right: trail.left; rightMargin: trail.width > 0 ? 14 : 0; verticalCenter: parent.verticalCenter }
        spacing: 1
        Text {
            width: parent.width
            text: r.title
            textFormat: r.rich ? Text.StyledText : Text.PlainText
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.weight: Font.Medium
            font.pixelSize: 14
            font.underline: r.clickable && (mouse.containsMouse || r.activeFocus)
            color: r.titleColor
        }
        Text {
            visible: r.subtitle !== ""
            width: parent.width
            text: r.subtitle
            textFormat: r.rich ? Text.StyledText : Text.PlainText
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.pixelSize: 12
            color: ap.faint
        }
    }
    Row {
        id: trail
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 6
    }
    Rectangle {
        visible: r.hairline
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: ap.hair
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: r.clickable
        hoverEnabled: true
        cursorShape: r.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: r.clicked()
    }
}
