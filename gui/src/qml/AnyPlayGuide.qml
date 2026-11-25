// AnyPlay: як керувати самою приставкою — меню PS, вихід з гри, запуск іншої гри.
// Дизайн 112: у головному вікні кожна порада на скляній плитці з об'ємними клавішами праворуч;
// compact (меню гри) — щільні рядки з тонкими лініями й фішками клавіш. Клавіші справжні (з урахуванням змін клієнта).
import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

GridLayout {
    id: guide
    property bool compact: false      // у меню гри: щільніше
    property string menuKey: qsTr("клавіша ` (під Esc)")
    readonly property bool tiles: !compact
    columns: 1
    columnSpacing: tiles ? 14 : 64
    rowSpacing: tiles ? 14 : 0

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
    // клавіша дії з режиму «Пішки» ("" — у цій розкладці такої дії немає)
    function footKey(id) {
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++) {
            if (profiles[i].id !== "foot")
                continue;
            const list = profiles[i].bindings;
            for (let j = 0; j < list.length; j++)
                if (list[j].id === id)
                    return list[j].key ? list[j].keyName : "";
        }
        return "";
    }
    // ручний перемикач «пішки ↔ транспорт» (дія з "profile": "toggle"; 115: U)
    function toggleKeyName() {
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++) {
            if (profiles[i].id !== "global")
                continue;
            const list = profiles[i].bindings;
            for (let j = 0; j < list.length; j++)
                if (list[j].profile === "toggle")
                    return list[j].key ? list[j].keyName : "";
        }
        return "";
    }
    // 113: плавні стіки з клавіатури (клавіші зі спільних, див. anyplaystick.h)
    function globalKey(id) {
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++) {
            if (profiles[i].id !== "global")
                continue;
            const list = profiles[i].bindings;
            for (let j = 0; j < list.length; j++)
                if (list[j].id === id)
                    return list[j].key ? list[j].keyName : "";
        }
        return "";
    }
    readonly property string hotwireKey: globalKey("hotwire")
    readonly property string preciseKey: globalKey("precise")
    readonly property string holdKey: globalKey("hold_stick")
    readonly property string toggleKey: toggleKeyName()
    readonly property string enterKey: footKey("vehicle")
    // 115: F (△) режим не перемикає, лише дія в грі; режим міняє автоматика за курками, вручну — U
    readonly property var modeRow: toggleKey ? [{
        title: qsTr("Пішки і транспорт"),
        text: (enterKey ? qsTr("%1 працює як △ у грі: сісти в машину, взяти предмет, відчинити двері. Режим клавіш вона не міняє: ").arg(enterKey)
                        : qsTr("Режим клавіш "))
            + qsTr("програма сама вмикає «Транспорт», коли герой сів у машину (приставка дає опір педалям газу й гальма), і «Пішки», коли вийшов. Якщо вона помилилась: %1 перемикає пішки і транспорт, F1, F2, F3 обирають режим.").arg(toggleKey),
        keys: [toggleKey]
    }] : []
    readonly property var lockRow: modeRow.concat(hotwireKey ? [{
        title: qsTr("Злам машини (GTA VI)"),
        text: qsTr("Тримай %1: обидва стіки стають назустріч, а мишею ти крутиш їх разом (правий за мишею, лівий дзеркально). Коліщатко і стрілки ← → докручують дрібно. Відпустив %1 — усе як було. Якщо гра просить просто крутити один стік по колу: лівий клавішами %2, правий клавішами %3.")
            .arg(hotwireKey)
            .arg([footKey("lock_l_ccw"), footKey("lock_l_cw")].filter((k) => k).join(" і ") || "—")
            .arg([footKey("lock_r_ccw"), footKey("lock_r_cw")].filter((k) => k).join(" і ") || "—"),
        keys: [hotwireKey, qsTr("миша")]
    }] : []).concat(preciseKey ? [{
        title: qsTr("Точний рух стіком"),
        text: qsTr("Тримай %1 і клавіші руху крутять лівий стік по колу плавно, за кутом (вліво і вправо повертають, вперед і назад міняють силу). Відпустив клавішу руху — стік стоїть, де був. Коротке натискання %1 вмикає режим до наступного натискання.").arg(preciseKey),
        keys: [preciseKey]
    }] : []).concat(holdKey ? [{
        title: qsTr("Утримати камеру"),
        text: qsTr("Натисни %1: правий стік тримає напрям, який задаєш мишею, і не повертається в центр (камера дивиться, куди поставив). Ще раз %1 — відпустити.").arg(holdKey),
        keys: [holdKey]
    }] : [])
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
        { title: qsTr("Меню AnyPlay"), text: qsTr("На геймпаді утримуй кнопку Create (ліворуч від тачпада) близько секунди; з клавіатури: %1. У меню ходи хрестовиною або стіком, ✕ обирає, ○ повертає. Тут продовження бронювання, якість картинки, клавіші і «Вийти з гри». Гра на приставці при цьому йде далі.").arg(menuKey), keys: ["Create", hold] },
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
        { title: qsTr("Меню AnyPlay"), text: qsTr("Відкривається так: %1. Тут продовження бронювання, якість картинки, клавіші і «Вийти з гри». Гра на приставці при цьому йде далі.").arg(menuKey), keys: ["`"] },
        { title: qsTr("Закінчити гру"), text: qsTr("Відкрий меню AnyPlay і обери «Вийти з гри». Приставку вимикати не треба: коли час гри вийде, вона завершить усе сама."), keys: ["`"] }
    ]
    readonly property var rows: pad ? padRows : keyRows.concat(lockRow)

    Repeater {
        model: guide.rows
        Item {
            id: tile
            required property var modelData
            Layout.fillWidth: true
            Layout.fillHeight: true      // у двох стовпцях плитки (лінії) одного ряду на одній висоті
            Layout.preferredWidth: 1
            implicitHeight: gRow.implicitHeight + (guide.tiles ? 16 : 0)
            Rectangle {   // скляна плитка
                visible: guide.tiles
                anchors.fill: parent
                radius: ap.radius + 2
                color: ap.card
                border.width: 1
                border.color: tileMouse.containsMouse ? ap.edgeHi : ap.cardEdge
                Behavior on border.color { ColorAnimation { duration: ap.tHover } }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
                    height: Math.min(40, parent.height * 0.5); radius: parent.radius - 1
                    gradient: Gradient { GradientStop { position: 0; color: ap.cardTop } GradientStop { position: 1; color: "#00ffffff" } }
                }
                MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            }
            ApRow {
                id: gRow
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: guide.tiles ? 18 : 0; rightMargin: guide.tiles ? 16 : 0 }
                hairline: !guide.tiles
                title: tile.modelData.title
                subtitle: tile.modelData.text
                titleSize: guide.tiles ? 16 : 15
                subSize: guide.tiles ? 14 : 13
                subColor: ap.mute          // довідку читають уважно: текст світліший і більший
                Repeater {
                    model: tile.modelData.keys
                    Loader {
                        required property string modelData
                        sourceComponent: guide.tiles ? bigKey : smallKey
                        Component { id: bigKey; ApKey { text: modelData; size: 32; interactive: false } }
                        Component { id: smallKey; ApChip { key: true; text: modelData } }
                    }
                }
            }
        }
    }
    AnyPlayStyle { id: ap }
}
