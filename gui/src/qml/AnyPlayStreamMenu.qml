// AnyPlay: меню під час гри, у стилі паузи GTA. Одне й те саме для клієнта й адміна.
// Ліворуч пункти великими літерами, праворуч вміст обраного пункту; угорі скільки лишилось, унизу зв'язок.
// Пункти: повернутись у гру, продовжити бронювання, клавіші, зображення, керування приставкою, головне вікно, вийти з гри.
// AnyPlay 113: «Якість», «Картинка» й «Розширені налаштування» злиті в один пункт «Зображення» (AnyPlayImage: якість з
// прикладами, кольори, обробка, екран і звук, трансляція зараз) — однаковий для клієнта й адміна.
// Адмін: без «Продовжити бронювання», з вибором, чи переводити приставку в режим спокою, коли виходить з гри.
// Навігація: ↑↓ по пунктах, → чи Enter у вміст, ← назад на пункти, Esc (○ на геймпаді) з вмісту повертає на пункти,
// з пунктів закриває меню. Геймпад: «Керування» шле ті самі клавіші, поки меню відкрите; меню відкривається ще й за
// Chiaki.cloud.menuRequested() (кнопка на геймпаді) — див. StreamView.
// Гість (cloud.guest): без «Продовжити бронювання», угорі замість часу броні — гостьовий доступ.
// AnyPlay 115 (плавність): сторінки праворуч створюються один раз і лише ховаються; важкі сторінки («Клавіші»,
// головне вікно поверх гри) вантажаться у фоні (asynchronous), і лише коли на пункті справді зупинились: прохід
// стрілками повз них більше не підгальмовує. «Головне вікно», «Баланс», «Підтримка» відкриваються Enter / → / клацом,
// а не самим наведенням фокусу (раніше стрілка на «Головне вікно» одразу відкривала його поверх меню й забирала фокус).
// Анімації лише transform / opacity, 120–180 мс.
// AnyPlay 115 (перегляд для адміна): demo: true — те саме меню без гри (панель адміна, «Меню гри: перегляд»): дані —
// із заглушок нижче (час броні, якість, зв'язок, продовження), нічого не надсилає на сервер і не змінює налаштувань;
// дії, що в грі щось зробили б (вийти, перепідключити, відкрити головне вікно), лише кажуть про це сигналом demoEvent.
// AnyPlay 116: пункт «Друзі й трансляція» (AnyPlayLivePanel): трансляція для друзів, голос і чат, допомога друга.
// Є лише тоді, коли в програмі є модуль трансляції (Chiaki.live) і власник її не вимкнув. Сторінка створюється у фоні
// (asynchronous), коли на пункт уперше зайшли, і далі лише ховається: прохід стрілками повз нього не гальмує.
// Поки керує друг, меню відкривається одразу на цьому пункті: ` і Enter — «Забрати керування».
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: panel
    property string page: "back"     // back | extend | live | keys | image | console | home | wallet | support | exit
    property bool demo: false        // перегляд у панелі адміна, без гри
    property bool demoAdmin: false   // у перегляді: меню адміна замість меню клієнта
    readonly property bool admin: demo ? demoAdmin : Chiaki.cloud.admin === true
    readonly property bool guest: !demo && !admin && Chiaki.cloud.guest === true
    readonly property bool canExtend: !admin && !guest   // продовжувати бронювання може лише клієнт зі своєю бронню
    property string openPage: ""     // з якої сторінки відкрити меню (нагадування про кінець гри відкриває «Продовжити гру»)
    property int tick: 0
    // джерела даних: справжні або заглушки перегляду
    readonly property var cloud: demo ? demoCloud : Chiaki.cloud
    readonly property var sess: demo ? demoSession : Chiaki.session
    readonly property var win: demo ? demoWindow : Chiaki.window
    // меню відкривається клавішею ` (під Esc); Ctrl+O / Cmd+O теж працює, але не показуємо: Ctrl у GTA — «присісти»
    readonly property string menuKey: Chiaki.controllers.length
        ? qsTr("клавіша ` (під Esc) або %1 на геймпаді").arg(Chiaki.settings.stringForStreamMenuShortcut())
        : qsTr("клавіша ` (під Esc)")
    signal resume()   // закрити меню й повернутись у гру
    signal exit()     // завершити трансляцію
    signal demoEvent(string text)   // перегляд: що сталося б у грі
    // з чого почати фокус, коли меню відкрилось (з нагадування про кінець гри — одразу «Продовжити гру»)
    // (поки керує друг — одразу «Друзі й трансляція»: там «Забрати керування»)
    readonly property Item firstItem: liveApi.available && liveApi.friendControls ? liveBtn
                                    : openPage === "extend" && canExtend ? extendBtn : resumeBtn
    AnyPlayStyle { id: ap }
    // трансляція для друзів, голос, допомога друга: справжні дані або заглушки перегляду
    AnyPlayLiveApi { id: liveApi; demo: panel.demo }
    // друг узяв керування: сторінку з «Забрати керування» готуємо заздалегідь (у фоні), щоб ` і Enter спрацювали одразу
    Connections {
        target: liveApi
        function onFriendControlsChanged() { if (liveApi.friendControls) liveLoader.wanted = true; }
    }

    readonly property var items: [resumeBtn, extendBtn, liveBtn, keysBtn, imageBtn, consoleBtn, homeBtn, walletBtn, supportBtn, exitBtn]
    function itemFor(p) {
        for (let i = 0; i < items.length; i++)
            if (items[i].pageId === p)
                return items[i];
        return resumeBtn;
    }
    function focusFirst() { itemFor(page).forceActiveFocus(Qt.TabFocusReason); }
    function goMain() { page = "back"; resumeBtn.forceActiveFocus(); }
    // пункти, що відкривають головне вікно AnyPlay поверх гри (на весь екран)
    function isOverlayPage(p) { return p === "home" || p === "wallet" || p === "support"; }
    property string overlay: ""      // яке головне вікно зараз відкрите поверх меню ("" — жодне)
    function openOverlay(p) {
        if (panel.demo) {
            panel.demoEvent(p === "wallet" ? qsTr("У грі тут відкриється баланс поверх гри, гра йде далі.")
                          : p === "support" ? qsTr("У грі тут відкриється чат з підтримкою поверх гри, гра йде далі.")
                          : panel.admin ? qsTr("У грі тут відкриється панель адміна поверх гри, гра йде далі.")
                          : qsTr("У грі тут відкриється головне вікно AnyPlay поверх гри, гра йде далі."));
            return;
        }
        panel.page = p;
        panel.overlay = p;
        homeOver.wanted = true;
        if (homeOver.item) homeOver.show();
    }
    function closeOverlay(back) {
        panel.overlay = "";
        if (back) panel.page = "back";
        itemFor(panel.page).forceActiveFocus(Qt.TabFocusReason);
    }
    // перейти з лівого стовпця у вміст праворуч (Enter або →)
    function enterContent() {
        if (isOverlayPage(page)) { openOverlay(page); return; }
        const target = page === "exit" ? exitConfirm : (page === "image" ? imagePanel.firstControl : (page === "extend" ? extendPanel.firstOption
                     : (page === "keys" ? keysLoader.item : (page === "live" && liveLoader.item ? liveLoader.item.firstControl : null))));
        if (target && target.visible && target.enabled)
            target.forceActiveFocus(Qt.TabFocusReason);
        else {
            const next = itemFor(page).nextItemInFocusChain(true);
            if (next && next !== itemFor(page))
                next.forceActiveFocus(Qt.TabFocusReason);
        }
    }
    onVisibleChanged: {
        overlay = "";
        if (visible && liveApi.available && liveApi.friendControls)
            page = "live";
        else if (visible)
            page = openPage !== "" && (openPage !== "extend" || canExtend) && !isOverlayPage(openPage) ? openPage : "back";
        else
            page = "back";
    }
    // фокус на рядку, якого не видно (низьке вікно, сторінка прокручується): плавно прокрутити до нього
    readonly property Item focusNow: Window.activeFocusItem
    onFocusNowChanged: {
        const f = focusNow;
        if (!f || !panel.visible) return;
        const pages = [backPage, extendPage, livePage, imagePage, consolePage, overPage, exitPage];
        for (let i = 0; i < pages.length; i++) {
            const pf = pages[i];
            if (!pf.visible || !pf.interactive) continue;
            let it = f;
            while (it && it !== pf) it = it.parent;
            if (!it) continue;
            const p = f.mapToItem(pf.contentItem, 0, 0);
            const pad = 24;
            let y = pf.contentY;
            if (p.y < pf.contentY + pad) y = p.y - pad;
            else if (p.y + f.height > pf.contentY + pf.height - pad) y = p.y + f.height - pf.height + pad;
            pf.scrollTo(y);
            return;
        }
    }
    // Esc (○ на геймпаді): з вмісту праворуч — назад на пункти; з пунктів — закрити меню
    Keys.onEscapePressed: {
        const left = itemFor(page);
        if (page === "back" || left.activeFocus)
            panel.resume();
        else
            left.forceActiveFocus(Qt.TabFocusReason);
    }

    Timer { interval: 1000; repeat: true; running: panel.visible; onTriggered: panel.tick++ }

    function leftText() {
        tick;
        const cl = panel.cloud;
        if (panel.admin) {   // адмін грає без броні: показуємо, чий зараз час на приставці
            const a = cl.adminInfo || ({});
            if (a.current)
                return qsTr("Режим адміна. Зараз час броні: %1, до %2").arg(a.current.user).arg(cl.formatTime(a.current.end));
            const n = a.next || [];
            return n.length ? qsTr("Режим адміна. Наступна бронь: %1 о %2").arg(n[0].user).arg(cl.formatTime(n[0].start)) : qsTr("Режим адміна");
        }
        const sec = Math.floor(cl.endTs - Date.now() / 1000 - cl.clockSkew);
        if (!(cl.endTs > 0) || sec <= 0)
            return panel.guest ? qsTr("Гостьовий доступ") : "";
        const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), x = sec % 60;
        const left = (h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0");
        if (panel.guest)   // гість грає до початку найближчої чужої гри; якщо броней попереду немає, кінця не показуємо
            return sec > 11 * 3600 ? qsTr("Гостьовий доступ: приставка вільна")
                                   : qsTr("Гостьовий доступ до %1, лишилось %2").arg(cl.formatTime(cl.endTs)).arg(left);
        return qsTr("Лишилось %1, гра до %2").arg(left).arg(cl.formatTime(cl.endTs));
    }

    // ── перегляд без гри (demo): заглушки сесії, вікна й сервера; нічого не пишуть у налаштування й на сервер ──
    QtObject {
        id: demoCloud
        readonly property int t0: Math.floor(Date.now() / 1000)
        property bool admin: panel.demoAdmin
        property bool guest: false
        property int clockSkew: 0
        property int endTs: t0 + 2 * 3600 + 14 * 60 + 15
        property bool hasWallet: true
        property int supportUnread: 1
        property bool busy: false
        property bool reconnectOnce: false
        property var adminInfo: ({ current: { user: "Андрій", start: t0 - 3600, end: t0 + 3 * 3600 } })
        // «Зображення»: стартуємо з того, що стоїть на цьому комп'ютері, далі міняємо лише тут
        property bool autoQuality: Chiaki.cloud.autoQuality === true
        property int qualityLevel: Chiaki.cloud.qualityLevel
        property bool showStats: Chiaki.cloud.showStats === true
        property string pcTier: Chiaki.cloud.pcTier || "ok"
        property string pcInfo: Chiaki.cloud.pcInfo || ""
        property bool renderCapped: false
        property int renderCap: -1
        property int renderCappedFrom: -1
        // «Продовжити бронювання»: ціни як на сервері (+1/+2/+3 год), оплатити не можна
        property var extendInfo: ({ active: true, closed: false, end: endTs, method: "uah",
            methods: [{ code: "uah", label: "🇺🇦 Картка (гривні)" }, { code: "pln", label: "🇵🇱 BLIK / переказ (злоті)" }],
            options: [{ hours: 1, free: true, price: "75.00 грн", prices: { uah: "75.00 грн", pln: "6.50 zł" } },
                      { hours: 2, free: true, price: "150.00 грн", prices: { uah: "150.00 грн", pln: "13.00 zł" } },
                      { hours: 3, free: false, price: "225.00 грн", prices: { uah: "225.00 грн", pln: "19.50 zł" } }] })
        signal extendResult(bool ok, string text)
        function formatTime(ts) { return Chiaki.cloud.formatTime(ts); }
        function renderLabel(p) { return Chiaki.cloud.renderLabel(p); }
        function pcCanRender(p) { return Chiaki.cloud.pcCanRender(p); }
        function setQualityLevel(l) {
            qualityLevel = l;
            // як у програмі: рівень задає й типову обробку (Ультра — ШІ-чіткість)
            demoWindow.videoPreset = [ChiakiWindow.VideoPreset.Fast, ChiakiWindow.VideoPreset.Default, ChiakiWindow.VideoPreset.HighQuality, ChiakiWindow.VideoPreset.HighQualitySpatial][Math.max(0, Math.min(3, l))];
        }
        function setRenderPreset(p) {
            demoWindow.videoPreset = p;
            if (qualityLevel >= 2)   // «Ультра» = «Максимальна» + ШІ-чіткість: рівень іде за обробкою
                qualityLevel = p === ChiakiWindow.VideoPreset.HighQualitySpatial || p === ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial ? 3 : 2;
        }
        function clearRenderCap() { renderCapped = false; renderCap = -1; renderCappedFrom = -1; }
        function loadExtend() {}
        function extend(hours, method, how) { extendResult(true, qsTr("Перегляд: тут клієнт закріпив би +%1 год і побачив оплату. Нічого не надіслано.").arg(hours)); }
        function payExtend() {} function cancelBooking() {} function copyText() {}
    }
    QtObject {
        id: demoWindow
        property int videoPreset: Chiaki.window ? Chiaki.window.videoPreset : 2
        property int videoMode: 0
        property real zoomFactor: 0     // у справжнього вікна ZoomFactor (див. AnyPlayImage)
        property int streamFps: 60
        property int shownFps: 58
        property int droppedFrames: 0
        property real picBrightness: 0
        property real picContrast: 0
        property real picSaturation: 0
        property real picWarmth: 0
        readonly property bool picIsDefault: !picBrightness && !picContrast && !picSaturation && !picWarmth
        function resetPicture() { picBrightness = 0; picContrast = 0; picSaturation = 0; picWarmth = 0; }
    }
    QtObject {
        id: demoSession
        property bool connected: true
        property string host: "PS5"
        property real measuredBitrate: 14.6
        property bool measuredBitrateReady: true
        property real averagePacketLoss: 0.001
        property int framesLost: 0
        property bool muted: true
    }
    QtObject {   // гучність і «віддача на екрані» в перегляді
        id: demoPrefs
        property int audioVolume: 100
        property bool anyplayHapticScreen: false
    }
    readonly property var prefs: demo ? demoPrefs : Chiaki.settings
    // головні клавіші: беремо справжні призначення (з урахуванням змін клієнта)
    property int layoutRev: 0
    // чи є клавіші режимів (пішки, транспорт, літак) — для підказки про Fn на MacBook
    readonly property bool hasModes: {
        layoutRev;
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++)
            if (profiles[i].id === "global")
                for (let j = 0; j < profiles[i].bindings.length; j++)
                    if (profiles[i].bindings[j].id.indexOf("mode_") === 0)
                        return true;
        return false;
    }
    function keyRows() {
        layoutRev;
        const labels = { pause: qsTr("OPTIONS: пауза й меню в самій грі"), ps: qsTr("кнопка PS: меню приставки"), map: qsTr("тачпад: карта") };
        let rows = [{ name: qsTr("меню AnyPlay"), key: "`" }];
        const profiles = Chiaki.settings.anyplayProfiles();
        let modes = [];
        for (let i = 0; i < profiles.length; i++) {
            const p = profiles[i];
            for (let j = 0; j < p.bindings.length; j++) {
                const b = p.bindings[j];
                let key = b.keyName;
                if (Qt.platform.os === "osx" && b.key === "Home")
                    key = "Fn + ←";
                if (p.id === "global" && labels[b.id])
                    rows.push({ name: labels[b.id], key: key });
                else if (p.id === "global" && b.id.indexOf("mode_") === 0)
                    modes.push({ name: b.name, key: key });
                else if (p.id === "foot" && b.id === "vehicle")
                    rows.push({ name: qsTr("сісти в транспорт чи вийти"), key: key });
            }
        }
        return rows.concat(modes);
    }
    // рахуємо раз, коли меню відкрилось (а не щоразу, коли фокус проходить через «Повернутись у гру»)
    readonly property var keyRowsNow: { layoutRev; return panel.visible ? panel.keyRows() : []; }

    // Якість обрали на екрані «Зображення»: «Максимальна» і «Ультра» відрізняються лише обробкою на комп'ютері (без
    // перепідключення); інший рівень — перепідключення на кілька секунд (головний екран сам натисне «Грати»).
    // from — рівень ДО вибору (до 115 сюди потрапляв уже новий рівень, тож «Оптимальна» → «Максимальна» не
    // перепідключала гру і потік лишався 720p, хоча на екрані було «Максимальна»).
    function qualityPicked(level, from) {
        if (level === -1 || level === -2) return;   // «Авто» чи той самий рівень: лишаємося в меню
        if (level === from || (from >= 2 && level >= 2)) return;
        if (panel.demo) {
            panel.demoEvent(qsTr("У грі тут гра перепідключилась би на кілька секунд з новою якістю (прогрес у грі не зникає)."));
            return;
        }
        Chiaki.cloud.reconnectOnce = true;
        panel.page = "back";
        if (panel.admin && Chiaki.session)
            Chiaki.stopSession(false);       // адміну закриття вікна показало б питання про режим спокою: закриваємо лише трансляцію
        else
            panel.exit();
    }

    // ── фон: ніч Vice City — гра ледь проглядає крізь темне скло, знизу світіння заходу сонця ──
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            // гра під меню лише ледь проглядає: інакше текст зливається з яскравою картинкою
            GradientStop { position: 0.0; color: "#f714091f" }
            GradientStop { position: 0.45; color: "#ee150a22" }
            GradientStop { position: 1.0; color: "#d8180b26" }
        }
    }
    Rectangle {   // світіння обрію: рожево-помаранчеве знизу
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.55
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#00ff4f8b" }
            GradientStop { position: 0.75; color: "#24ff4f8b" }
            GradientStop { position: 1.0; color: "#40ff8a3d" }
        }
    }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (wheel) => wheel.accepted = true }

    Item {
        id: zoom
        readonly property real k: Math.max(1, Math.min(2.2, Math.min(panel.width / 1600, panel.height / 1000)))
        readonly property bool low: height < 780          // 1280×720, 1366×768: щільніші пункти, щоб усе вмістилось без прокрутки
        width: panel.width / k
        height: panel.height / k
        scale: k
        transformOrigin: Item.TopLeft

        ColumnLayout {
            anchors { fill: parent; leftMargin: zoom.width < 900 ? 20 : 32; rightMargin: anchors.leftMargin; topMargin: zoom.low ? 16 : 28; bottomMargin: zoom.low ? 12 : 22 }
            spacing: 0

            // ── шапка ──
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                spacing: 20
                Column {
                    spacing: 6
                    Text {
                        text: qsTr("Пауза")
                        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: zoom.low ? 30 : 40
                        font.letterSpacing: 3; font.capitalization: Font.AllUppercase
                        color: ap.ink
                    }
                    Rectangle {   // смужка заходу сонця під заголовком
                        width: 64; height: 3; radius: 2
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                    }
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                // скільки лишилось: золота пігулка
                Rectangle {
                    visible: timeText.text !== ""
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: timeText.implicitWidth + 28
                    implicitHeight: timeText.implicitHeight + 14
                    radius: height / 2
                    color: ap.glass
                    border.width: 1; border.color: panel.admin ? ap.edge : "#66ffd27a"
                    Text {
                        id: timeText
                        anchors.centerIn: parent
                        text: panel.leftText()
                        color: panel.admin ? ap.mute : ap.gold
                        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: zoom.low ? 14 : 16
                        font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: zoom.low ? 20 : 30
                Layout.bottomMargin: zoom.low ? 18 : 22
                spacing: zoom.width < 1000 ? 40 : 56

                // ── ліворуч: пункти меню ──
                ColumnLayout {
                    readonly property real w: Math.max(230, Math.min(320, zoom.width * 0.25))
                    Layout.fillWidth: false
                    Layout.preferredWidth: w
                    Layout.maximumWidth: w
                    Layout.alignment: Qt.AlignTop
                    spacing: zoom.low ? 3 : 6
                    PauseItem { id: resumeBtn; pageId: "back"; text: qsTr("Повернутись у гру"); KeyNavigation.down: extendBtn }
                    PauseItem { id: extendBtn; pageId: "extend"; visible: panel.canExtend; text: qsTr("Продовжити бронювання"); KeyNavigation.up: resumeBtn; KeyNavigation.down: liveBtn }
                    // 116: трансляція для друзів; поки керує друг — блакитне, з позначкою «керує друг»
                    PauseItem {
                        id: liveBtn; pageId: "live"
                        // власник вимкнув у CRM і трансляцію, і допомогу друга — пункту немає (якщо трансляція вже йде — є)
                        visible: liveApi.available && (liveApi.featLive || liveApi.featHelper || liveApi.featHandoff || liveApi.on)
                        live: liveApi.on || liveApi.friendControls
                        text: liveApi.friendControls ? qsTr("Керує друг: забрати")
                            : liveApi.unread > 0 ? qsTr("Друзі й трансляція (%1)").arg(liveApi.unread) : qsTr("Друзі й трансляція")
                        KeyNavigation.up: extendBtn; KeyNavigation.down: keysBtn
                    }
                    PauseItem { id: keysBtn; pageId: "keys"; text: qsTr("Клавіші"); KeyNavigation.up: liveBtn; KeyNavigation.down: imageBtn }
                    PauseItem { id: imageBtn; pageId: "image"; text: qsTr("Зображення"); KeyNavigation.up: keysBtn; KeyNavigation.down: consoleBtn }
                    PauseItem { id: consoleBtn; pageId: "console"; text: qsTr("Керування приставкою"); KeyNavigation.up: imageBtn; KeyNavigation.down: homeBtn }
                    PauseItem { id: homeBtn; pageId: "home"; text: panel.admin ? qsTr("Панель адміна") : qsTr("Головне вікно AnyPlay"); KeyNavigation.up: consoleBtn; KeyNavigation.down: walletBtn }
                    // AnyPlay 110: баланс і підтримка, не виходячи з гри (відкривається головне вікно на потрібній вкладці)
                    PauseItem { id: walletBtn; pageId: "wallet"; visible: !panel.admin && panel.cloud.hasWallet === true; text: qsTr("Баланс"); KeyNavigation.up: homeBtn; KeyNavigation.down: supportBtn }
                    PauseItem { id: supportBtn; pageId: "support"; visible: !panel.admin; text: panel.cloud.supportUnread > 0 ? qsTr("Підтримка (%1)").arg(panel.cloud.supportUnread) : qsTr("Підтримка"); KeyNavigation.up: walletBtn; KeyNavigation.down: exitBtn }
                    PauseItem { id: exitBtn; pageId: "exit"; danger: true; text: qsTr("Вийти з гри"); KeyNavigation.up: supportBtn }
                }

                // ── праворуч: вміст обраного пункту ──
                // Усі сторінки створені один раз і лише ховаються (без перестворення під час руху стрілками);
                // нова сторінка з'являється коротким згасанням і зсувом (opacity + transform, без перекомпонування).
                Item {
                    id: content
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // скляна панель під вмістом (об'єм: світліша смужка вгорі, тінь)
                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: -18; anchors.rightMargin: -18; anchors.topMargin: -16; anchors.bottomMargin: -10
                        radius: ap.cardRadius
                        color: "#5a0c0618"
                        border.width: 1; border.color: ap.cardEdge
                        Rectangle { x: 1; y: 1; width: parent.width - 2; height: 1; color: ap.cardTop }
                    }

                    // повернутись у гру: гра не на паузі, гучність, головні клавіші
                    PageFlick {
                        id: backPage
                        visible: panel.page === "back"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; text: qsTr("Гра на паузі не стоїть") }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                role: "lead"
                                text: qsTr("Поки відкрите це меню, гра на приставці йде далі. Повернись пунктом ліворуч або клавішею Esc. Меню AnyPlay: %1.").arg(panel.menuKey)
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.maximumWidth: 620
                                Layout.topMargin: 4
                                spacing: 14
                                ApText { role: "cap"; text: qsTr("Гучність") }
                                MenuSlider {
                                    id: volume
                                    Layout.fillWidth: true
                                    from: 0; to: 128; stepSize: 1
                                    value: panel.prefs.audioVolume
                                    onMoved: panel.prefs.audioVolume = value
                                    KeyNavigation.left: resumeBtn
                                }
                                ApChip { text: ((volume.value / 128.0) * 100).toFixed(0) + "%" }
                            }
                            ApOpt {   // «віддача» для клавіатури: краї картинки темніють разом з вібрацією геймпада
                                Layout.fillWidth: true
                                Layout.maximumWidth: 620
                                text: qsTr("Віддача на екрані")
                                sub: Qt.platform.os === "osx"
                                    ? qsTr("Краї екрана темніють, коли в грі трясе, а трекпад ледь відчутно клацає. Лише для клавіатури й миші: геймпад вібрує сам.")
                                    : qsTr("Краї екрана темніють, коли в грі трясе. Лише для клавіатури й миші: геймпад вібрує сам.")
                                checked: panel.prefs.anyplayHapticScreen === true
                                onClicked: panel.prefs.anyplayHapticScreen = !checked
                                KeyNavigation.left: resumeBtn
                            }
                            ApText { role: "cap"; text: qsTr("Головні клавіші"); Layout.topMargin: 10 }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: panel.keyRowsNow
                                    Row {
                                        required property var modelData
                                        spacing: 6
                                        height: 24
                                        rightPadding: 10
                                        ApChip { anchors.verticalCenter: parent.verticalCenter; key: true; text: modelData.key }
                                        ApText { anchors.verticalCenter: parent.verticalCenter; role: "small"; color: ap.mute; wrapMode: Text.NoWrap; text: modelData.name }
                                    }
                                }
                            }
                            ApText {
                                visible: Qt.platform.os === "osx" && panel.hasModes
                                Layout.fillWidth: true
                                role: "small"
                                text: qsTr("На MacBook клавіші F1, F2, F3 натискай разом з Fn: Fn + F1.")
                            }
                        }
                    }

                    // продовжити гру
                    PageFlick {
                        id: extendPage
                        visible: panel.page === "extend"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; text: qsTr("Продовжити бронювання") }
                            ExtendPanel {
                                id: extendPanel
                                Layout.fillWidth: true
                                Layout.maximumWidth: 720
                                compact: true
                                cloud: panel.cloud
                                visible: panel.visible && panel.page === "extend"
                            }
                        }
                    }

                    // клавіші: екран керування з геймпадом (компактний варіант для гри)
                    // (фокус лишається на пунктах ліворуч; у клавіші — клацом, Enter чи →; Esc там закриває меню, як і всюди)
                    // Важкий екран: створюється у фоні (asynchronous) і лише коли на пункті «Клавіші» зупинились (140 мс)
                    // або його відкрили клацом / Enter; прохід стрілками повз «Клавіші» нічого не створює.
                    Loader {
                        id: keysLoader
                        property bool wanted: false
                        property bool focusOnLoad: false
                        anchors.fill: parent
                        // вміст — рівно по краях інших сторінок, смуга прокрутки — праворуч за ним, з відступом
                        anchors.leftMargin: -14
                        anchors.rightMargin: -14
                        asynchronous: true
                        active: panel.visible && wanted && panel.page === "keys"
                        visible: panel.page === "keys" && status === Loader.Ready
                        opacity: visible ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } }
                        onActiveChanged: if (!active) focusOnLoad = false
                        onLoaded: if (focusOnLoad) { focusOnLoad = false; item.forceActiveFocus(Qt.TabFocusReason); }
                        sourceComponent: Component {
                            AnyPlayControls {
                                inGame: true
                                sideInset: 14
                                onCloseRequested: panel.resume()
                            }
                        }
                    }
                    Timer { id: keysDelay; interval: 140; onTriggered: if (panel.page === "keys") keysLoader.wanted = true }
                    ApText {   // поки екран клавіш вантажиться у фоні
                        visible: panel.page === "keys" && keysLoader.status !== Loader.Ready
                        anchors.centerIn: parent
                        role: "small"; color: ap.faint
                        text: qsTr("Відкриваю клавіші…")
                    }
                    MouseArea {   // у перегляді клавіші лише показуємо: клац по них не змінює налаштувань цього комп'ютера
                        visible: panel.demo && keysLoader.visible
                        anchors.fill: keysLoader
                        acceptedButtons: Qt.AllButtons
                        onWheel: (wheel) => wheel.accepted = false
                    }

                    // 116: друзі й трансляція. Створюється у фоні, коли на пункт уперше зайшли, і далі лише ховається
                    PageFlick {
                        id: livePage
                        visible: panel.page === "live"
                        Loader {
                            id: liveLoader
                            property bool wanted: false
                            property bool focusOnLoad: false
                            width: content.width
                            asynchronous: true
                            active: wanted && liveApi.available
                            onLoaded: if (focusOnLoad) { focusOnLoad = false; if (panel.page === "live") item.firstControl.forceActiveFocus(Qt.TabFocusReason); }
                            sourceComponent: Component {
                                AnyPlayLivePanel {
                                    api: liveApi
                                    demo: panel.demo
                                    navLeft: liveBtn
                                }
                            }
                        }
                        ApText {   // поки сторінка вантажиться у фоні (перший раз, частки секунди)
                            visible: liveLoader.status !== Loader.Ready
                            role: "small"; color: ap.faint
                            text: qsTr("Відкриваю…")
                        }
                    }

                    // зображення: якість з прикладами, кольори, обробка, екран і звук, трансляція зараз (AnyPlay 113)
                    PageFlick {
                        id: imagePage
                        visible: panel.page === "image"
                        AnyPlayImage {
                            id: imagePanel
                            width: content.width
                            inGame: true
                            demo: panel.demo
                            cloud: panel.cloud
                            win: panel.win
                            sess: panel.sess
                            navLeft: imageBtn
                            onQualityPicked: (level, from) => panel.qualityPicked(level, from)
                        }
                    }

                    // керування самою приставкою
                    PageFlick {
                        id: consolePage
                        visible: panel.page === "console"
                        ColumnLayout {
                            width: content.width
                            spacing: 6
                            ApText { role: "cap"; text: qsTr("Керування приставкою") }
                            AnyPlayGuide {
                                Layout.fillWidth: true
                                columns: content.width >= 700 ? 2 : 1   // 1280×720 теж у дві колонки: без прокрутки
                                columnSpacing: 32
                                compact: true
                                menuKey: panel.menuKey
                            }
                        }
                    }

                    // головне вікно, баланс, підтримка: що відкриється (самим фокусом не відкриваємо)
                    PageFlick {
                        id: overPage
                        visible: panel.isOverlayPage(panel.page)
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText {
                                role: "cap"
                                text: panel.page === "wallet" ? qsTr("Баланс") : panel.page === "support" ? qsTr("Підтримка")
                                    : panel.admin ? qsTr("Панель адміна") : qsTr("Головне вікно AnyPlay")
                            }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                role: "lead"
                                text: panel.page === "wallet" ? qsTr("Баланс, поповнення й історія, не виходячи з гри. Гра на приставці йде далі.")
                                    : panel.page === "support" ? (panel.cloud.supportUnread > 0
                                        ? qsTr("Чат з підтримкою AnyPlay: є нові відповіді (%1). Гра на приставці йде далі.").arg(panel.cloud.supportUnread)
                                        : qsTr("Чат з підтримкою AnyPlay, не виходячи з гри. Гра на приставці йде далі."))
                                    : panel.admin ? qsTr("Хто грає, наступні броні, спільний PSN і інструменти, не виходячи з гри. Трансляція йде далі.")
                                    : qsTr("Броні, баланс, свій PSN і підтримка, не виходячи з гри. Гра на приставці йде далі.")
                            }
                            Row {
                                Layout.topMargin: 6
                                spacing: 14
                                ApButton {
                                    id: overOpen
                                    focusPolicy: Qt.StrongFocus
                                    text: panel.overlay !== "" && homeOver.status !== Loader.Ready ? qsTr("Відкриваю…") : qsTr("Відкрити")
                                    onClicked: panel.openOverlay(panel.page)
                                    KeyNavigation.left: panel.itemFor(panel.page)
                                }
                                ApText {
                                    anchors.verticalCenter: overOpen.verticalCenter
                                    role: "small"; color: ap.faint
                                    text: qsTr("або Enter")
                                }
                            }
                        }
                    }

                    // вийти з гри
                    PageFlick {
                        id: exitPage
                        visible: panel.page === "exit"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; color: ap.bad; text: qsTr("Вийти з гри") }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                role: "lead"; rich: true
                                text: {
                                    const cl = panel.cloud;
                                    if (panel.admin) {   // адмін сам вирішує, що буде з приставкою після виходу
                                        const cur = (cl.adminInfo || ({})).current;
                                        return qsTr("Трансляція закриється. Приставку можна лишити ввімкненою або перевести в режим спокою.")
                                            + (cur ? " " + qsTr("Зараз час броні: <b>%1</b>. Режим спокою перерве гру клієнта, тож краще лишити приставку ввімкненою.").arg(cur.user) : "");
                                    }
                                    if (panel.guest)
                                        return qsTr("Трансляція закриється. Повернутись можна з головного екрана кнопкою «Грати», поки приставка вільна.");
                                    return cl.endTs > 0
                                        ? qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до <b>%1</b>.").arg(cl.formatTime(cl.endTs))
                                        : qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до кінця броні.");
                                }
                            }
                            Flow {
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                spacing: 10
                                ApButton {
                                    id: exitConfirm
                                    focusPolicy: Qt.StrongFocus
                                    text: qsTr("Вийти з гри")
                                    // адміну закриття вікна показало б стандартне питання про режим спокою: відповідь уже тут, двома кнопками
                                    onClicked: panel.demo ? panel.demoEvent(qsTr("У грі тут трансляція закрилась би, час броні йде далі."))
                                             : panel.admin && Chiaki.session ? Chiaki.stopSession(false) : panel.exit()
                                    KeyNavigation.left: exitBtn
                                    KeyNavigation.right: sleepBtn
                                }
                                ApButton {
                                    id: sleepBtn
                                    visible: panel.admin && !!panel.sess
                                    focusPolicy: Qt.StrongFocus
                                    ghost: true
                                    height: exitConfirm.height
                                    text: qsTr("Вийти й приспати приставку")
                                    onClicked: panel.demo ? panel.demoEvent(qsTr("У грі тут трансляція закрилась би, а приставка пішла б у режим спокою."))
                                             : Chiaki.stopSession(true)
                                    KeyNavigation.left: exitConfirm
                                    KeyNavigation.right: stayBtn
                                }
                                ApButton {
                                    id: stayBtn
                                    focusPolicy: Qt.StrongFocus
                                    ghost: true
                                    height: exitConfirm.height
                                    text: qsTr("Залишитись")
                                    onClicked: panel.goMain()
                                    KeyNavigation.left: sleepBtn
                                }
                            }
                        }
                    }
                }
            }

            // ── підвал: зв'язок і як закрити меню ──
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                spacing: 20
                FootText {
                    text: !panel.sess ? ""
                        : panel.sess.measuredBitrateReady === false ? qsTr("Зв'язок: вимірюю…")   // перші секунди гри чесного виміру ще немає
                        : qsTr("Зв'язок %1 Мбіт/с, втрати %2%").arg(panel.sess.measuredBitrate.toFixed(1).replace(".", ","))
                            .arg(((isFinite(panel.sess.averagePacketLoss) ? panel.sess.averagePacketLoss : 0) * 100).toFixed(1).replace(".", ","))
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                FootText { text: qsTr("Esc: назад, з пунктів — закрити меню. Відкрити й закрити: `") }
            }
        }
    }

    onPageChanged: {
        if (page === "live")
            liveLoader.wanted = true;   // у фоні; далі сторінка лишається створеною
        if (page === "keys")
            keysDelay.restart();
        else {
            keysDelay.stop();
            keysLoader.wanted = false;
        }
    }

    // повзунок у стилі меню: тонка лінія й кругла ручка
    component MenuSlider: Slider {
        id: ms
        background: Rectangle {
            x: ms.leftPadding
            y: ms.topPadding + ms.availableHeight / 2 - height / 2
            width: ms.availableWidth
            height: 2
            color: "#40ffffff"
            Rectangle { width: ms.visualPosition * parent.width; height: parent.height; color: ap.ink }
        }
        handle: Rectangle {
            x: ms.leftPadding + ms.visualPosition * (ms.availableWidth - width)
            y: ms.topPadding + ms.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7
            color: ap.ink
            border.width: ms.visualFocus ? 2 : 0
            border.color: ap.cyan
        }
    }

    component FootText: Text {
        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 12
        font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
        color: ap.faint
    }

    // ── головне вікно AnyPlay поверх гри: бронювання, баланс, PSN, не виходячи з гри (трансляція йде далі) ──
    // Створюється у фоні, коли його вперше відкрили, і далі лише ховається: наступне відкриття миттєве.
    Loader {
        id: homeOver
        property bool wanted: false
        anchors.fill: parent
        z: 50
        asynchronous: true
        active: wanted && !panel.demo
        visible: panel.overlay !== "" && panel.visible && status === Loader.Ready
        sourceComponent: AnyPlayHome {
            overGame: true
            onBackToGame: { panel.closeOverlay(true); panel.resume(); }
            onBackToMenu: panel.closeOverlay(false)
        }
        function show() { if (!item || panel.overlay === "") return; item.view = panel.overlay; item.forceActiveFocus(); }
        onLoaded: show()
    }

    // сторінка праворуч: прокручується, якщо вікно низьке; з'являється згасанням і коротким зсувом
    component PageFlick: Flickable {
        id: pf
        default property alias body: pfInner.data
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: pfInner.childrenRect.height + 8
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } }
        transform: Translate { x: pf.visible ? 0 : 10; Behavior on x { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } } }
        function scrollTo(y) {
            scrollAnim.to = Math.max(0, Math.min(contentHeight - height, y));
            scrollAnim.restart();
        }
        NumberAnimation { id: scrollAnim; target: pf; property: "contentY"; duration: ap.tPage; easing.type: Easing.OutCubic }
        ScrollBar.vertical: ScrollBar {
            policy: pf.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
        }
        Item { id: pfInner; width: pf.width; height: childrenRect.height }
    }

    // пункт ліворуч: великі літери на склі. Обраний — у градієнті заходу сонця зі світінням; наведення — зсув праворуч
    // і підсвітка; натиск — стискання; фокус з клавіатури чи геймпада — блакитна рамка (після клацу мишкою рамки немає).
    // Усі зміни — згасанням (opacity) і зсувом (transform), без анімації кольорів і розмірів.
    component PauseItem: Item {
        id: pi
        property string pageId
        property string text
        property bool danger: false
        property bool live: false         // 116: трансляція йде або керує друг — блакитна позначка зліва
        property bool byMouse: false
        readonly property bool current: panel.page === pageId
        readonly property bool hov: piMouse.containsMouse
        Layout.fillWidth: true
        implicitHeight: piText.implicitHeight + (zoom.low ? 16 : 22)
        activeFocusOnTab: true
        onActiveFocusChanged: { if (activeFocus) panel.page = pageId; else byMouse = false; }
        function activate() {
            if (pageId === "back") panel.resume();
            else if (panel.isOverlayPage(pageId)) panel.openOverlay(pageId);
            else {
                panel.page = pageId;
                if (pageId === "keys") { keysLoader.wanted = true; if (!keysLoader.item) { keysLoader.focusOnLoad = true; return; } }
                if (pageId === "live") { liveLoader.wanted = true; if (!liveLoader.item) { liveLoader.focusOnLoad = true; return; } }
                panel.enterContent();
            }
        }
        Keys.onReturnPressed: activate()
        Keys.onEnterPressed: activate()
        Keys.onSpacePressed: activate()
        Keys.onRightPressed: if (pageId !== "back") activate()
        Item {
            id: piBody
            anchors.fill: parent
            transform: Translate { x: pi.hov && !pi.current ? 6 : 0; Behavior on x { NumberAnimation { duration: ap.tHover; easing.type: Easing.OutCubic } } }
            scale: piMouse.pressed ? ap.pressScale : 1
            Behavior on scale { NumberAnimation { duration: ap.tPress } }
            // тінь під обраним
            Rectangle {
                x: 0; y: 4; width: parent.width; height: parent.height
                radius: ap.radius
                color: pi.danger ? "#40ff4f4f" : "#55ff4f8b"
                opacity: pi.current ? 0.6 : 0
                Behavior on opacity { NumberAnimation { duration: ap.tPage } }
            }
            // скло під наведенням
            Rectangle {
                anchors.fill: parent
                radius: ap.radius
                color: ap.glassHi
                border.width: 1
                border.color: ap.edge
                opacity: pi.hov && !pi.current ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            }
            // обраний: градієнт заходу сонця
            Rectangle {
                anchors.fill: parent
                radius: ap.radius
                opacity: pi.current ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } }
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: pi.danger ? "#e0d94a5a" : ap.accentA }
                    GradientStop { position: 1.0; color: pi.danger ? "#c0b0303f" : ap.accentB }
                }
                Rectangle { x: 6; y: 1; width: parent.width - 12; height: 1; color: "#59ffffff" }   // відблиск зверху
            }
            Text {
                id: piText
                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                text: pi.text
                elide: Text.ElideRight
                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: zoom.low ? 17 : 19
                font.letterSpacing: 1.8; font.capitalization: Font.AllUppercase
                color: pi.current ? ap.inkAccent : pi.danger ? ap.bad : ap.ink
                opacity: pi.current || pi.hov || pi.activeFocus ? 1 : 0.72
                Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            }
            Rectangle {   // 116: позначка «в ефірі» / «керує друг»: блакитна крапка зліва від назви
                visible: pi.live && !pi.current
                anchors { left: parent.left; leftMargin: 5; verticalCenter: parent.verticalCenter }
                width: 6; height: 6; radius: 3
                color: ap.cyan
            }
            Text {   // стрілка праворуч у обраного: туди йде вміст
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                text: "›"
                color: ap.inkAccent
                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: zoom.low ? 18 : 22
                opacity: pi.current && pi.pageId !== "back" ? 1 : 0
                transform: Translate { x: pi.current ? 0 : -6; Behavior on x { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } } }
                Behavior on opacity { NumberAnimation { duration: ap.tPage } }
            }
            Rectangle {   // фокус з клавіатури чи геймпада
                anchors.fill: parent
                anchors.margins: -3
                radius: ap.radius + 3
                visible: pi.activeFocus && !pi.byMouse
                color: "transparent"
                border.width: 2; border.color: ap.cyan
            }
        }
        MouseArea {
            id: piMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                pi.byMouse = true;
                pi.forceActiveFocus();
                pi.byMouse = true;
                if (pi.pageId === "back") panel.resume();
                else if (panel.isOverlayPage(pi.pageId)) panel.openOverlay(pi.pageId);
                else {
                    panel.page = pi.pageId;
                    if (pi.pageId === "keys") keysLoader.wanted = true;
                }
            }
        }
    }
}
