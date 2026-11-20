// AnyPlay: як керувати самою приставкою — меню PS, вихід з гри, запуск іншої гри.
// Рядки з тонкими лініями, клавіші праворуч фішками. Клавіші справжні (з урахуванням того, що клієнт міг їх змінити).
import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

GridLayout {
    id: guide
    property bool compact: false      // у меню гри: щільніше
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
                    if (Qt.platform.os === "osx" && list[j].key === "Home")   // клієнт сам призначив Home: на MacBook це Fn + ←
                        return "Fn + ←";
                    return list[j].keyName || fallback;
                }
            }
        }
        return fallback;
    }
    // геймпад: під час гри — якщо зараз керують ним; поза грою — якщо він підключений
    property bool pad: Chiaki.session ? !!Chiaki.session.gamepadMode : Chiaki.controllers.length > 0
    readonly property string ps: keyOf("ps", "P")
    readonly property string opt: keyOf("pause", "Esc")
    readonly property string cross: keyOf("select", "Enter")
    readonly property string moon: keyOf("back", "Backspace")
    readonly property string hold: qsTr("тримати 1 с")
    readonly property var padRows: [
        { title: qsTr("Швидке меню приставки"), text: qsTr("Коротко натисни кнопку PS на геймпаді. Унизу екрана з'явиться панель PS5: звук, сповіщення, друзі, перемикання між іграми. Щоб сховати її, натисни PS ще раз."), keys: ["PS"] },
        { title: qsTr("Головний екран приставки"), text: qsTr("Утримуй кнопку PS близько секунди. Відкриється головний екран зі списком ігор. Гра при цьому не закривається: у неї можна повернутись."), keys: ["PS", hold] },
        { title: qsTr("Рух по меню приставки"), text: qsTr("Хрестовина або лівий стік рухають вибір. ✕ підтверджує, ○ повертає назад (на геймпаді Xbox це A і B)."), keys: ["✕", "○"] },
        { title: qsTr("Запустити гру"), text: qsTr("На головному екрані обери гру хрестовиною і натисни ✕. Перший запуск гри триває до хвилини."), keys: ["✕"] },
        { title: qsTr("Перейти в іншу гру"), text: qsTr("Утримуй PS, обери іншу гру і натисни ✕. Приставка запитає, чи закрити попередню гру: погодься."), keys: ["PS", "✕"] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни OPTIONS (на Xbox це Menu) і обери «Закрити гру»."), keys: ["OPTIONS"] },
        { title: qsTr("Пауза і меню самої гри"), text: qsTr("Під час гри кнопка OPTIONS відкриває паузу гри: карту, завдання, налаштування."), keys: ["OPTIONS"] },
        { title: qsTr("Меню AnyPlay"), text: qsTr("Відкривається з клавіатури: %1. Тут продовження гри, якість картинки, клавіші і «Вийти з гри». Гра на приставці при цьому йде далі.").arg(menuKey), keys: ["`"] },
        { title: qsTr("Закінчити гру"), text: qsTr("Відкрий меню AnyPlay і обери «Вийти з гри». Приставку вимикати не треба: коли час гри вийде, вона завершить усе сама."), keys: ["`"] }
    ]
    readonly property var keyRows: [
        { title: qsTr("Швидке меню приставки"), text: qsTr("Коротко натисни клавішу %1: це кнопка PS. Унизу екрана з'явиться панель PS5: звук, сповіщення, друзі, перемикання між іграми. Щоб сховати її, натисни %1 ще раз.").arg(ps), keys: [ps] },
        { title: qsTr("Головний екран приставки"), text: qsTr("Утримуй клавішу %1 близько секунди. Відкриється головний екран зі списком ігор. Гра при цьому не закривається: у неї можна повернутись.").arg(ps), keys: [ps, hold] },
        { title: qsTr("Рух по меню приставки"), text: qsTr("Стрілки рухають вибір. %1 підтверджує (це кнопка ✕), %2 повертає назад (це кнопка ○).").arg(cross).arg(moon), keys: ["↑ ↓ ← →", cross, moon] },
        { title: qsTr("Запустити гру"), text: qsTr("На головному екрані обери гру стрілками і натисни %1. Перший запуск гри триває до хвилини.").arg(cross), keys: ["← →", cross] },
        { title: qsTr("Перейти в іншу гру"), text: qsTr("Утримуй %1, обери іншу гру стрілками і натисни %2. Приставка запитає, чи закрити попередню гру: погодься.").arg(ps).arg(cross), keys: [ps, cross] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни %1 (це кнопка OPTIONS) і обери «Закрити гру».").arg(opt), keys: [opt] },
        { title: qsTr("Пауза і меню самої гри"), text: qsTr("Під час гри клавіша %1 працює як кнопка OPTIONS: відкриває паузу гри, карту, завдання, налаштування.").arg(opt), keys: [opt] },
        { title: qsTr("Меню AnyPlay"), text: qsTr("Відкривається так: %1. Тут продовження гри, якість картинки, клавіші і «Вийти з гри». Гра на приставці при цьому йде далі.").arg(menuKey), keys: ["`"] },
        { title: qsTr("Закінчити гру"), text: qsTr("Відкрий меню AnyPlay і обери «Вийти з гри». Приставку вимикати не треба: коли час гри вийде, вона завершить усе сама."), keys: ["`"] }
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
            titleSize: 15
            subSize: 13
            subColor: ap.mute          // довідку читають уважно: текст світліший і більший
            Repeater {
                model: gRow.modelData.keys
                ApChip {
                    required property string modelData
                    key: true
                    text: modelData
                }
            }
        }
    }
    AnyPlayStyle { id: ap }
}
