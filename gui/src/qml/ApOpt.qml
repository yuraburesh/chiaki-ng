// AnyPlay: варіант вибору — рядок з тонкою лінією знизу, праворуч кружечок (radio) або свій вміст (ціна).
import QtQuick
import QtQuick.Layouts

Item {
    id: o
    property string text
    property string sub: ""
    property bool checked: false
    property bool radio: true
    property real textSize: 14
    property url icon: ""                       // квадратний логотип зліва (розкладки ігор)
    default property alias trailing: trail.data
    signal clicked()
    AnyPlayStyle { id: ap }

    Layout.fillWidth: true
    implicitWidth: 240
    implicitHeight: Math.max(44, Math.max(col.implicitHeight, logo.visible ? 40 : 0) + 22)
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()

    Rectangle {   // підсвітка фокусу з клавіатури
        anchors.fill: parent
        visible: o.activeFocus
        color: "#0fffffff"
        border.color: ap.cyan
        border.width: 1
        radius: ap.radius
    }
    Image {
        id: logo
        visible: String(o.icon) !== "" && status === Image.Ready
        anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
        width: 40; height: 40
        source: o.icon
        sourceSize: Qt.size(96, 96)
        fillMode: Image.PreserveAspectCrop
    }
    Column {
        id: col
        anchors {
            left: logo.visible ? logo.right : parent.left; leftMargin: logo.visible ? 12 : 2
            right: trail.left; rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        spacing: 2
        Text {
            width: parent.width
            text: o.text
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.weight: Font.Medium
            font.pixelSize: o.textSize
            color: o.checked || mouse.containsMouse ? ap.ink : ap.mute
        }
        Text {
            visible: o.sub !== ""
            width: parent.width
            text: o.sub
            wrapMode: Text.WordWrap
            font.family: ap.body
            font.pixelSize: 12
            color: ap.faint
        }
    }
    Row {
        id: trail
        anchors { right: parent.right; rightMargin: 2; verticalCenter: parent.verticalCenter }
        spacing: 6
        Rectangle {   // кружечок вибору
            visible: o.radio
            anchors.verticalCenter: parent.verticalCenter
            width: 12; height: 12; radius: 6
            color: "transparent"
            border.width: 1.5
            border.color: o.checked ? "#ffffff" : "#80ffffff"
            Rectangle {
                visible: o.checked
                anchors.centerIn: parent
                width: 6; height: 6; radius: 3
                color: "#ffffff"
            }
        }
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: ap.hair
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: o.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: o.clicked()
    }
}
