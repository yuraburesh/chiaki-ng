// AnyPlay: як керувати самою приставкою — меню PS, вихід з гри, запуск іншої гри.
// Клавіші показуємо справжні (з урахуванням того, що клієнт міг їх змінити).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

GridLayout {
    id: guide
    property bool compact: false      // у меню гри — щільніше, у два стовпці
    property string menuKey: Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O"
    columns: compact ? 2 : 1
    columnSpacing: 10
    rowSpacing: compact ? 8 : 10

    function keyOf(id, fallback) {
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++) {
            if (profiles[i].id !== "global")
                continue;
            const list = profiles[i].bindings;
            for (let j = 0; j < list.length; j++) {
                if (list[j].id === id) {
                    if (Qt.platform.os === "osx" && list[j].key === "Home")
                        return "Fn + ←";
                    return list[j].keyName || fallback;
                }
            }
        }
        return fallback;
    }
    readonly property string ps: keyOf("ps", "Home")
    readonly property string opt: keyOf("pause", "Esc")
    readonly property string cross: keyOf("select", "Enter")
    readonly property string moon: keyOf("back", "Backspace")
    readonly property var rows: [
        { icon: "home", title: qsTr("Головний екран приставки"),
          text: qsTr("Натисни й утримуй %1 (кнопка PS) близько секунди. Відкриється головний екран PS5 зі списком ігор.").arg(ps) },
        { icon: "bolt", title: qsTr("Швидке меню"),
          text: qsTr("Коротко натисни %1 (кнопка PS). Знизу з'явиться панель: звук, друзі, перемикання між грою і меню.").arg(ps) },
        { icon: "close", title: qsTr("Закрити гру"),
          text: qsTr("Відкрий головний екран, стрілками наведи на гру, натисни %1 (кнопка OPTIONS) і обери «Закрити гру».").arg(opt) },
        { icon: "gamepad", title: qsTr("Запустити іншу гру"),
          text: qsTr("На головному екрані обери гру стрілками ← → і натисни %1 (✕). Якщо попередня гра ще відкрита, приставка запропонує її закрити: погодься.").arg(cross) },
        { icon: "compass", title: qsTr("Рух по меню"),
          text: qsTr("Стрілки ↑ ↓ ← → рухають вибір, %1 (✕) підтверджує, %2 (○) повертає назад. У самій грі %3 відкриває паузу.").arg(cross).arg(moon).arg(opt) },
        { icon: "warning", title: qsTr("Чого не робити"),
          text: qsTr("Не вимикай приставку, не вмикай режим спокою і не виходь з акаунта PSN: після цього підключитись не вийде. Щоб закінчити, натисни «Вийти з гри» в меню AnyPlay (%1).").arg(menuKey) }
    ]

    Repeater {
        model: guide.rows
        Rectangle {
            required property var modelData
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            implicitHeight: rowBox.implicitHeight + (guide.compact ? 16 : 24)
            radius: 14
            color: "#1f1240"
            border.color: "#22ffffff"
            RowLayout {
                id: rowBox
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: guide.compact ? 10 : 14 }
                spacing: 10
                Image {
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: guide.compact ? 24 : 30
                    Layout.preferredHeight: guide.compact ? 24 : 30
                    Layout.topMargin: 1
                    source: "qrc:/icons/ap-" + modelData.icon + ".svg"
                    sourceSize: Qt.size(60, 60)
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label { text: modelData.title; color: "white"; font.pixelSize: guide.compact ? 14 : 17; font.bold: true }
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        text: modelData.text; color: "#d8cdea"; font.pixelSize: guide.compact ? 12.5 : 14
                    }
                }
            }
        }
    }
}
