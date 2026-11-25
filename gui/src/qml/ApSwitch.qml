// AnyPlay: перемикач єдиного дизайну 112 — увімкнено: доріжка в градієнті заходу сонця, кружечок праворуч.
// checked — стан; toggled(bool) — натиснули (стан міняє той, хто слухає, або checked прив'язаний до налаштування).
import QtQuick

Item {
    id: s
    property bool checked: false
    signal toggled(bool on)
    AnyPlayStyle { id: ap }
    implicitWidth: 46; implicitHeight: 26
    activeFocusOnTab: true
    Keys.onSpacePressed: toggled(!checked)
    Keys.onReturnPressed: toggled(!checked)
    opacity: enabled ? 1 : 0.45

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: mouse.containsMouse ? ap.glassHi : ap.glass
        Rectangle {   // увімкнено: доріжка в градієнті заходу сонця
            anchors.fill: parent
            radius: parent.radius
            opacity: s.checked ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
        }
        border.width: s.activeFocus ? 2 : (s.checked ? 0 : 1)
        border.color: s.activeFocus ? ap.cyan : ap.edge
    }
    Rectangle {
        width: parent.height - 6; height: width; radius: width / 2
        y: 3
        x: 3
        // рух кружечка — зсувом (transform), без зміни геометрії
        transform: Translate { x: s.checked ? s.width - s.height : 0; Behavior on x { NumberAnimation { duration: ap.tHover; easing.type: Easing.OutCubic } } }
        color: "#ffffff"
        scale: mouse.pressed ? 0.9 : 1
        Behavior on scale { NumberAnimation { duration: ap.tPress } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: s.toggled(!s.checked)
    }
}
