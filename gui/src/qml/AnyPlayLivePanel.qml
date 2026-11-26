// AnyPlay 116–118: меню гри → «Друзі й трансляція». Три розділи:
//   Трансляція     — почати (звук гри, «Відео для всіх браузерів»), що піде глядачам і скільки вихідного інтернету треба,
//                    стан (в ефірі, чекаю зв'язок), глядачі, «Посилання для всіх» (копіювати, QR), окремо Telegram і друзі
//   Голос і чат    — мікрофон для глядачів і гучність голосів, чат (пишеш тут, у грі повідомлення видно в чорних смугах)
//   Допомога друга — «Передати керування» (друг керує через трансляцію) і «Передати повністю» (друг грає зі своєї програми)
// Поки керує друг — угорі кожного розділу велика картка «Керує Андрій» з «Забрати керування» (фокус одразу на ній).
// Дані й дії — лише через AnyPlayLiveApi (api). Нічого важкого: звичайні рядки, без шарів і шейдерів; анімації —
// opacity / transform. Сторінку створює меню у фоні, коли на пункт уперше зайшли (див. AnyPlayStreamMenu).
// Навігація як у «Зображенні»: ↑↓ по елементах, ←→ по вкладках, ← з вмісту — на пункт меню ліворуч (navLeft).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtCore

import org.streetpea.chiaking

