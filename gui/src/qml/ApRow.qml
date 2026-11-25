// AnyPlay: рядок списку (дизайн 112) — назва, сірий підпис під нею, праворуч фішка чи кнопка, тонка лінія знизу.
// clickable: під наведенням скляна підкладка й підйом, під натиском опускання.
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
    property color subColor: ap.faint      // підпис під назвою; у довідках світліший, щоб читався
    property real titleSize: ap.fsBody
    property real subSize: ap.fsSub
    default property alias trailing: trail.data
    signal clicked()
    AnyPlayStyle { id: ap }

    Layout.fillWidth: true
    implicitWidth: 320
    implicitHeight: Math.max(ap.rowHeight, Math.max(texts.implicitHeight, trail.implicitHeight) + 20)

    Rectangle {   // підкладка під наведенням / фокусом (лише для рядків, що натискаються)
        anchors { fill: parent; leftMargin: -10; rightMargin: -10; topMargin: 2; bottomMargin: 2 }
        radius: ap.radiusSmall
        visible: r.clickable
        color: ap.glass
        opacity: mouse.containsMouse || r.activeFocus ? 1 : 0   // згасанням (opacity), без анімації кольору
        Behavior on opacity { NumberAnimation { duration: ap.tHover } }
        Rectangle { anchors.fill: parent; radius: parent.radius; visible: r.activeFocus; color: "transparent"; border.width: 2; border.color: ap.cyan }
    }
    activeFocusOnTab: clickable
    Keys.onReturnPressed: if (clickable) clicked()
    Keys.onEnterPressed: if (clickable) clicked()
    Keys.onSpacePressed: if (clickable) clicked()

    Column {
        id: texts
        transform: Translate { x: r.clickable && mouse.containsMouse ? 3 : 0; Behavior on x { NumberAnimation { duration: ap.tHover } } }
        anchors { left: parent.left; right: trail.left; rightMargin: trail.width > 0 ? 14 : 0; verticalCenter: parent.verticalCenter }
        spacing: 3
        Text {
            width: parent.width
            text: r.title
            textFormat: r.rich ? Text.StyledText : Text.PlainText
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.weight: Font.Medium
            font.pixelSize: r.titleSize
            color: r.titleColor
        }
        Text {
            visible: r.subtitle !== ""
            width: parent.width
            text: r.subtitle
            textFormat: r.rich ? Text.StyledText : Text.PlainText
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.pixelSize: r.subSize
            color: r.subColor
        }
    }
    RowLayout {   // фішки й кнопки різної висоти стоять по центру рядка (у Row вони тулились би до верху)
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
