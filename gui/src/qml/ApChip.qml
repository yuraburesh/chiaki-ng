// AnyPlay: фішка статусу чи клавіші — тонка рамка, ледь заокруглені кути.
// kind: "" звичайна, ok — оплачено, wait — чекає оплату, live — йде гра, bad — помилка. key: true — назва клавіші.
import QtQuick

Rectangle {
    id: c
    property string text
    property string kind: ""
    property bool key: false
    property url icon: ""                // квадратний логотип гри зліва (якщо є)
    AnyPlayStyle { id: ap }

    implicitWidth: row.implicitWidth + (key ? 12 : 16)
    implicitHeight: key ? 20 : 22
    radius: ap.chipRadius
    color: "#12ffffff"
    border.width: 1
    border.color: kind === "ok" ? "#809be8b8" : kind === "wait" ? "#80ffd9a0" : kind === "live" ? ap.cyan : kind === "bad" ? "#80ff9a9a" : ap.edge

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Image {
            id: logo
            visible: String(c.icon) !== "" && status === Image.Ready
            anchors.verticalCenter: parent.verticalCenter
            width: 16; height: 16
            source: c.icon
            sourceSize: Qt.size(48, 48)
            fillMode: Image.PreserveAspectCrop
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: c.text
            font.family: ap.body
            font.weight: Font.DemiBold
            font.pixelSize: c.key ? (c.text === "`" ? 15 : 11) : 12   // клавіша ` дрібна, тож трохи більша
            color: c.kind === "ok" ? ap.ok : c.kind === "wait" ? ap.gold : c.kind === "live" ? ap.cyan : c.kind === "bad" ? ap.bad : ap.ink
        }
    }
}
