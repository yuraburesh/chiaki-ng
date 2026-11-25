// AnyPlay: поле вводу (дизайн 112) — скло, тонкий край, фокус блакитною рамкою.
import QtQuick
import QtQuick.Controls

TextField {
    id: f
    AnyPlayStyle { id: ap }
    color: ap.ink
    placeholderTextColor: ap.faint
    selectionColor: "#668fe3ff"
    selectedTextColor: ap.ink
    font.family: ap.body
    font.pixelSize: ap.fsBody
    leftPadding: 14; rightPadding: 14
    topPadding: 12; bottomPadding: 12
    background: Rectangle {
        implicitWidth: 200
        implicitHeight: 46
        radius: ap.radius
        color: f.activeFocus ? "#1fffffff" : (f.hovered ? ap.glassHi : ap.glass)
        border.width: f.activeFocus ? 2 : 1
        border.color: f.activeFocus ? ap.cyan : (f.hovered ? ap.edgeHi : ap.edge)
    }
}
