// AnyPlay: великий таймер — кожна цифра в комірці однакової ширини, щоб число не «стрибало» щосекунди.
import QtQuick

Row {
    id: t
    property string text: ""
    property color color: ap.ink
    property real size: 96
    AnyPlayStyle { id: ap }

    TextMetrics {
        id: digit
        font: probe.font
        text: "0"
    }
    TextMetrics {   // висота самих цифр (властивість, а не функція — оновлюється разом зі шрифтом)
        id: digits
        font: probe.font
        text: "0123456789"
    }
    // висота рядка як у макеті (0,95 розміру), цифри по центру — без великих порожніх полів шрифту зверху й знизу
    readonly property real digitH: digits.tightBoundingRect.height
    readonly property real cellH: Math.round(size * 0.95)
    Text {   // лише для шрифту, не показується
        id: probe
        visible: false
        font.family: ap.display
        font.weight: Font.Medium
        font.pixelSize: t.size
    }
    Repeater {
        model: t.text.length
        Item {
            id: cell
            required property int index
            readonly property string ch: t.text.charAt(index)
            readonly property bool num: ch >= "0" && ch <= "9"
            width: num ? Math.ceil(digit.advanceWidth) : glyph.implicitWidth + t.size * 0.02
            height: t.cellH
            Text {
                id: glyph
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.baseline: parent.top
                anchors.baselineOffset: Math.round((t.cellH + t.digitH) / 2)
                text: cell.ch
                font: probe.font
                color: t.color
            }
        }
    }
}
