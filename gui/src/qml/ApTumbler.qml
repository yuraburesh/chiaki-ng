// AnyPlay: барабан вибору числа, як у будильнику: перетягни, прокрути коліщатком, клацни сусіднє число або тисни ↑ ↓.
// value = обране число (індекс × step). Використання: ApTumbler { count: 49; label: qsTr("годин") }.
import QtQuick
import QtQuick.Controls

Item {
    id: t
    property int count: 10               // скільки значень на барабані
    property int step: 1                 // крок між значеннями
    property bool twoDigits: false       // «05» замість «5»
    property string label: ""            // підпис під барабаном («годин», «хвилин»)
    property alias currentIndex: drum.currentIndex
    readonly property int value: drum.currentIndex * step
    readonly property alias moving: drum.moving
    property alias drumItem: drum
    function setValue(v) { drum.currentIndex = Math.max(0, Math.min(count - 1, Math.round(v / step))); }
    AnyPlayStyle { id: ap }

    implicitWidth: 104
    implicitHeight: drum.height + (label !== "" ? cap.implicitHeight + 8 : 0)
    activeFocusOnTab: true
    onActiveFocusChanged: if (activeFocus) drum.forceActiveFocus(Qt.TabFocusReason)

    Tumbler {
        id: drum
        readonly property real rowH: height / visibleItemCount
        width: parent.width
        height: 170
        model: t.count
        visibleItemCount: 5
        wrap: true
        focusPolicy: Qt.StrongFocus
        // фон: дві тонкі лінії навколо обраного числа (блакитні, коли барабан у фокусі клавіатури)
        background: Item {
            Rectangle {
                x: 8; width: parent.width - 16; height: drum.activeFocus ? 2 : 1
                y: Math.round((drum.height - drum.rowH) / 2)
                color: drum.activeFocus ? ap.cyan : ap.edge
            }
            Rectangle {
                x: 8; width: parent.width - 16; height: drum.activeFocus ? 2 : 1
                y: Math.round((drum.height + drum.rowH) / 2)
                color: drum.activeFocus ? ap.cyan : ap.edge
            }
        }
        delegate: Item {
            id: cell
            required property int index
            // 0 — обране число, 1 — сусіднє… (поки барабан ще не взяв комірку собі, зсуву в неї немає)
            readonly property real off: cell.parent ? Math.abs(cell.Tumbler.displacement) : 3
            opacity: Math.max(0.12, 1 - off * 0.42)
            Text {
                anchors.centerIn: parent
                text: t.twoDigits ? String(cell.index * t.step).padStart(2, "0") : String(cell.index * t.step)
                font.family: ap.display
                font.weight: cell.off < 0.5 ? Font.DemiBold : Font.Medium
                font.pixelSize: 30
                font.letterSpacing: 1
                scale: Math.max(0.6, 1 - cell.off * 0.2)
                color: cell.off < 0.5 ? ap.ink : ap.mute
            }
            MouseArea {   // клац по сусідньому числу обирає його (перетягування барабана лишається)
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { drum.forceActiveFocus(); drum.currentIndex = cell.index; }
            }
        }
        // коліщатко миші й тачпад: один крок на поділку
        MouseArea {
            property real acc: 0
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: (wheel) => {
                wheel.accepted = true;
                acc += wheel.angleDelta.y;
                while (acc >= 120) { acc -= 120; drum.currentIndex = (drum.currentIndex - 1 + t.count) % t.count; }
                while (acc <= -120) { acc += 120; drum.currentIndex = (drum.currentIndex + 1) % t.count; }
            }
        }
    }
    Text {
        id: cap
        visible: t.label !== ""
        anchors { top: drum.bottom; topMargin: 8; horizontalCenter: parent.horizontalCenter }
        text: t.label
        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 12
        font.letterSpacing: ap.capSpacing; font.capitalization: Font.AllUppercase
        color: ap.mute
    }
}
