// AnyPlay: як керувати самою приставкою — меню PS, вихід з гри, запуск іншої гри.
// Рядки з тонкими лініями, клавіші праворуч фішками. Клавіші справжні (з урахуванням того, що клієнт міг їх змінити).
import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

GridLayout {
    id: guide
    property bool compact: false      // у меню гри — без рядка «Чого не робити» внизу сітки, щільніше
    property string menuKey: qsTr("клавіша ` (під Esc)")
    columns: 1
    columnSpacing: 64
    rowSpacing: 0

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
    // геймпад: під час гри — якщо зараз керують ним; поза грою — якщо він підключений
    property bool pad: Chiaki.session ? !!Chiaki.session.gamepadMode : Chiaki.controllers.length > 0
    readonly property string ps: keyOf("ps", "Home")
    readonly property string opt: keyOf("pause", "Esc")
    readonly property string cross: keyOf("select", "Enter")
    readonly property string moon: keyOf("back", "Backspace")
    readonly property string dontText: qsTr("Не вимикай приставку, не вмикай режим спокою і не виходь з акаунта PSN: після цього підключитись не вийде. Щоб закінчити, обери «Вийти з гри» в меню AnyPlay: %1.").arg(menuKey)
    readonly property var padRows: [
        { title: qsTr("Головний екран приставки"), text: qsTr("Утримуй кнопку PS на геймпаді близько секунди: відкриється список ігор."), keys: ["PS", qsTr("утримати")] },
        { title: qsTr("Швидке меню"), text: qsTr("Коротко натисни кнопку PS: звук, друзі, перемикання між грою і меню."), keys: ["PS"] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни OPTIONS (на Xbox це Menu) і обери «Закрити гру»."), keys: ["OPTIONS"] },
        { title: qsTr("Запустити іншу гру"), text: qsTr("На головному екрані обери гру хрестовиною і натисни ✕ (на Xbox це A). Якщо попередня гра ще відкрита, приставка запропонує її закрити: погодься."), keys: ["✕"] },
        { title: qsTr("Рух по меню"), text: qsTr("Хрестовина або лівий стік рухають вибір, ✕ підтверджує, ○ повертає назад (на Xbox це A і B)."), keys: ["✕", "○"] },
        { title: qsTr("Чого не робити"), text: dontText, keys: [] }
    ]
    readonly property var keyRows: [
        { title: qsTr("Головний екран приставки"), text: qsTr("Утримуй кнопку PS близько секунди: відкриється список ігор."), keys: [ps, qsTr("утримати")] },
        { title: qsTr("Швидке меню"), text: qsTr("Коротко натисни кнопку PS: звук, друзі, перемикання між іграми."), keys: [ps] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни OPTIONS і обери «Закрити гру»."), keys: [opt] },
        { title: qsTr("Запустити іншу гру"), text: qsTr("На головному екрані обери гру стрілками і натисни ✕. Якщо попередня гра ще відкрита, приставка запропонує її закрити: погодься."), keys: ["← →", cross] },
        { title: qsTr("Рух по меню"), text: qsTr("Стрілки рухають вибір, ✕ підтверджує, ○ повертає назад. У самій грі OPTIONS відкриває паузу."), keys: ["↑ ↓ ← →", cross, moon] },
        { title: qsTr("Чого не робити"), text: dontText, keys: [] }
    ]
    readonly property var rows: pad ? padRows : keyRows

    Repeater {
        model: guide.rows
        ApRow {
            id: gRow
            required property var modelData
            Layout.fillWidth: true
            Layout.fillHeight: true      // у двох стовпцях лінії під рядками на одній висоті
            Layout.preferredWidth: 1
            title: modelData.title
            subtitle: modelData.text
            titleColor: modelData.keys.length ? ap.ink : ap.gold
            Repeater {
                model: gRow.modelData.keys
                ApChip {
                    required property string modelData
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    key: true
                    text: modelData
                }
            }
        }
    }
    AnyPlayStyle { id: ap }
}
