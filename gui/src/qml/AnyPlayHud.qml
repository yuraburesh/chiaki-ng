import QtQuick

// AnyPlay 112: «системний рядок» під час гри — компактна скляна пігулка в стилі Vice City 2026.
// Живе в чорній смузі над або під кадром (відео 16:9 вписане з чорними смугами), а коли смуг немає —
// біля краю вікна поверх гри. Тонке темне скло, світлий край, маленька риска заходу сонця зліва,
// короткий ярлик великими літерами (Oswald) і спокійний текст (Inter). Без обводки, без емодзі.
//
// Використання:
//   AnyPlayHud { id: hud; edge: "top"; fits: ...; k: ... }   hud.show("Режим", "Транспорт", 1600, "F — пішки")
//   AnyPlayHud { active: умова; label: "…"; text: "…" }       (показ, яким керує батько, без таймера)
//   У тіло можна класти свої Text (вони стають у рядок після вбудованих): AnyPlayHud { Text { … } }
Item {
    id: hud
    AnyPlayStyle { id: ap }

    property string edge: "top"          // "top" — у верхній смузі, "bottom" — у нижній
    property string align: "center"      // "center", "left" або "right" (116: «в ефірі» праворуч угорі)
    property bool fits: true             // відео вписане з чорними смугами (режим «Normal»); інакше смуг немає
    property bool hidden: false          // тимчасово сховати (відкрите меню тощо), стан показу не губиться
    property real k: 1                   // масштаб від висоти вікна (1 на 1000 рядках, до 2)
    property real margin: 14             // відступ від краю, коли смуги немає (до масштабу)
    property real offsetY: 0             // зсув по вертикалі (напр. статистика під пігулкою режиму)
    property string label: ""            // ярлик великими літерами: «РЕЖИМ», «КАРТИНКА», «ЗВ'ЯЗОК»
    property string text: ""             // головний текст
    property string detail: ""           // короткий додаток блідішим: «F — пішки»
    property color textColor: ap.ink     // колір головного тексту (золотий для таймера)
    property color tone: ap.accentA      // колір риски, коли toneGradient вимкнено
    property bool toneGradient: true     // риска в градієнті заходу сонця
    property bool active: false          // показано (show() вмикає й вимикає через таймер)
    property bool ring: false            // 121: блакитна рамка — пігулка зараз приймає клавіші (підказка «Картинка просідає»)
    default property alias content: row.data

    // ── геометрія смуги й масштабу ──
    // висота чорної смуги зверху/знизу: вікно вужче за 16:9 і відео вписане
    readonly property real band: fits && parent ? Math.max(0, (parent.height - parent.width * 9 / 16) / 2) : 0
    readonly property real baseH: 34     // висота пігулки при масштабі 1
    readonly property real minS: 11 / 15 // найменший масштаб: текст не менше 11 px
    // пігулка в смузі, якщо вміщується хоч при зменшеному масштабі; інакше поверх краю відео
    readonly property bool inBand: band >= baseH * minS + 6
    readonly property real s: inBand ? Math.min(k, (band - 8) / baseH) : k
    readonly property real padX: 14 * s
    readonly property real maxWidth: parent ? parent.width - 2 * margin * s : 4096

    implicitWidth: Math.min(maxWidth, row.implicitWidth + 2 * padX)
    implicitHeight: Math.round(baseH * s)
    width: implicitWidth
    height: implicitHeight

    readonly property real restY: inBand
        ? (edge === "top" ? (band - height) / 2 : parent.height - band + (band - height) / 2)
        : (edge === "top" ? margin * s : parent.height - height - margin * s)
    property real drift: active ? 0 : (edge === "top" ? -7 : 7)
    x: parent ? (align === "left" ? margin * s : align === "right" ? Math.round(parent.width - width - margin * s) : Math.round((parent.width - width) / 2)) : 0
    y: Math.round(restY) + offsetY + drift
    opacity: active && !hidden ? 1 : 0
    visible: opacity > 0

    Behavior on opacity { NumberAnimation { duration: 160 } }
    Behavior on drift { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    Timer { id: hideTimer; onTriggered: hud.active = false }

    // показати повідомлення на ms мілісекунд; нове замінює попереднє без стрибків
    function show(label, text, ms, detail) {
        hud.label = label || "";
        hud.text = text || "";
        hud.detail = detail || "";
        hud.active = true;
        hideTimer.interval = ms > 0 ? ms : 1600;
        hideTimer.restart();
    }
    function hide() { hideTimer.stop(); hud.active = false; }

    // Текст режиму з C++ приходить готовим рядком: «🚗 Транспорт. F — назад «🚶 Пішки»».
    // Прибираємо емодзі, ділимо на назву й підказку, підказку скорочуємо до «F — пішки».
    // Якщо рядок незвичний — показуємо як є, лише без емодзі.
    function modeParts(raw) {
        const s = String(raw || "").replace(/[\uD83C-\uDBFF][\uDC00-\uDFFF]|[☀-➿]|️|‍/g, "").replace(/\s+/g, " ").replace(/«\s+/g, "«").replace(/\s+»/g, "»").trim();
        // «Транспорт (сів у транспорт). F — вийти» → «Транспорт» | «F — вийти»; «Точний рух увімкнено: Alt — вимкнути» → так само з двокрапкою
        const m = s.match(/^([^.…:]+)[.:]\s+(.+)$/);
        if (!m)
            return { text: s.replace(/\s*\([^)]*\)/g, ""), detail: "" };
        m[1] = m[1].replace(/\s*\([^)]*\)/g, "");
        let d = m[2].trim();
        const back = d.match(/^(\S+)\s+—\s+назад\s+«(.+)»\.?$/);
        if (back)
            d = back[1] + " — " + back[2].charAt(0).toLowerCase() + back[2].slice(1);
        return { text: m[1].trim(), detail: d };
    }

    // ── скло ──
    Rectangle {   // м'яка тінь, коли пігулка поверх гри (у чорній смузі тіні не видно й не треба)
        anchors.fill: parent
        anchors.topMargin: 2
        anchors.leftMargin: -1; anchors.rightMargin: -1; anchors.bottomMargin: -2
        radius: height / 2
        color: ap.shadow
        visible: !hud.inBand || hud.offsetY !== 0
        opacity: 0.45
    }
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: ap.dialog
        opacity: hud.inBand && hud.offsetY === 0 ? 0.72 : 0.9   // поверх гри скло щільніше, щоб текст читався
        border.width: 1
        border.color: ap.cardEdge
    }
    Rectangle {   // 121: рамка фокусу з клавіатури, як у меню (ap.cyan)
        anchors.fill: parent
        anchors.margins: -2
        radius: height / 2
        color: "transparent"
        border.width: 2
        border.color: ap.cyan
        visible: hud.ring
    }
    Rectangle {   // відблиск угорі: трохи об'єму
        anchors.fill: parent
        anchors.margins: 1
        radius: height / 2
        gradient: Gradient {
            GradientStop { position: 0; color: ap.cardTop }
            GradientStop { position: 0.55; color: "transparent" }
        }
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        x: hud.padX
        spacing: 9 * hud.s

        // риска заходу сонця
        Item {
            width: 3 * hud.s; height: 14 * hud.s
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                anchors.fill: parent; radius: width / 2
                visible: hud.toneGradient
                gradient: Gradient {
                    GradientStop { position: 0; color: ap.accentA }
                    GradientStop { position: 1; color: ap.accentB }
                }
            }
            Rectangle { anchors.fill: parent; radius: width / 2; visible: !hud.toneGradient; color: hud.tone }
        }
        Text {
            id: labelText
            anchors.verticalCenter: parent.verticalCenter
            visible: hud.label !== ""
            text: hud.label
            font.family: ap.display; font.weight: Font.Medium
            font.pixelSize: 12 * hud.s
            font.letterSpacing: 2 * hud.s
            font.capitalization: Font.AllUppercase
            color: ap.mute
        }
        Text {
            id: mainText
            anchors.verticalCenter: parent.verticalCenter
            visible: hud.text !== ""
            text: hud.text
            font.family: ap.body; font.weight: Font.DemiBold
            font.pixelSize: 15 * hud.s
            color: hud.textColor
        }
        Rectangle {   // тонка лінія між текстом і додатком (замість крапки)
            anchors.verticalCenter: parent.verticalCenter
            visible: hud.detail !== "" && hud.text !== ""
            width: 1; height: 12 * hud.s
            color: ap.edge
        }
        Text {
            id: detailText
            anchors.verticalCenter: parent.verticalCenter
            visible: hud.detail !== ""
            text: hud.detail
            font.family: ap.body; font.weight: Font.Medium
            font.pixelSize: 14 * hud.s
            color: ap.faint
            elide: Text.ElideRight
            // решту місця: усе, що лишилось від найбільшої ширини після інших частин рядка
            readonly property real otherW: 3 * hud.s + row.spacing
                + (labelText.visible ? labelText.implicitWidth + row.spacing : 0)
                + (mainText.visible ? mainText.implicitWidth + row.spacing : 0)
                + (hud.text !== "" ? 1 + row.spacing : 0)
            width: Math.max(40 * hud.s, Math.min(implicitWidth, hud.maxWidth - 2 * hud.padX - otherW))
        }
    }
}
