// AnyPlay: варіант вибору (дизайн 112) — рядок з тонкою лінією знизу, праворуч кружечок (radio) або свій вміст (ціна).
// Обраний: смужка заходу сонця зліва, кружечок з градієнтом. Наведення: скляна підкладка, натиск: опускання.
import QtQuick
import QtQuick.Layouts

Item {
    id: o
    property string text
    property string sub: ""
    property bool checked: false
    property bool radio: true
    property real textSize: ap.fsBody
    property url icon: ""                       // квадратний логотип зліва (розкладки ігор)
    default property alias trailing: trail.data
    signal clicked()
    AnyPlayStyle { id: ap }

    Layout.fillWidth: true
    implicitWidth: 240
    implicitHeight: Math.max(52, Math.max(col.implicitHeight, logo.visible ? 44 : 0) + 24)
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: true
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()

    Rectangle {   // підкладка: наведення, фокус, обраний
        anchors { fill: parent; topMargin: 2; bottomMargin: 2 }
        radius: ap.radiusSmall
        color: o.checked ? "#1fffffff" : (mouse.containsMouse || o.activeFocus ? ap.glass : "transparent")
        border.width: o.activeFocus ? 2 : 0
        border.color: ap.cyan
        Behavior on color { ColorAnimation { duration: ap.tHover } }
    }
    Rectangle {   // смужка заходу сонця біля обраного
        visible: o.checked
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 10; bottomMargin: 10 }
        width: 3; radius: 1.5
        gradient: Gradient { GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
    }
    Image {
        id: logo
        visible: String(o.icon) !== "" && status === Image.Ready
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
        width: 44; height: 44
        source: o.icon
        sourceSize: Qt.size(96, 96)
        fillMode: Image.PreserveAspectCrop
    }
    Column {
        id: col
        anchors {
            left: logo.visible ? logo.right : parent.left; leftMargin: logo.visible ? 14 : 14
            right: trail.left; rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        spacing: 3
        transform: Translate { y: mouse.pressed ? 1 : 0 }
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
            font.pixelSize: ap.fsSub
            color: ap.faint
        }
    }
    Row {
        id: trail
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
        spacing: 6
        Rectangle {   // кружечок вибору
            visible: o.radio
            anchors.verticalCenter: parent.verticalCenter
            width: 20; height: 20; radius: 10
            color: "#0dffffff"
            border.width: o.checked ? 0 : 1.5
            border.color: mouse.containsMouse ? ap.edgeHi : "#80ffffff"
            Rectangle {   // обраний: кружечок у градієнті заходу сонця
                anchors.fill: parent
                radius: parent.radius
                visible: o.checked
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
            Rectangle {
                visible: o.checked
                anchors.centerIn: parent
                width: 8; height: 8; radius: 4
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
