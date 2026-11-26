// AnyPlay: як керувати самою приставкою — меню PS, вихід з гри, запуск іншої гри.
// 117: усе на одній сторінці без прокрутки (головне вікно від 1280×800, меню гри від 1280×720): компактні скляні плитки
// до трьох у ряд, назва з об'ємними клавішами праворуч, під нею коротке пояснення (той самий зміст, менше слів).
// compact (меню гри) — те саме, щільніше. Клавіші справжні (з урахуванням змін клієнта).
// 118: для GTA VI з клавіатури ще ряд: «коротко і тримай» на літерах хрестовини і що ввімкнути в налаштуваннях самої гри
// (назви пунктів у лапках такі, як їх показує приставка: меню GTA VI на ній російською).
import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

GridLayout {
    id: guide
    property bool compact: false      // у меню гри: щільніше
    property string menuKey: qsTr("клавіша ` (під Esc)")
    columns: 1
    columnSpacing: compact ? 10 : 12
    rowSpacing: compact ? 8 : 10

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
        text: (enterKey ? qsTr("«Транспорт» чи «Пішки» програма вмикає сама, %1 лише дія △ у грі. ").arg(enterKey)
                        : qsTr("«Транспорт» чи «Пішки» програма вмикає сама. "))
            + qsTr("Помилилась: %1 перемикає, F1, F2, F3 обирають режим.").arg(toggleKey),
        keys: [toggleKey]
    }] : []
    readonly property var lockRow: modeRow.concat(hotwireKey ? [{
        title: qsTr("Злам машини (GTA VI)"),
        text: qsTr("Тримай %1: стіки стають назустріч, миша крутить обидва, коліщатко і ← → докручують. Один стік по колу: лівий %2, правий %3.")
            .arg(hotwireKey)
            .arg([footKey("lock_l_ccw"), footKey("lock_l_cw")].filter((k) => k).join(" і ") || "—")
            .arg([footKey("lock_r_ccw"), footKey("lock_r_cw")].filter((k) => k).join(" і ") || "—"),
        keys: [hotwireKey, qsTr("миша")]
    }] : []).concat(preciseKey && holdKey ? [{
        // 118: точний рух і «утримати камеру» в одній плитці, щоб з порадами для GTA VI все вміщалось без прокрутки
        title: qsTr("Точний рух і камера"),
        text: qsTr("Тримай %1: клавіші руху плавно крутять лівий стік (коротко %1 — до наступного натискання). %2: правий стік тримає напрям від миші, ще раз %2 відпускає.").arg(preciseKey).arg(holdKey),
        keys: [preciseKey, holdKey]
    }] : preciseKey ? [{
        title: qsTr("Точний рух стіком"),
        text: qsTr("Тримай %1: клавіші руху плавно крутять лівий стік і лишають його там, де відпустив. Коротко %1: режим до наступного натискання.").arg(preciseKey),
        keys: [preciseKey]
    }] : holdKey ? [{
        title: qsTr("Утримати камеру"),
        text: qsTr("%1: правий стік тримає напрям, заданий мишею, і не вертається в центр. Ще раз %1 відпускає.").arg(holdKey),
        keys: [holdKey]
    }] : [])
    // 118: GTA VI — хрестовина на літерах (коротко / тримай) і налаштування самої гри, що полегшують клавіатуру
    readonly property bool gta6: Chiaki.settings.anyplayLayout() === "gta6"
    readonly property var gtaRows: {
        if (!gta6)
            return [];
        const t = footKey("phone"), x = footKey("radio"), z = footKey("minimap"), g = footKey("detonate");
        const out = [];
        if (t && x && z && g)
            out.push({
                title: qsTr("Коротко і тримай (GTA VI)"),
                text: qsTr("Як на геймпаді: %1 коротко — телефон, тримай — WAiNK. Так само %2, %3, %4 і все, що на екрані «Клавіші» через «/».").arg(t).arg(x).arg(z).arg(g),
                keys: [t, x, z, g]
            });
        out.push({
            title: qsTr("Гра: легше з клавіатури"),
            text: qsTr("Налаштування гри, «Игровой процесс»: увімкни «Упрощенные мини-игры» (злам без стіків) і «Помощь с нажатиями» (тримати замість частого □)."),
            keys: [opt]
        });
        out.push({
            title: qsTr("Гра: приціл і курки"),
            text: qsTr("Там само «Прицеливание» і «Взаимодействие»: «Удерживать», у «Бои»: «Автонаведение». Адаптивні курки не вимикай: за ними програма бачить машину."),
            keys: [footKey("aim") || qsTr("ПКМ")]
        });
        return out;
    }
    // геймпад: під час гри — якщо зараз керують ним; поза грою — якщо він підключений
    property bool pad: Chiaki.session ? !!Chiaki.session.gamepadMode : Chiaki.controllers.length > 0
    readonly property string ps: keyOf("ps", "P")
    readonly property string opt: keyOf("pause", "Esc")
    readonly property string cross: keyOf("select", "Enter")
    readonly property string moon: keyOf("back", "Backspace")
    readonly property string hold: qsTr("тримати 1 с")
    readonly property var padRows: [
        { title: qsTr("Швидке меню приставки"), text: qsTr("Коротко натисни PS: унизу панель PS5 зі звуком, друзями й іграми. Ще раз PS ховає її."), keys: ["PS"] },
        { title: qsTr("Головний екран приставки"), text: qsTr("Утримуй PS секунду: відкриється список ігор. Гра не закривається, у неї можна повернутись."), keys: ["PS", hold] },
        { title: qsTr("Рух по меню"), text: qsTr("Хрестовина або лівий стік рухають вибір, ✕ підтверджує, ○ назад (на Xbox це A і B)."), keys: ["✕", "○"] },
        { title: qsTr("Запустити гру"), text: qsTr("На головному екрані обери гру хрестовиною й натисни ✕. Перший запуск триває до хвилини."), keys: ["✕"] },
        { title: qsTr("Перейти в іншу гру"), text: qsTr("Утримуй PS, обери гру й натисни ✕. Коли приставка спитає, чи закрити попередню, погодься."), keys: ["PS", "✕"] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни OPTIONS (на Xbox це Menu) і обери «Закрити гру»."), keys: ["OPTIONS"] },
        { title: qsTr("Пауза і меню гри"), text: qsTr("OPTIONS відкриває паузу самої гри: карту, завдання, налаштування."), keys: ["OPTIONS"] },
        { title: qsTr("Меню AnyPlay і вихід"), text: qsTr("Утримуй Create (ліворуч від тачпада) секунду. Тут бронь, картинка, клавіші й «Вийти з гри». Приставку не вимикай: вона все завершить сама."), keys: ["Create", hold] }
    ]
    readonly property var keyRows: [
        { title: qsTr("Кнопка PS"), text: qsTr("Коротко %1: унизу панель PS5 зі звуком, друзями й іграми. Утримуй %1 секунду: головний екран, гра не закривається.").arg(ps), keys: [ps, hold] },
        { title: qsTr("Рух по меню"), text: qsTr("Стрілки рухають вибір, %1 підтверджує (кнопка ✕), %2 повертає назад (кнопка ○).").arg(cross).arg(moon), keys: ["↑↓←→", cross, moon] },
        { title: qsTr("Запустити чи змінити гру"), text: qsTr("Утримуй %1, обери гру стрілками й натисни %2 (перший запуск до хвилини). Спитає, чи закрити попередню, — погодься.").arg(ps).arg(cross), keys: [ps, cross] },
        { title: qsTr("Закрити гру"), text: qsTr("На головному екрані наведи на гру, натисни %1 (кнопка OPTIONS) і обери «Закрити гру».").arg(opt), keys: [opt] },
        { title: qsTr("Пауза і меню гри"), text: qsTr("Під час гри %1 працює як OPTIONS: пауза самої гри, карта, завдання, налаштування.").arg(opt), keys: [opt] },
        { title: qsTr("Меню AnyPlay і вихід"), text: qsTr("Відкривається: %1. Тут бронь, картинка, клавіші й «Вийти з гри». Приставку не вимикай: вона все завершить сама.").arg(menuKey), keys: ["`"] }
    ]
    readonly property var rows: pad ? padRows : keyRows.concat(lockRow).concat(gtaRows)

    Repeater {
        model: guide.rows
        Item {
            id: tile
            required property var modelData
            Layout.fillWidth: true
            Layout.fillHeight: true      // плитки одного ряду на одній висоті
            Layout.preferredWidth: 1
            implicitHeight: tCol.implicitHeight + (guide.compact ? 18 : 22)
            Rectangle {   // скляна плитка: наведення підсвічує край
                anchors.fill: parent
                radius: ap.radius + 2
                color: ap.card
                border.width: 1
                border.color: tileMouse.containsMouse ? ap.edgeHi : ap.cardEdge
                Behavior on border.color { ColorAnimation { duration: ap.tHover } }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
                    height: Math.min(34, parent.height * 0.5); radius: parent.radius - 1
                    gradient: Gradient { GradientStop { position: 0; color: ap.cardTop } GradientStop { position: 1; color: "#00ffffff" } }
                }
                MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            }
            Column {
                id: tCol
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: guide.compact ? 14 : 16; rightMargin: guide.compact ? 12 : 14; topMargin: guide.compact ? 9 : 11 }
                spacing: guide.compact ? 4 : 5
                Item {   // назва ліворуч (у вузькій плитці у два рядки), клавіші праворуч
                    width: parent.width
                    height: Math.max(tTitle.implicitHeight, tKeys.implicitHeight)
                    Text {
                        id: tTitle
                        anchors { left: parent.left; right: tKeys.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        text: tile.modelData.title
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: guide.compact ? 14 : 15
                        color: ap.ink
                    }
                    Row {
                        id: tKeys
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 5
                        Repeater {
                            model: tile.modelData.keys
                            ApKey { required property string modelData; text: modelData; size: guide.compact ? 22 : 25; interactive: false }
                        }
                    }
                }
                Text {
                    width: parent.width
                    text: tile.modelData.text
                    wrapMode: Text.WordWrap
                    lineHeight: 1.05
                    font.family: ap.body; font.pixelSize: guide.compact ? 13 : 13.5
                    color: ap.mute          // довідку читають уважно: текст світлий
                }
            }
        }
    }
    AnyPlayStyle { id: ap }
}
