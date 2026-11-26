// AnyPlay 113: неблокуюча підказка під час гри — «Картинка просідає: знизити якість?».
// Показує StreamView за сигналом Chiaki.cloud.qualityHint() (кадрів на екрані помітно менше, ніж приходить, і спрощення
// обробки вже не допомагає). Не частіше ніж раз на 5 хв (лічить AnyPlayCloud).
// 121: живе в нижній чорній смузі (пігулка AnyPlayHud), а не поверх гри. Мишка й клавіші під час гри йдуть у гру, тому
// відповідати тут клавішею: ` (під Esc) або кнопка меню геймпада (Create 1 с) не відкривають меню, а беруть фокус на
// підказку (engaged; StreamView тоді забирає ввід у гри). Далі ←/→ (і A/D) обирають, Enter/✕ — обране, Esc/○ —
// «Не зараз». Сама ` ніколи не знижує якість: друге натискання — це «Не зараз». Без відповіді підказка зникає за 10 с,
// як «Не зараз».
import QtQuick

import org.streetpea.chiaking

AnyPlayHud {
    id: hint
    property bool shown: false
    property bool engaged: false            // відповідаємо клавішами: фокус і ввід у підказці, гра не отримує натискань
    property int sel: 0                     // 0 — «Знизити», 1 — «Не зараз»
    property string menuKey: "`"            // як назвати кнопку меню (StreamView додає кнопку геймпада)
    property bool pad: false                // є геймпад: підписи ✕ і ○
    signal lower()                          // «Знизити»: рівень нижче з перепідключенням
    AnyPlayStyle { id: hap }

    // куди знизимо: з «Ультра» одразу на «Оптимальну» (так і робить StreamView), інакше на рівень нижче
    readonly property int targetLevel: Chiaki.cloud.qualityLevel === 3 ? 1 : Math.max(0, Chiaki.cloud.qualityLevel - 1)
    readonly property string levelName: Chiaki.cloud.qualityLevel > 0
        ? [qsTr("Економна"), qsTr("Оптимальна"), qsTr("Максимальна"), qsTr("Ультра")][targetLevel] : ""

    edge: "bottom"
    active: shown
    ring: engaged
    label: qsTr("Картинка просідає")
    text: levelName !== "" ? qsTr("Знизити до «%1»?").arg(levelName) : qsTr("Знизити якість?")
    // на вузькому вікні додаток не вміщується поруч із кнопками: тоді без нього
    detail: parent && parent.width >= 1440 ? qsTr("гра перепідключиться на кілька секунд") : ""
    toneGradient: false
    tone: hap.gold

    function show() {
        sel = 0;
        shown = true;
        hide.restart();
    }
    // ` або кнопка меню геймпада, поки підказку видно: перше натискання — відповідати, друге — «Не зараз».
    // Повертає true, якщо натискання забрала підказка (тоді меню не відкриваємо)
    property double menuKeyAt: 0
    function menuKeyPressed() {
        if (!shown)
            return false;
        // кнопка меню геймпада може прийти двічі поспіль (сесія і Ctrl+O від геймпада): друге за 400 мс — те саме натискання
        const now = Date.now();
        if (now - menuKeyAt < 400)
            return true;
        menuKeyAt = now;
        if (engaged)
            choose(1);
        else {
            sel = 0;
            engaged = true;
            hide.restart();
        }
        return true;
    }
    function close() {
        hide.stop();
        engaged = false;
        shown = false;
        Chiaki.cloud.qualityHintDone();
    }
    function choose(i) {
        close();
        if (i === 0)
            lower();
    }
    Timer { id: hide; interval: 10000; onTriggered: hint.close() }   // без відповіді — як «Не зараз»

    Keys.onPressed: (e) => {
        if (!hint.engaged)
            return;
        e.accepted = true;   // поки відповідаємо, жодна клавіша не йде далі
        hide.restart();
        const k = String(Chiaki.settings.anyplayKeyName(e.key, e.modifiers, e.text, e.nativeScanCode || 0)).toUpperCase();
        if (e.key === Qt.Key_Left || k === "A")
            hint.sel = 0;
        else if (e.key === Qt.Key_Right || k === "D")
            hint.sel = 1;
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space)
            hint.choose(hint.sel);
        else if (e.key === Qt.Key_Escape || e.key === Qt.Key_Back)
            hint.choose(1);
    }

    Repeater {
        model: [qsTr("Знизити"), qsTr("Не зараз")]
        Rectangle {
            id: chip
            required property int index
            required property string modelData
            readonly property bool on: hint.engaged && hint.sel === index
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            height: Math.round(22 * hint.s)
            width: Math.round(chipText.implicitWidth + 20 * hint.s)
            radius: hap.chipRadius * hint.s
            color: chip.on ? hap.ink : hap.glass
            border.width: 1
            border.color: chip.on ? hap.ink : hap.edge
            Text {
                id: chipText
                anchors.centerIn: parent
                text: chip.modelData
                font.family: hap.display; font.weight: Font.Medium
                font.pixelSize: 12 * hint.s
                font.letterSpacing: 1.4 * hint.s
                font.capitalization: Font.AllUppercase
                color: chip.on ? hap.dark : hap.ink
            }
            MouseArea {   // мишка доходить сюди, коли підказка взяла ввід (після `)
                anchors.fill: parent
                onClicked: hint.choose(chip.index)
            }
        }
    }
    Text {
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        font.family: hap.body; font.weight: Font.Medium
        font.pixelSize: 13 * hint.s
        color: hint.engaged ? hap.cyan : hap.faint
        text: hint.engaged
            ? (hint.pad ? qsTr("Enter або ✕ — обрати, Esc або ○ — не зараз") : qsTr("Enter — обрати, Esc — не зараз"))
            : qsTr("%1 — відповісти").arg(hint.menuKey)
    }
}
