// AnyPlay 116: трансляція для друзів під час гри — лише в чорних смугах над і під кадром (або тонко біля краю, коли
// смуг немає), у стилі AnyPlayHud. Гру не перекриває і нічого не робить, поки трансляція вимкнена.
//   Угорі праворуч: «ЕФІР 3 глядачі», хто говорить; пауза — золотим. Поки керує друг — замість цього блакитне
//   «КЕРУЄ ДРУГ Андрій | Забрати: F8».
//   Унизу ліворуч: нові повідомлення чату (скільки рядків влазить у смугу, без смуги — до 3), кожне ~9 с, далі згасають.
//   Згорнуто (меню → «Друзі й трансляція» → «Голос і чат» → «Чат під час гри»): лише «ЧАТ 2 нових».
// Легко для гри: жодних шарів і шейдерів, анімації opacity / transform, один таймер раз на секунду, лише поки є рядки.
// Події для короткої підказки вгорі (пауза, керування повернулось) — сигналом notice (StreamView показує в anyplayHud).
import QtQuick
import QtCore

Item {
    id: lh
    property var api: null                 // AnyPlayLiveApi
    property bool fits: true               // відео вписане з чорними смугами
    property real k: 1
    property bool hidden: false            // відкрите меню: ховаємо все
    signal notice(string label, string text, int ms)
    AnyPlayStyle { id: ap }

    readonly property bool active: !!api && api.available && (api.on || api.friendControls)

    // ── налаштування «Чат під час гри» (те саме, що в AnyPlayLivePanel; перечитуємо, коли закрилось меню) ──
    Settings { id: prefs; category: "anyplay" }
    property bool chatInGame: true
    function readPrefs() { const v = prefs.value("liveChatInGame", true); chatInGame = v === true || v === "true"; }
    onHiddenChanged: if (!hidden) readPrefs()
    Component.onCompleted: { readPrefs(); markSeen(); }

    // ── геометрія смуг (як у AnyPlayHud) ──
    readonly property real band: fits ? Math.max(0, (height - width * 9 / 16) / 2) : 0
    readonly property real lineH0: 26
    readonly property bool inBand: band >= lineH0 * (11 / 15) + 6
    readonly property real s: inBand ? Math.min(k, (band - 8) / lineH0) : k
    readonly property real lineH: Math.round(lineH0 * s)
    readonly property int maxLines: inBand ? Math.max(1, Math.min(3, Math.floor((band - 4) / (lineH + 3 * s)))) : 3
    readonly property real margin: 14 * s

    // ── нові повідомлення чату ──
    property var seen: ({})
    function markSeen() {
        const c = api ? api.chat : [];
        for (let i = 0; i < c.length; i++) seen[c[i].id] = true;
    }
    ListModel { id: lines }
    Connections {
        target: lh.api
        ignoreUnknownSignals: true
        function onChatChanged() {
            const c = lh.api.chat;
            const now = Date.now();
            for (let i = 0; i < c.length; i++) {
                const m = c[i];
                if (lh.seen[m.id]) continue;
                lh.seen[m.id] = true;
                if (m.mine) continue;
                lines.append({ mid: String(m.id), name: m.name || "", text: m.text || "", system: !!m.system,
                               until: now + (m.system ? 5000 : 9000) + Math.min(6000, (m.text || "").length * 60) });
            }
            while (lines.count > lh.maxLines) lines.remove(0);
            if (lines.count) { lh.fresh = true; freshTimer.restart(); }
        }
        function onStateChanged() {
            const st = lh.api.state;
            // ефір сам не стає на паузу: лише чекає, коли зник інтернет чи гра перепідключається
            if (st === "reconnecting")
                lh.notice(qsTr("Трансляція"), lh.api.reason || qsTr("Немає зв'язку, ефір повернеться сам"), 4000);
            else if (st === "on" && lh.prevState === "reconnecting")
                lh.notice(qsTr("Трансляція"), qsTr("Знову в ефірі"), 2500);
            else if (st === "error" && lh.api.reason)
                lh.notice(qsTr("Трансляція"), lh.api.reason, 6000);
            lh.prevState = st;
        }
        function onMessage(text) { lh.notice(qsTr("Трансляція"), text, 5000); }
        function onFriendControlsChanged() {
            if (lh.api.friendControls)
                lh.notice(qsTr("Керування"), qsTr("Керує %1").arg(lh.api.controlBy), 3000);
            else
                lh.notice(qsTr("Керування"), qsTr("Знову в тебе"), 2500);
        }
    }
    property string prevState: ""
    property bool fresh: false             // щойно прийшло нове повідомлення (для згорнутого чату поверх гри)
    Timer { id: freshTimer; interval: 6000; onTriggered: lh.fresh = false }
    Timer {
        interval: 1000; repeat: true
        running: lines.count > 0
        onTriggered: {
            const now = Date.now();
            for (let i = lines.count - 1; i >= 0; i--)
                if (lines.get(i).until < now) lines.remove(i);
        }
    }

    // ── угорі праворуч: ефір або «керує друг» ──
    AnyPlayHud {
        id: onAir
        edge: "top"; align: "right"
        fits: lh.fits
        k: lh.k
        hidden: lh.hidden
        active: lh.active
        readonly property var speakers: lh.api ? lh.api.viewers.filter(v => v.speaking && !v.muted) : []
        toneGradient: !lh.api || (!lh.api.friendControls && lh.api.state !== "reconnecting")
        tone: lh.api && lh.api.friendControls ? ap.cyan : ap.gold
        textColor: lh.api && lh.api.friendControls ? ap.cyan : lh.api && lh.api.state === "reconnecting" ? ap.gold : ap.ink
        label: lh.api && lh.api.friendControls ? qsTr("Керує друг") : qsTr("Ефір")
        text: !lh.api ? "" : lh.api.friendControls ? lh.api.controlBy
            : lh.api.state === "reconnecting" ? qsTr("чекаю зв'язок")
            : lh.api.state === "starting" || lh.api.state === "checking" ? qsTr("підключаю…")
            : qsTr("%1 %2").arg(lh.api.viewers.length).arg(lh.api.viewers.length === 1 ? qsTr("глядач") : lh.api.viewers.length >= 2 && lh.api.viewers.length <= 4 ? qsTr("глядачі") : qsTr("глядачів"))
        detail: !lh.api ? "" : lh.api.friendControls
            ? (lh.api.takeBackKey ? qsTr("Забрати: %1").arg(lh.api.takeBackKey) : qsTr("Забрати: ` і Enter"))
            : speakers.length ? qsTr("говорить %1").arg(speakers.map(v => v.name).join(", "))
            : lh.api.speaking && lh.api.mic ? qsTr("тебе чути") : ""
    }

    // ── унизу ліворуч: рядки чату ──
    Column {
        id: feed
        visible: lh.active && lh.chatInGame
        x: lh.margin
        spacing: 3 * lh.s
        readonly property real maxW: Math.min(lh.width * 0.42, 640 * lh.s)
        y: lh.inBand ? lh.height - lh.band + (lh.band - height) / 2 : lh.height - height - lh.margin
        opacity: lh.hidden ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 160 } }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 } }
        move: Transition { NumberAnimation { property: "y"; duration: 160; easing.type: Easing.OutCubic } }
        Repeater {
            model: lines
            ChatLine { }
        }
    }
    // згорнуто: «ЧАТ 2 нових» (у смузі — поки є непрочитані; поверх гри — 6 с після нового)
    AnyPlayHud {
        id: collapsed
        edge: "bottom"; align: "left"
        fits: lh.fits
        k: lh.k
        hidden: lh.hidden
        active: lh.active && !lh.chatInGame && !!lh.api && lh.api.unread > 0 && (lh.inBand || lh.fresh)
        label: qsTr("Чат")
        text: lh.api ? qsTr("%1 нових").arg(lh.api.unread) : ""
        detail: qsTr("прочитати: `")
    }

    // рядок чату: скло як у AnyPlayHud, ім'я кольором заходу сонця, текст; системні — блідим
    component ChatLine: Item {
        id: cl
        required property string name
        required property string text
        required property bool system
        width: Math.min(feed.maxW, row.implicitWidth + 2 * 12 * lh.s)
        height: lh.lineH
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: ap.dialog
            opacity: lh.inBand ? 0.72 : 0.9
            border.width: 1
            border.color: ap.cardEdge
        }
        Row {
            id: row
            x: 12 * lh.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8 * lh.s
            Text {
                id: who
                visible: !cl.system && cl.name !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: cl.name
                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 13 * lh.s
                color: ap.accentA
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: cl.text
                width: Math.min(implicitWidth, feed.maxW - 24 * lh.s - (who.visible ? who.implicitWidth + row.spacing : 0))
                elide: Text.ElideRight
                font.family: ap.body; font.weight: cl.system ? Font.Normal : Font.Medium; font.pixelSize: 14 * lh.s
                font.italic: cl.system
                color: cl.system ? ap.faint : ap.ink
            }
        }
    }
}