FocusScope {
    id: lp
    property var api: null                   // AnyPlayLiveApi
    property Item navLeft: null
    property string section: "live"          // live | chat | help
    property bool kbd: true
    property bool demo: false
    property var cloud: Chiaki.cloud
    AnyPlayStyle { id: ap }

    implicitHeight: col.implicitHeight
    readonly property real w: Math.min(width, 1400)
    readonly property bool wide: w >= 760
    readonly property real colW: wide ? Math.floor((w - 28) / 2) : w
    readonly property Item firstControl: api && api.friendControls ? takeBtn : lp

    readonly property var sections: [{ id: "live", text: qsTr("Трансляція") },
                                     { id: "chat", text: qsTr("Голос і чат"), badge: api ? api.unread : 0 },
                                     { id: "help", text: qsTr("Допомога друга") }]

    // чат під час гри (у чорних смугах): спільне налаштування з AnyPlayLiveHud (той самий ключ, читаємо методом value)
    Settings { id: prefs; category: "anyplay" }
    property bool chatInGame: true
    function readPrefs() { const v = prefs.value("liveChatInGame", true); chatInGame = v === true || v === "true"; }
    function setChatInGame(on) { chatInGame = on; prefs.setValue("liveChatInGame", on); if (typeof prefs.sync === "function") prefs.sync(); }

    // коротке повідомлення внизу сторінки («Посилання скопійовано»)
    property string note: ""
    function say(t) { note = t; noteTimer.restart(); }
    Timer { id: noteTimer; interval: 3500; onTriggered: lp.note = "" }

    // підтвердження «Передати повністю» тим самим натиском удруге (без вікон поверх меню)
    property var confirmId: null
    // перший натиск «Передати» ще й готує передачу (prepareHandover: друг заздалегідь отримує ключі приставки, тож
    // після «Так, передати» підключиться одразу); не підтвердили за 8 с — підготовку скасовуємо
    Timer {
        id: confirmTimer; interval: 8000
        onTriggered: lp.dropConfirm()
    }
    function dropConfirm() {
        confirmTimer.stop();
        if (confirmId !== null && api && api.handoff === "preparing") api.cancelHandoff();
        confirmId = null;
    }

    Connections { target: lp.api; ignoreUnknownSignals: true; function onMessage(text) { lp.say(text); } }

    // «Відео для всіх браузерів» діє з наступного підключення гри: гравець сам натискає «Перепідключити гру зараз»
    // (без його згоди гру не перепідключаємо). Ефір і посилання лишаються, глядачі зачекають кілька секунд.
    signal exitGame()
    function reconnectGame() {
        if (lp.demo) { say(qsTr("У грі тут гра перепідключилась би на кілька секунд у форматі H.264 (прогрес у грі не зникає).")); return; }
        api.holdForReconnect(180);
        if (lp.cloud) lp.cloud.reconnectOnce = true;
        lp.exitGame();
    }
    onVisibleChanged: {
        if (visible) { readPrefs(); if (api) api.loadConfig(); if (section === "chat" && api) api.markRead(); }
        else { dropConfirm(); note = ""; }
    }
    onSectionChanged: { dropConfirm(); if (section === "chat" && api) api.markRead(); }
    Component.onCompleted: readPrefs()

    function tr2(n) { return n === 1 ? qsTr("глядач") : (n >= 2 && n <= 4) ? qsTr("глядачі") : qsTr("глядачів"); }
    function timeOf(ts) { return lp.cloud && typeof lp.cloud.formatTime === "function" ? lp.cloud.formatTime(ts) : ""; }
    // друзі, яких ще немає серед глядачів (кого запросити)
    function notWatching() {
        if (!api) return [];
        const ids = {};
        for (let i = 0; i < api.viewers.length; i++) ids[api.viewers[i].id] = true;
        return api.friends.filter(f => !ids[f.id]);
    }
    // кому можна дати керування: друзі серед глядачів (гості за посиланням — лише дивляться)
    // кому передати гру повністю: друзі серед глядачів (C++ «Трансляції» передає учаснику кімнати), а якщо друзів
    // програма не знає — усі глядачі, крім гостей за посиланням
    function handoffTo() { return helpers(); }
    function helpers() { return (api ? api.viewers : []).filter(v => v.friend !== false); }
    function sendChat() {
        const t = chatField.text.trim();
        if (!t) return;
        if (api.sendChat(t)) chatField.text = "";
    }

    // ── навігація з клавіатури й геймпада (як у AnyPlayImage) ──
    function tabItems() {
        const out = [];
        for (let i = 0; i < tabs.children.length; i++) {
            const c = tabs.children[i];
            if (c.modelData !== undefined && c.visible) out.push(c);
        }
        return out;
    }
    function tabItem(id) {
        const t = tabItems();
        for (let i = 0; i < t.length; i++) if (t[i].modelData.id === id) return t[i];
        return t.length ? t[0] : null;
    }
    function focusables() {
        const out = [];
        function walk(it) {
            if (!it || !it.visible || it.enabled === false || it === tabs) return;
            if (it.activeFocusOnTab && it !== lp) out.push(it);
            const ch = it.children;
            for (let i = 0; i < ch.length; i++) walk(ch[i]);
        }
        walk(body);
        return out;
    }
    function current() { return Window.activeFocusItem; }
    function isTab(it) { return it && it.parent === tabs; }
    function focusTab() { const t = tabItem(section); if (t) t.forceActiveFocus(Qt.TabFocusReason); }
    function moveSection(d) {
        let i = 0;
        for (let k = 0; k < sections.length; k++) if (sections[k].id === section) i = k;
        i = Math.max(0, Math.min(sections.length - 1, i + d));
        if (sections[i].id !== section) { section = sections[i].id; focusTab(); return true; }
        return false;
    }
    function moveRow(d) {
        const cur = current();
        const f = focusables();
        if (isTab(cur)) { if (d > 0 && f.length) f[0].forceActiveFocus(Qt.TabFocusReason); return; }
        let i = -1;
        for (let k = 0; k < f.length; k++) if (f[k] === cur || f[k].activeFocus) { i = k; break; }
        if (i < 0) { if (f.length) f[0].forceActiveFocus(Qt.TabFocusReason); return; }
        const j = i + d;
        if (j < 0) { focusTab(); return; }
        if (j < f.length) f[j].forceActiveFocus(Qt.TabFocusReason);
    }
    function moveCol(d) {
        if (isTab(current())) {
            if (moveSection(d)) return true;
            if (d < 0 && navLeft) { navLeft.forceActiveFocus(Qt.TabFocusReason); return true; }
            return false;
        }
        if (d < 0 && navLeft) { navLeft.forceActiveFocus(Qt.TabFocusReason); return true; }
        return false;
    }
    Keys.onUpPressed: (e) => { kbd = true; moveRow(-1); e.accepted = true; }
    Keys.onDownPressed: (e) => { kbd = true; moveRow(1); e.accepted = true; }
    Keys.onLeftPressed: (e) => { kbd = true; e.accepted = moveCol(-1); }
    Keys.onRightPressed: (e) => { kbd = true; e.accepted = moveCol(1); }
    Keys.onReturnPressed: (e) => { if (current() === lp) { focusTab(); e.accepted = true; } }
    onActiveFocusChanged: if (activeFocus && Window.activeFocusItem === lp) focusTab()

    ColumnLayout {
        id: col
        width: lp.w
        spacing: 0

        Item {
            id: body
            Layout.fillWidth: true
            implicitHeight: bodyCol.implicitHeight
            ColumnLayout {
                id: bodyCol
                width: parent.width
                spacing: 0

                ApTabs {
                    id: tabs
                    Layout.bottomMargin: 12
                    model: lp.sections
                    current: lp.section
                    compact: true
                    onActivated: (id) => { lp.section = id; lp.focusTab(); }
                    onClickedTab: lp.kbd = false
                }

                // ═════ керує друг: над усіма розділами ═════
                Item {
                    id: ctlCard
                    visible: !!lp.api && lp.api.friendControls
                    Layout.fillWidth: true
                    Layout.bottomMargin: 14
                    implicitHeight: ctlRow.implicitHeight + 28
                    Rectangle {
                        anchors.fill: parent
                        radius: ap.cardRadius
                        color: "#1f7fe6ff"
                        border.width: 1; border.color: "#997fe6ff"
                        Rectangle { x: 0; y: 10; width: 3; height: parent.height - 20; radius: 1.5; color: ap.cyan }
                    }
                    RowLayout {
                        id: ctlRow
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 20; rightMargin: 16 }
                        spacing: 16
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            ApText { role: "cap"; color: ap.cyan; text: qsTr("Керує друг: %1").arg(lp.api ? lp.api.controlBy : "") }
                            ApText {
                                Layout.fillWidth: true
                                role: "small"; color: ap.mute
                                text: lp.api && lp.api.takeBackKey
                                    ? qsTr("Твої клавіші й геймпад зараз не діють. Забрати можна тут, а просто в грі: %1.").arg(lp.api.takeBackKey)
                                    : qsTr("Твої клавіші й геймпад зараз не діють. Забрати можна тут: меню ` і Enter.")
                            }
                        }
                        ApButton {
                            id: takeBtn
                            focusPolicy: Qt.StrongFocus
                            text: qsTr("Забрати керування")
                            onClicked: { lp.api.takeControl(); lp.say(qsTr("Керування знову в тебе")); }
                        }
                    }
                }

                // ═════ ТРАНСЛЯЦІЯ ═════
                ColumnLayout {
                    visible: lp.section === "live"
                    Layout.fillWidth: true
                    spacing: 0

                    // модуля трансляції немає в цій збірці: чесно пояснюємо й нічого не вмикаємо
                    ApText {
                        visible: !!lp.api && !lp.api.supported
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        role: "lead"
                        text: lp.api ? lp.api.unsupportedText : ""
                    }
                    ApText {
                        visible: !!lp.api && !lp.api.supported
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.topMargin: 10
                        role: "small"
                        text: qsTr("Голосовий чат і «Допомога друга» працюють разом з трансляцією, тож у цій збірці їх теж немає. Друзі, подарунки й перегляд трансляцій друзів доступні в головному вікні, вкладка «Друзі».")
                    }

                    // вимкнено: що це, скільки інтернету треба, як почати
                    GridLayout {
                        visible: !!lp.api && lp.api.supported && !lp.api.on
                        Layout.fillWidth: true
                        columns: lp.wide ? 2 : 1
                        columnSpacing: 28
                        rowSpacing: 14
                        ColumnLayout {
                            Layout.preferredWidth: lp.colW
                            Layout.maximumWidth: lp.colW
                            Layout.alignment: Qt.AlignTop
                            spacing: 8
                            ApText {
                                Layout.fillWidth: true
                                role: "lead"
                                text: qsTr("Друзі дивляться твою гру з будь-якого пристрою: телефона, комп'ютера чи телевізора, просто в браузері, без програми й без Telegram. До %1 глядачів.").arg(lp.api ? lp.api.maxViewers : 5)
                            }
                            ApText {
                                Layout.fillWidth: true
                                role: "small"
                                text: qsTr("Твоїй грі це не заважає: програма нічого не перекодовує, а пересилає глядачам ті самі кадри й звук, що приходять з приставки. Тому глядачі бачять гру в тій самій якості, що й ти.")
                            }
                            Feature { Layout.topMargin: 6; title: qsTr("Відео твоєї гри"); sub: qsTr("та сама якість і кадри, що в тебе; звук гри — за бажанням") }
                            Feature { title: qsTr("Голос, як у Discord"); sub: qsTr("ти говориш, друзі коментують і підказують") }
                            Feature { title: qsTr("Чат"); sub: qsTr("повідомлення видно в чорній смузі під картинкою, гру не закривають") }
                            Feature { title: qsTr("Допомога друга"); sub: qsTr("друг може пройти складну місію за тебе"); hairline: false }
                        }
                        ColumnLayout {
                            Layout.preferredWidth: lp.colW
                            Layout.maximumWidth: lp.colW
                            Layout.alignment: Qt.AlignTop
                            spacing: 0
                            ApText { role: "cap"; text: qsTr("Що піде глядачам"); Layout.bottomMargin: 6 }
                            ApText {
                                Layout.fillWidth: true
                                role: "body"
                                text: lp.api && lp.api.gameText ? qsTr("Гра зараз: %1").arg(lp.api.gameText) : qsTr("Гра зараз: чекаю картинку…")
                            }
                            ApText {
                                visible: !!lp.api && lp.api.needKbps > 0
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                role: "small"
                                text: lp.api ? qsTr("Трансляція відправляє в інтернет стільки ж, скільки гра приходить до тебе. Потрібно вихідного інтернету: від %1 Мбіт/с.").arg(lp.api.mbps(lp.api.needKbps))
                                               + (lp.api.uplinkKbps > 0 ? " " + qsTr("Остання перевірка: %1 Мбіт/с.").arg(lp.api.mbps(lp.api.uplinkKbps)) : "") : ""
                            }
                            ApText {
                                visible: !!lp.api && lp.api.browserNote !== ""
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                role: "small"
                                text: lp.api ? lp.api.browserNote : ""
                            }
                            ApOpt {
                                Layout.topMargin: 8
                                radio: false
                                text: qsTr("Звук гри")
                                sub: startQ.audio ? qsTr("глядачі чують гру і твій голос") : qsTr("глядачі чують лише твій голос")
                                checked: startQ.audio
                                onClicked: startQ.audio = !startQ.audio
                                ApSwitch { activeFocusOnTab: false; checked: startQ.audio; onToggled: startQ.audio = !startQ.audio }
                            }
                            CompatOpt {}
                            ApButton {
                                id: startBtn
                                Layout.topMargin: 14
                                enabled: !!lp.api && lp.api.featLive
                                focusPolicy: Qt.StrongFocus
                                text: lp.api && lp.api.state === "error" ? qsTr("Спробувати ще раз") : qsTr("Почати трансляцію")
                                onClicked: lp.api.start(startQ.audio)
                            }
                            ApText {   // не вийшло (наприклад, бракує вихідного інтернету): чесна причина й що робити
                                visible: !!lp.api && lp.api.state === "error" && lp.api.reason !== ""
                                Layout.fillWidth: true
                                Layout.topMargin: 10
                                role: "small"; color: ap.gold
                                text: lp.api ? lp.api.reason : ""
                            }
                            ApText {
                                visible: !!lp.api && lp.api.featLive && lp.api.state !== "error"
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                role: "small"
                                text: qsTr("Перед стартом програма кілька секунд перевіряє інтернет на відправлення. Якщо його бракує, скаже одразу, а не зупинятиме ефір посеред гри.")
                            }
                            ApText {   // власник вимкнув трансляції в CRM або ще не вписав ключі
                                visible: !!lp.api && !lp.api.featLive
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                role: "small"; color: ap.gold
                                text: qsTr("Трансляції зараз вимкнені: їх вмикає власник AnyPlay.")
                            }
                            QtObject { id: startQ; property bool audio: lp.api ? lp.api.gameAudio : true }
                        }
                    }

                    // увімкнено: стан, глядачі, посилання, налаштування
                    RowLayout {
                        visible: !!lp.api && lp.api.on
                        Layout.fillWidth: true
                        Layout.bottomMargin: 10
                        spacing: 8
                        ApChip {
                            kind: !lp.api ? "" : lp.api.state === "reconnecting" ? "wait" : lp.api.state === "on" ? "live" : ""
                            text: !lp.api ? "" : lp.api.state === "reconnecting" ? qsTr("Чекаю зв'язок")
                                : lp.api.state === "checking" ? qsTr("Перевіряю інтернет…")
                                : lp.api.state === "starting" ? qsTr("Підключаю…") : qsTr("В ефірі")
                        }
                        ApChip {
                            visible: !!lp.api && lp.api.sendText !== ""
                            kind: lp.api && lp.api.viewersLag ? "wait" : ""
                            text: lp.api ? lp.api.sendText : ""
                        }
                        ApChip {
                            text: lp.api ? qsTr("%1 з %2 %3").arg(lp.api.viewers.length).arg(lp.api.maxViewers).arg(lp.tr2(lp.api.maxViewers)) : ""
                        }
                        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                    }
                    ApText {
                        visible: !!lp.api && lp.api.on && (lp.api.reason !== "" || lp.api.viewersLag)
                        Layout.fillWidth: true; Layout.maximumWidth: 900
                        Layout.bottomMargin: 10
                        role: "small"
                        color: ap.gold
                        text: !lp.api ? "" : lp.api.reason !== "" ? lp.api.reason
                            : qsTr("Інтернет на відправлення не встигає за грою, тож у глядачів картинка часом завмирає на мить. Твоя гра йде як є, ефір не зупиняється.")
                    }
                    GridLayout {
                        visible: !!lp.api && lp.api.on
                        Layout.fillWidth: true
                        columns: lp.wide ? 2 : 1
                        columnSpacing: 28
                        rowSpacing: 14
                        // ліворуч: глядачі й посилання
                        ColumnLayout {
                            Layout.preferredWidth: lp.colW
                            Layout.maximumWidth: lp.colW
                            Layout.alignment: Qt.AlignTop
                            spacing: 0
                            ApText { role: "cap"; text: qsTr("Глядачі") }
                            ApText {
                                visible: !!lp.api && lp.api.viewers.length === 0
                                Layout.fillWidth: true
                                Layout.topMargin: 6
                                role: "small"
                                text: qsTr("Поки нікого. Надішли посилання нижче.")
                            }
                            Repeater {
                                model: lp.api ? lp.api.viewers : []
                                ViewerRow { required property var modelData; v: modelData }
                            }
                            ApText { role: "cap"; text: qsTr("Посилання для всіх"); Layout.topMargin: 16; Layout.bottomMargin: 6 }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                // QR для телефона чи телевізора: сервер картинки не дає, малюємо самі з посилання для браузера
                                AnyPlayQr {
                                    visible: !!lp.api && lp.api.qr === "" && valid
                                    Layout.preferredWidth: 112; Layout.preferredHeight: 112
                                    Layout.alignment: Qt.AlignTop
                                    text: lp.api ? lp.api.qrText : ""
                                }
                                Rectangle {
                                    visible: !!lp.api && lp.api.qr !== ""
                                    Layout.preferredWidth: 112; Layout.preferredHeight: 112
                                    radius: ap.radiusSmall
                                    color: "#ffffff"
                                    Image { anchors.fill: parent; anchors.margins: 5; source: parent.visible ? lp.api.qr : ""; fillMode: Image.PreserveAspectFit; smooth: false; asynchronous: true }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Text {
                                        Layout.fillWidth: true
                                        text: lp.api ? lp.api.qrText.replace(/^https?:\/\//, "") : ""
                                        elide: Text.ElideMiddle
                                        font.family: ap.body; font.pixelSize: ap.fsSub
                                        color: ap.mute
                                    }
                                    Text {   // код кімнати: друг може ввести його на сторінці трансляції чи в боті
                                        visible: !!lp.api && lp.api.code !== ""
                                        text: qsTr("код %1").arg(lp.api ? lp.api.code : "")
                                        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 17; font.letterSpacing: 3
                                        color: ap.gold
                                    }
                                    ApButton {
                                        small: true
                                        focusPolicy: Qt.StrongFocus
                                        text: qsTr("Копіювати посилання")
                                        onClicked: { lp.api.copyWebLink(); lp.say(qsTr("Посилання скопійовано. Воно відкривається в будь-якому браузері: на телефоні, комп'ютері чи телевізорі, без програми й без входу.")); }
                                    }
                                }
                            }
                            ApText {
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                role: "small"
                                text: qsTr("Посилання чи QR відкриваються в будь-якому браузері. Глядач лише пише ім'я, ні програма, ні Telegram не потрібні.")
                            }
                            Flow {
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                spacing: 8
                                ApButton {
                                    small: true; ghost: true
                                    focusPolicy: Qt.StrongFocus
                                    text: qsTr("Надіслати в Telegram")
                                    onClicked: {
                                        lp.cloud.openExternal("https://t.me/share/url?url=" + encodeURIComponent(lp.api.watchUrl)
                                                              + "&text=" + encodeURIComponent(qsTr("Дивись, як я граю в AnyPlay")));
                                        lp.say(qsTr("Відкрив Telegram: обери друга. Гра тут іде далі."));
                                    }
                                }
                                Repeater {   // друзям — запрошення в бот, з кнопкою «Дивитись»
                                    model: lp.api && lp.api.canInvite ? lp.notWatching() : []
                                    ApButton {
                                        required property var modelData
                                        small: true; ghost: true
                                        focusPolicy: Qt.StrongFocus
                                        text: "+ " + modelData.name
                                        onClicked: { lp.api.invite(modelData.id); lp.say(qsTr("Запрошення надіслано в бот: %1").arg(modelData.name)); }
                                    }
                                }
                            }
                        }
                        // праворуч: що бачать глядачі
                        ColumnLayout {
                            Layout.preferredWidth: lp.colW
                            Layout.maximumWidth: lp.colW
                            Layout.alignment: Qt.AlignTop
                            spacing: 0
                            ApText { role: "cap"; text: qsTr("Що бачать глядачі"); Layout.bottomMargin: 6 }
                            ApText {
                                Layout.fillWidth: true
                                role: "body"
                                text: lp.api && lp.api.gameText ? qsTr("Гру як у тебе: %1").arg(lp.api.gameText) : qsTr("Гру як у тебе")
                            }
                            ApText {
                                visible: !!lp.api && lp.api.browserNote !== ""
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                role: "small"
                                text: lp.api ? lp.api.browserNote : ""
                            }
                            ApOpt {
                                Layout.topMargin: 8
                                radio: false
                                text: qsTr("Звук гри")
                                sub: lp.api && lp.api.gameAudio ? qsTr("глядачі чують гру і твій голос") : qsTr("глядачі чують лише твій голос")
                                checked: !!lp.api && lp.api.gameAudio
                                onClicked: lp.api.setGameAudio(!lp.api.gameAudio)
                                ApSwitch { activeFocusOnTab: false; checked: !!lp.api && lp.api.gameAudio; onToggled: lp.api.setGameAudio(!lp.api.gameAudio) }
                            }
                            CompatOpt {}
                            ApText {
                                Layout.fillWidth: true
                                Layout.topMargin: 10
                                role: "small"
                                text: qsTr("Ефір іде, доки ти його не зупиниш. Якщо зникне інтернет, глядачі зачекають, а трансляція повернеться сама.")
                            }
                            ApButton {
                                Layout.topMargin: 14
                                danger: true
                                focusPolicy: Qt.StrongFocus
                                text: qsTr("Зупинити трансляцію")
                                onClicked: { lp.api.stop(); lp.say(qsTr("Трансляцію зупинено. Глядачі побачать, що ефір закінчився.")); }
                            }
                        }
                    }
                }

                // ═════ ГОЛОС І ЧАТ ═════
                GridLayout {
                    visible: lp.section === "chat"
                    Layout.fillWidth: true
                    columns: lp.wide ? 2 : 1
                    columnSpacing: 28
                    rowSpacing: 14
                    // чат
                    ColumnLayout {
                        Layout.preferredWidth: lp.colW
                        Layout.maximumWidth: lp.colW
                        Layout.alignment: Qt.AlignTop
                        spacing: 6
                        ApText { role: "cap"; text: qsTr("Чат") }
                        ApText {
                            visible: !!lp.api && lp.api.chat.length === 0
                            Layout.fillWidth: true
                            role: "small"
                            text: lp.api && lp.api.on ? qsTr("Тут пишуть глядачі. Під час гри їхні повідомлення видно в чорній смузі під картинкою.")
                                                      : qsTr("Чат з'явиться, коли почнеш трансляцію.")
                        }
                        Column {   // останні повідомлення (до 8; давніші — у глядачів на сторінці трансляції)
                            Layout.fillWidth: true
                            spacing: 6
                            Repeater {
                                model: lp.api ? lp.api.chat.slice(-8) : []
                                ChatBubble { required property var modelData; m: modelData; width: parent.width }
                            }
                        }
                        RowLayout {
                            visible: !!lp.api && lp.api.on
                            Layout.fillWidth: true
                            Layout.topMargin: 4
                            spacing: 8
                            ApField {
                                id: chatField
                                Layout.fillWidth: true
                                placeholderText: qsTr("Написати глядачам…")
                                maximumLength: 300
                                activeFocusOnTab: true
                                onAccepted: lp.sendChat()
                            }
                            ApButton {
                                small: true
                                focusPolicy: Qt.StrongFocus
                                enabled: chatField.text.trim() !== ""
                                text: qsTr("Надіслати")
                                onClicked: lp.sendChat()
                            }
                        }
                    }
                    // голос
                    ColumnLayout {
                        Layout.preferredWidth: lp.colW
                        Layout.maximumWidth: lp.colW
                        Layout.alignment: Qt.AlignTop
                        spacing: 0
                        ApText { role: "cap"; text: qsTr("Голос"); Layout.bottomMargin: 4 }
                        ApOpt {
                            radio: false
                            enabled: !!lp.api && lp.api.micReady
                            text: qsTr("Мікрофон для глядачів")
                            sub: !lp.api || !lp.api.micReady ? qsTr("мікрофона немає або система не дала дозволу")
                                : lp.api.mic ? (lp.api.speaking ? qsTr("тебе чути зараз") : qsTr("увімкнено: глядачі чують тебе, на приставку не йде"))
                                : qsTr("вимкнено")
                            checked: !!lp.api && lp.api.mic
                            onClicked: lp.api.setMic(!lp.api.mic)
                            ApSwitch { activeFocusOnTab: false; checked: !!lp.api && lp.api.mic; onToggled: lp.api.setMic(!lp.api.mic) }
                        }
                        VolumeRow {
                            visible: !!lp.api && lp.api.mic && lp.api.hasMicVolume
                            maxValue: 200   // 100 — як є, до 200 — підсилити тихий мікрофон
                            label: qsTr("Гучність мікрофона")
                            value: lp.api ? lp.api.micVolume : 100
                            onMoved: (v) => lp.api.setMicVolume(v)
                        }
                        ApOpt {
                            radio: false
                            text: qsTr("Голоси глядачів")
                            sub: lp.api && lp.api.voices ? qsTr("чути у твоїх навушниках поверх гри") : qsTr("вимкнено: глядачі тебе чують, ти їх ні")
                            checked: !!lp.api && lp.api.voices
                            onClicked: lp.api.setVoices(!lp.api.voices)
                            ApSwitch { activeFocusOnTab: false; checked: !!lp.api && lp.api.voices; onToggled: lp.api.setVoices(!lp.api.voices) }
                        }
                        VolumeRow {
                            visible: !!lp.api && lp.api.voices
                            label: qsTr("Гучність голосів")
                            value: lp.api ? lp.api.voicesVolume : 80
                            onMoved: (v) => lp.api.setVoicesVolume(v)
                        }
                        ApOpt {
                            radio: false
                            text: qsTr("Чат під час гри")
                            sub: lp.chatInGame ? qsTr("нові повідомлення видно кілька секунд у чорній смузі, потім згортаються")
                                               : qsTr("згорнуто: лише число нових повідомлень")
                            checked: lp.chatInGame
                            onClicked: lp.setChatInGame(!lp.chatInGame)
                            ApSwitch { activeFocusOnTab: false; checked: lp.chatInGame; onToggled: lp.setChatInGame(!lp.chatInGame) }
                        }
                    }
                }

                // ═════ ДОПОМОГА ДРУГА ═════
                ColumnLayout {
                    visible: lp.section === "help"
                    Layout.fillWidth: true
                    spacing: 0
                    ApText {
                        Layout.fillWidth: true; Layout.maximumWidth: 900
                        Layout.bottomMargin: 12
                        role: "hint"
                        text: qsTr("Друг пройде складну місію за тебе, навіть якщо в нього немає броні. Час броні не змінюється, керування завжди повертається до тебе, а кінець броні діє для всіх.")
                    }
                    GridLayout {
                        Layout.fillWidth: true
                        columns: lp.wide ? 2 : 1
                        columnSpacing: 20
                        rowSpacing: 14
                        // передати керування (через трансляцію)
                        HelpCard {
                            visible: !!lp.api && lp.api.featHelper
                            title: qsTr("Передати керування")
                            lead: qsTr("Друг дивиться трансляцію і керує твоєю грою: геймпадом, клавіатурою чи кнопками на телефоні. Без перепідключень, забрати можна будь-коли.")
                            hint: qsTr("Чесно: у друга затримка 0,3–0,6 с. Для перестрілок і гонок краще «Передати повністю».")
                            ApText {
                                visible: lp.helpers().length === 0
                                Layout.fillWidth: true
                                role: "small"; color: ap.gold
                                text: lp.api && lp.api.on ? qsTr("Друг має дивитись трансляцію: запроси його в розділі «Трансляція». Керування даємо лише друзям, не гостям за посиланням.")
                                                          : qsTr("Спершу почни трансляцію і запроси друга: керувати можна, лише коли він дивиться.")
                            }
                            Repeater {
                                model: lp.helpers()
                                ApRow {
                                    required property var modelData
                                    title: modelData.name
                                    subtitle: lp.api.friendControls && lp.api.controlBy === modelData.name ? qsTr("керує зараз") : qsTr("дивиться")
                                    hairline: true
                                    ApButton {
                                        small: true
                                        ghost: !(lp.api.friendControls && lp.api.controlBy === modelData.name)
                                        focusPolicy: Qt.StrongFocus
                                        text: lp.api.friendControls && lp.api.controlBy === modelData.name ? qsTr("Забрати") : qsTr("Дати керування")
                                        onClicked: {
                                            if (lp.api.friendControls && lp.api.controlBy === modelData.name) { lp.api.takeControl(); lp.say(qsTr("Керування знову в тебе")); }
                                            else { lp.api.giveControl(modelData.id); lp.say(qsTr("%1 керує. Забрати: кнопка вгорі або клавіша в грі").arg(modelData.name)); }
                                        }
                                    }
                                }
                            }
                        }
                        // передати повністю (друг підключається своєю програмою)
                        HelpCard {
                            visible: !!lp.api && lp.api.featHandoff
                            title: qsTr("Передати повністю")
                            lead: qsTr("Друг підключається до приставки своєю програмою AnyPlay, без затримки. Твоя гра тут м'яко зупиниться, а ти дивитимешся трансляцію друга, якщо він її ввімкне.")
                            hint: qsTr("Другу потрібна програма AnyPlay на комп'ютері чи Android. Повернути гру собі можна будь-коли: «Повернути собі» в головному вікні, на вкладці «Гра» чи «Друзі».")
                            ApText {
                                visible: !!lp.api && lp.api.handoff === "preparing" && lp.confirmId === null
                                Layout.fillWidth: true
                                role: "small"; color: ap.cyan
                                text: qsTr("Готуємо приставку, грати буде %1. Гра тут зупиниться за кілька секунд.").arg(lp.api ? lp.api.handoffTo : "")
                            }
                            ApButton {
                                visible: !!lp.api && lp.api.handoff === "preparing" && lp.confirmId === null
                                small: true; ghost: true
                                focusPolicy: Qt.StrongFocus
                                text: qsTr("Скасувати")
                                onClicked: lp.api.cancelHandoff()
                            }
                            ApText {
                                visible: !!lp.api && lp.api.handoff === "" && lp.handoffTo().length === 0
                                Layout.fillWidth: true
                                role: "small"; color: ap.gold
                                text: qsTr("Друг має дивитись твою трансляцію: почни її і запроси друга в розділі «Трансляція».")
                            }
                            Repeater {
                                model: lp.api && (lp.api.handoff === "" || lp.confirmId !== null) ? lp.handoffTo() : []
                                ApRow {
                                    id: fr
                                    required property var modelData
                                    readonly property bool asking: lp.confirmId === modelData.id
                                    title: modelData.name
                                    subtitle: asking ? qsTr("натисни ще раз, щоб передати") : qsTr("дивиться трансляцію")
                                    subColor: asking ? ap.gold : ap.faint
                                    hairline: true
                                    ApButton {
                                        small: true
                                        ghost: !fr.asking
                                        focusPolicy: Qt.StrongFocus
                                        text: fr.asking ? qsTr("Так, передати") : qsTr("Передати")
                                        onClicked: {
                                            if (lp.confirmId === modelData.id) { confirmTimer.stop(); lp.confirmId = null; lp.api.handoffFull(modelData.id); }
                                            else { lp.confirmId = modelData.id; confirmTimer.restart(); lp.api.prepareHandoff(modelData.id); }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // коротке повідомлення про дію
                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    text: lp.note
                    opacity: lp.note !== "" ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: ap.tPage } }
                    wrapMode: Text.WordWrap
                    font.family: ap.body; font.pixelSize: ap.fsSub; font.weight: Font.Medium
                    color: ap.ok
                }
            }
        }
    }

    // ── глядач: ім'я, хто говорить, без звуку, прибрати ──
    component ViewerRow: ApRow {
        property var v: ({})
        title: v.name || ""
        subtitle: (v.role === "helper" ? qsTr("керує твоєю грою") : v.speaking ? qsTr("говорить") : v.friend === true ? qsTr("друг, дивиться")
                   : v.friend === false ? qsTr("дивиться за посиланням") : qsTr("дивиться"))
                  + (v.muted ? qsTr(", без звуку") : "")
        subColor: v.role === "helper" ? ap.cyan : v.speaking ? ap.ok : ap.faint
        ApButton {
            visible: lp.api.canMute
            small: true; ghost: true
            focusPolicy: Qt.StrongFocus
            text: v.muted ? qsTr("Чути") : qsTr("Без звуку")
            onClicked: lp.api.muteViewer(v.id, !v.muted)
        }
        ApButton {
            small: true; ghost: true
            focusPolicy: Qt.StrongFocus
            text: qsTr("Прибрати")
            onClicked: { lp.api.removeViewer(v.id); lp.say(qsTr("%1 більше не дивиться").arg(v.name)); }
        }
    }

    // ── повідомлення чату: ім'я кольором акценту, текст; свої праворуч, системні — блідим рядком ──
    component ChatBubble: Item {
        id: cb
        property var m: ({})
        implicitHeight: m.system ? sys.implicitHeight + 2 : bubble.height
        Text {
            id: sys
            visible: !!cb.m.system
            width: parent.width
            text: cb.m.text || ""
            wrapMode: Text.WordWrap
            font.family: ap.body; font.pixelSize: 12; font.italic: true
            color: ap.faint
        }
        Rectangle {
            id: bubble
            visible: !cb.m.system
            readonly property real maxW: cb.width * 0.86
            width: Math.min(maxW, Math.max(nameT.implicitWidth, textT.implicitWidth) + 24)
            height: bubCol.implicitHeight + 14
            x: cb.m.mine ? cb.width - width : 0
            radius: 12
            color: cb.m.mine ? "#33ff6a6a" : ap.glass
            border.width: 1; border.color: cb.m.mine ? "#55ff6a6a" : ap.cardEdge
            Column {
                id: bubCol
                x: 12; y: 7
                width: bubble.width - 24
                spacing: 2
                Text {
                    id: nameT
                    visible: !cb.m.mine
                    text: (cb.m.name || "") + (cb.m.ts ? "  " + lp.timeOf(cb.m.ts) : "")
                    font.family: ap.body; font.pixelSize: 12; font.weight: Font.DemiBold
                    color: ap.accentA
                }
                Text {
                    id: textT
                    width: Math.min(implicitWidth, bubble.maxW - 24)
                    text: cb.m.text || ""
                    wrapMode: Text.Wrap
                    font.family: ap.body; font.pixelSize: ap.fsSub + 1
                    color: ap.ink
                }
            }
        }
    }

    // ── гучність: підпис, повзунок, відсотки ──
    component VolumeRow: RowLayout {
        id: vr
        property string label
        property int value: 100
        property int maxValue: 100
        signal moved(int v)
        Layout.fillWidth: true
        Layout.leftMargin: 14
        Layout.topMargin: 2
        Layout.bottomMargin: 6
        spacing: 12
        ApText { role: "small"; text: vr.label }
        Slider {
            id: vs
            Layout.fillWidth: true
            from: 0; to: vr.maxValue; stepSize: 5
            value: vr.value
            focusPolicy: Qt.StrongFocus
            activeFocusOnTab: true
            onMoved: vr.moved(Math.round(value))
            background: Rectangle {
                x: vs.leftPadding
                y: vs.topPadding + vs.availableHeight / 2 - height / 2
                width: vs.availableWidth
                height: 2
                color: "#40ffffff"
                Rectangle { width: vs.visualPosition * parent.width; height: parent.height; color: ap.ink }
            }
            handle: Rectangle {
                x: vs.leftPadding + vs.visualPosition * (vs.availableWidth - width)
                y: vs.topPadding + vs.availableHeight / 2 - height / 2
                width: 14; height: 14; radius: 7
                color: ap.ink
                border.width: vs.visualFocus ? 2 : 0
                border.color: ap.cyan
            }
        }
        ApChip { text: Math.round(vs.value) + "%" }
    }

    // ── «Відео для всіх браузерів»: гра в H.264, щоб відео відкривалось будь-де (діє з наступного підключення гри) ──
    component CompatOpt: ColumnLayout {
        visible: !!lp.api && lp.api.canCompat
        Layout.fillWidth: true
        spacing: 0
        ApOpt {
            radio: false
            text: qsTr("Відео для всіх браузерів")
            sub: lp.api && lp.api.compatVideo
                ? qsTr("гра йде у форматі H.264: відео відкривається будь-де; у тебе картинка трохи менш чітка при тій самій швидкості")
                : qsTr("вимкнено: формат, як дає приставка, у тебе найчіткіша картинка")
            checked: !!lp.api && lp.api.compatVideo
            onClicked: lp.api.setCompatVideo(!lp.api.compatVideo)
            ApSwitch { activeFocusOnTab: false; checked: !!lp.api && lp.api.compatVideo; onToggled: lp.api.setCompatVideo(!lp.api.compatVideo) }
        }
        ApText {
            visible: !!lp.api && lp.api.compatPending
            Layout.fillWidth: true
            Layout.topMargin: 6
            role: "small"; color: ap.gold
            text: qsTr("Почне діяти після перепідключення гри: це 5–10 секунд, прогрес у грі не зникає. Ефір і посилання лишаються, глядачі зачекають.")
        }
        ApButton {
            visible: !!lp.api && lp.api.compatPending
            Layout.topMargin: 8
            small: true; ghost: true
            focusPolicy: Qt.StrongFocus
            text: qsTr("Перепідключити гру зараз")
            onClicked: lp.reconnectGame()
        }
    }

    // ── що вміє трансляція (коли ще не почали): рядок з назвою і підписом ──
    component Feature: ApRow {
        property string sub
        title: ""
        subtitle: sub
        titleSize: ap.fsBody
    }

    // ── картка варіанта допомоги: назва, пояснення, чесна примітка, далі вміст (друзі з кнопками) ──
    component HelpCard: ApCard {
        id: hc
        property string lead
        property string hint
        Layout.preferredWidth: lp.wide ? Math.floor((lp.w - 20) / 2) : lp.w
        Layout.maximumWidth: Layout.preferredWidth
        Layout.alignment: Qt.AlignTop
        padding: 18
        spacing: 8
        ApText { Layout.fillWidth: true; role: "body"; text: hc.lead }
        ApText { Layout.fillWidth: true; role: "small"; text: hc.hint }
    }
}
