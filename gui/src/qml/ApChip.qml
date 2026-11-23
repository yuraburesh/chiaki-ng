// AnyPlay: фішка статусу чи клавіші (дизайн 112). Статус — підкладка в колір стану з тонкою рамкою;
// key: true — маленька об'ємна клавіша (для великих клавіш з наведенням і натиском є ApKey).
// kind: "" звичайна, ok — оплачено, wait — чекає оплату, live — йде гра, bad — помилка. key: true — назва клавіші.
import QtQuick

Rectangle {
    id: c
    property string text
    property string kind: ""
    property bool key: false
    property url icon: ""                // квадратний логотип гри зліва (якщо є)
    AnyPlayStyle { id: ap }

    implicitWidth: row.implicitWidth + (key ? 14 : 20)
    implicitHeight: key ? 24 : 26
    radius: ap.chipRadius
    color: kind === "ok" ? "#249ef0bf" : kind === "wait" ? "#24ffd27a" : kind === "live" ? "#247fe6ff" : kind === "bad" ? "#24ff8f8f" : (key ? "transparent" : ap.glass)
    Rectangle {   // клавіша: світліша вгорі (об'єм)
        visible: c.key
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient { GradientStop { position: 0; color: "#33ffffff" } GradientStop { position: 1; color: "#14ffffff" } }
    }
    border.width: 1
    border.color: kind === "ok" ? "#999ef0bf" : kind === "wait" ? "#99ffd27a" : kind === "live" ? ap.cyan : kind === "bad" ? "#99ff8f8f" : ap.edge
    Rectangle {   // нижній бортик клавіші: об'єм
        visible: c.key
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
        height: 2; radius: 1
        color: "#40000000"
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Image {
            id: logo
            visible: String(c.icon) !== "" && status === Image.Ready
            anchors.verticalCenter: parent.verticalCenter
            width: 18; height: 18
            source: c.icon
            sourceSize: Qt.size(48, 48)
            fillMode: Image.PreserveAspectCrop
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: c.text
            font.family: ap.body
            font.weight: Font.DemiBold
            font.pixelSize: c.key ? (c.text === "`" ? 16 : 12) : 13   // клавіша ` дрібна, тож трохи більша
            color: c.kind === "ok" ? ap.ok : c.kind === "wait" ? ap.gold : c.kind === "live" ? ap.cyan : c.kind === "bad" ? ap.bad : ap.ink
        }
    }
}
