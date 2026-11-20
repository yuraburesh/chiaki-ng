// AnyPlay: поле вводу нового дизайну — прозоре, тонка рамка, світлий текст.
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
    font.pixelSize: 14
    leftPadding: 12; rightPadding: 12
    topPadding: 10; bottomPadding: 10
    background: Rectangle {
        implicitWidth: 200
        implicitHeight: 42
        radius: ap.radius
        color: "#0affffff"
        border.width: f.activeFocus ? 2 : 1
        border.color: f.activeFocus ? ap.cyan : ap.edge
    }
}
