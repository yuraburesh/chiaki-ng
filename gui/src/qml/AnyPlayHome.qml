// AnyPlay: головний екран програми (новий дизайн: вечірній градієнт, вкладки, рядки з тонкими лініями).
// Клієнт: «Гра» (таймер, мої броні, налаштування гри), «Бронювання», «Баланс», «Зображення», «Мій PSN», «Як керувати», «Клавіші».
// «Баланс» є лише тоді, коли сервер його вміє (старий сервер — вкладки й фішки балансу немає); адмінам балансу немає.
// Адмін: «Панель» (хто грає і як: пристрій, керування, якість, зв'язок, екран клієнта; завершити гру, подарувати гру, закрити доступ),
// «CRM» (повна CRM усередині програми; поверх гри її немає), «Спільний PSN», «Свої PSN», а також «Зображення», «Як керувати», «Клавіші».
// Клієнт: ще «Підтримка» — чат з адміном просто в програмі, і поверх гри теж (число нових відповідей на вкладці).
// Гість (cloud.guest): грає, поки приставка вільна; замість тексту про бронь — про гостьовий доступ, продовження немає.
// AnyPlay 116: вкладка «Друзі» (AnyPlayFriends: друзі, хто грає, «Дивитись», подарунки, додати друга), коли програма
// вміє друзів (AnyPlayLiveApi). «Передати повністю»: поки грає друг — «Повернути собі» на «Гра» і на екрані
// «Гра вже йде»; другу, якому передали гру, — «Тобі передали гру» з «Грати».
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import QtCore

import org.streetpea.chiaking

Rectangle {
    id: home
    property var cloud: Chiaki.cloud
    property var updater: Chiaki.updater
    readonly property var speed: Chiaki.speedTest || null
    property int tick: 0
    property bool serviceMode: false     // адмін тимчасово відкрив повний (сервісний) інтерфейс
    Shortcut {
        sequence: "Ctrl+Alt+Shift+S"
        enabled: Chiaki.cloud.admin && !home.overGame
        onActivated: home.serviceMode = true
    }
    readonly property bool isAdmin: cloud.loggedIn && cloud.admin
    readonly property var adm: cloud.adminInfo || ({})
    // К15: приставки («блоки») з сервера, кожна зі своїм «зараз грає» і «далі». Старий сервер їх не віддає:
    // тоді одна приставка з полів current/next, і панель виглядає як раніше
    readonly property var units: {
        const u = adm.units;
        if (u && u.length)
            return u;
        return [{ id: 0, name: "", current: adm.current || null, next: adm.next || [], legacy: true }];
    }
    readonly property bool multiUnit: units.length > 1
    readonly property var cur: adm.current || home.firstCurrent()
    function firstCurrent() {
        for (let i = 0; i < home.units.length; i++)
            if (home.units[i].current)
                return home.units[i].current;
        return null;
    }
    // усі броні «далі» з усіх приставок, за часом (з назвою приставки, якщо їх кілька)
    readonly property var allNext: {
        let out = [];
        for (let i = 0; i < home.units.length; i++) {
            const u = home.units[i];
            const n = u.next || [];
            for (let j = 0; j < n.length; j++)
                out.push(Object.assign({ unitName: home.multiUnit ? u.name : "" }, n[j]));
        }
        out.sort((a, b) => a.start - b.start);
        return out;
    }
    // телеметрія гри: об'єкт у current.live (старий сервер надсилає там лише true або false)
    function liveOf(c) {
        if (!c) return null;
        if (c.live && typeof c.live === "object") return c.live;
        if (c.liveStats && typeof c.liveStats === "object") return c.liveStats;
        return null;
    }
    readonly property var liveInfo: liveOf(home.cur)
    // дані старші за півтори хвилини (програма клієнта шле їх раз на 20 с): клієнт згорнув гру або зник зв'язок
    function liveAgeOf(l) { return l && l.at > 0 && nowTs() - l.at > 90 ? Math.max(1, Math.floor((nowTs() - l.at) / 60)) : 0; }
    readonly property int liveAgeMin: liveAgeOf(liveInfo)
    // гостьовий доступ: грає, поки приставка вільна (кінець гри — початок найближчої чужої броні)
    readonly property bool guestPlay: !isAdmin && st === "play" && cloud.guest === true
    // попереду броней немає (сервер тоді ставить кінець через 12 годин): відлік нічого не каже, пишемо «приставка вільна»
    readonly property bool guestOpen: guestPlay && cloud.endTs - nowTs() > 11 * 3600
    readonly property string st: cloud.state
    // без входу чи без зв'язку з сервером — лише екран входу / помилки, без вкладок
    readonly property bool gated: !cloud.loggedIn || st === "login" || st === "pairing" || st === "offline"
    // клієнт увійшов, але грати зараз не можна (застаріла програма, приставка недоступна,
    // гра вже йде на іншому його пристрої) — замість вкладки «Гра»
    readonly property bool gameGate: !isAdmin && (st === "update" || st === "no_console" || st === "other_device")
    readonly property var mine: (cloud.bookInfo && cloud.bookInfo.mine) || []
    // 116: друзі, трансляція, передана гра (усе з C++ через один адаптер)
    AnyPlayLiveApi { id: homeLive }
    readonly property bool friendsOn: !home.isAdmin && (homeLive.friendsAvailable || (homeLive.available && (homeLive.featFriends || homeLive.featGifts)))
    readonly property bool lentAway: homeLive.handoff === "away" || homeLive.handoff === "preparing" || homeLive.handoff === "returning"
    // overGame: це вікно відкрите з меню гри поверх трансляції: гра йде далі, «Грати» повертає в неї
    property bool overGame: false
    signal backToGame()
    signal backToMenu()
    property string view: "home"         // home | book | wallet | support | quality | psn | guide | keys | (адмін) crm | shared | clients
    signal openKeys()                    // лишився для сумісності: клавіші тепер окрема вкладка
    color: ap.bg1
    focus: visible

    AnyPlayStyle { id: ap }
    AnyPlayWallet { id: wallet }
    readonly property bool walletOn: wallet.on && !home.isAdmin
    onWalletOnChanged: if (!walletOn && view === "wallet") view = "home"

    // ── розміри: до 1600 px як у макеті, на великих екранах (2K, 4K без масштабу системи) усе пропорційно більше ──
    readonly property real zoomK: Math.max(1, Math.min(2.2, Math.min(width / 1560, height / 900)))
    readonly property real pageW: zoom.width
    readonly property real padX: Math.max(pageW < 1100 ? 20 : 32, (pageW - 1520) / 2)   // дизайн 112: ширший вміст, без порожніх полів
    readonly property real cw: pageW - 2 * padX                      // ширина вмісту
    readonly property bool twoCol: cw >= 840
    readonly property real colGap: cw > 1000 ? 28 : 20
    readonly property real leftW: twoCol ? Math.floor((cw - colGap) * 1.2 / 2.2) : cw
    readonly property real rightW: twoCol ? cw - colGap - leftW : cw
    readonly property real timerSize: Math.max(64, Math.min(120, pageW * 0.1))
    readonly property real bigSize: Math.max(38, Math.min(60, pageW * 0.045))
    readonly property string menuKeyText: qsTr("клавіша ` (під Esc)")

    // Фон нічого не пропускає крізь себе: кліки, колесо й наведення не доходять до списку консолей під ним
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        preventStealing: true
        onWheel: (wheel) => wheel.accepted = true
        onPressed: (mouse) => { mouse.accepted = true; home.forceActiveFocus(); }
    }

    Timer { interval: 1000; running: home.visible; repeat: true; onTriggered: home.tick++ }
    Timer { interval: 15000; running: home.visible && home.isAdmin; repeat: true; triggeredOnStart: true; onTriggered: home.cloud.refreshAdmin() }
    // мої броні на вкладці «Гра»: оновлюємо раз на хвилину, а також коли змінюється стан чи вкладка
    Timer { interval: 60000; running: home.visible && home.cloud.loggedIn && !home.isAdmin && !home.gated; repeat: true; onTriggered: home.loadMine() }
    function loadMine() { if (home.cloud.loggedIn && !home.isAdmin && !home.gated) home.cloud.loadBook(); }
    onStChanged: loadMine()
    onViewChanged: {
        if (view === "home") loadMine();
        if (view === "wallet") {
            if (!home.walletOn) { view = "home"; return; }   // старий сервер без балансу або адмін
            home.cloud.loadWallet();
        }
        if (view === "shared") { sharedPage.rev++; home.cloud.refreshAdmin(); }
        if (view === "clients") { clientsPage.result = ""; home.cloud.refreshAdmin(); }
        if (view === "crm") crmOpened = true;
        if (view === "friends") friendsLoader.wanted = true;
        if (view === "crm" && home.overGame) view = "home";   // поверх гри CRM немає (вбудований браузер лише поза грою)
    }
    // ── повний екран (дизайн 112): кнопка «Весь екран» у шапці, F11 або Ctrl+Cmd+F; програма пам'ятає вибір
    // і наступного разу відкривається так само. Типово на весь екран на ноутбуках (екран до 1600 точок завширшки).
    Settings {
        id: winPrefs
        category: "anyplay"
        property bool fullscreen: Screen.width > 0 && Screen.width <= 1600
    }
    readonly property var appWindow: Chiaki.window || null
    readonly property bool isFullscreen: !!appWindow && appWindow.visibility === Window.FullScreen
    function setFullscreen(on) {
        if (!appWindow || home.overGame)
            return;
        winPrefs.fullscreen = on;
        if (on)
            appWindow.showFullScreen();
        else
            appWindow.showMaximized();
    }
    function applyFullscreenPref() {
        if (appWindow && !home.overGame && !Chiaki.session && winPrefs.fullscreen && !home.isFullscreen)
            appWindow.showFullScreen();
    }
    Timer { id: fullscreenStart; interval: 700; onTriggered: home.applyFullscreenPref() }
    Shortcut {
        enabled: !home.overGame && home.visible
        sequences: ["F11", "Ctrl+Meta+F"]
        onActivated: home.setFullscreen(!home.isFullscreen)
    }
    // після гри вікно повертається з повноекранного режиму гри: якщо програма має бути на весь екран — знову на весь екран
    readonly property var liveSession: Chiaki.session
    onLiveSessionChanged: if (!liveSession) fullscreenStart.restart()

    property bool crmOpened: false   // CRM вантажимо, коли її вперше відкрили, і тримаємо, поки відкрите вікно
    onIsAdminChanged: view = "home"
    Component.onCompleted: { loadMine(); if (!overGame) fullscreenStart.start(); }

    function nowTs() { tick; return Math.floor(Date.now() / 1000) + cloud.clockSkew; }
    // «сьогодні 14:05», «вчора 21:30» або «18.11 19:00»
    function dayTime(ts) {
        const d = new Date(ts * 1000), n = new Date(nowTs() * 1000);
        const same = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
        const y = new Date(n.getTime() - 86400000);
        const t = cloud.formatTime(ts);
        if (same(d, n)) return qsTr("сьогодні %1").arg(t);
        if (same(d, y)) return qsTr("вчора %1").arg(t);
        return String(d.getDate()).padStart(2, "0") + "." + String(d.getMonth() + 1).padStart(2, "0") + " " + t;
    }
    function dur(s) {
        s = Math.max(0, s);
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
        if (d > 0) return qsTr("%1 д %2 год").arg(d).arg(h);
        return (h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0");
    }
    function pad2(n) { return String(n).padStart(2, "0"); }
    function hhmm(ts) { const d = new Date(ts * 1000); return pad2(d.getHours()) + ":" + pad2(d.getMinutes()); }
    // «Сьогодні», «Завтра» або «Сб, 21.11»
    function dayName(ts) {
        const d = new Date(ts * 1000), t = new Date();
        t.setHours(0, 0, 0, 0);
        const diff = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - t) / 86400000);
        if (diff === 0) return qsTr("Сьогодні");
        if (diff === 1) return qsTr("Завтра");
        return [qsTr("Нд"), qsTr("Пн"), qsTr("Вт"), qsTr("Ср"), qsTr("Чт"), qsTr("Пт"), qsTr("Сб")][d.getDay()] + ", " + d.getDate() + "." + pad2(d.getMonth() + 1);
    }
    function rangeTitle(a, b) { return dayName(a) + ", " + hhmm(a) + "–" + hhmm(b); }
    // фішка статусу броні
    function bookingChip(m) {
        const now = nowTs();
        if (m.status === "hold") return { text: qsTr("чекає оплату"), kind: "wait" };
        if (m.status === "pending_review") return { text: qsTr("перевіряємо оплату"), kind: "wait" };
        if (m.status === "active" || (m.start <= now && now < m.end)) return { text: qsTr("йде гра"), kind: "live" };
        return { text: (m.pay || m.payMode) === "wallet" ? qsTr("оплачено з балансу") : qsTr("оплачено"), kind: "ok" };
    }
    // приставка для гри: зареєстрована PS5 зі списку (з'являється з сервера на час броні)
    function consoleIndex() {
        const hosts = Chiaki.hosts;
        for (let i = 0; i < hosts.length; i++) {
            const h = hosts[i];
            if (h.display && h.registered)
                return i;
        }
        return -1;
    }
    // «Грати»: спершу питаємо, у що гратиме (розкладка клавіш під гру), якщо клієнт не просив запам'ятати
    function play() {
        if (overGame) { backToGame(); return; }
        if (Chiaki.settings.anyplayAskGame === true && consoleIndex() >= 0) {
            home.pickerFromKeys = false;
            gamePicker.actionText = qsTr("▶ Грати");
            gamePicker.open();
            return;
        }
        playNow();
    }
    // «Показати вибір перед грою» на екрані клавіш: показуємо вибір одразу.
    // Кнопка в ньому справді починає гру, лише якщо зараз уже можна грати; інакше це «Готово».
    property bool pickerFromKeys: false
    readonly property bool canPlayNow: !home.isAdmin && home.st === "play" && home.consoleIndex() >= 0
    function openPickerFromKeys() {
        home.pickerFromKeys = true;
        gamePicker.actionText = home.canPlayNow ? qsTr("▶ Грати") : qsTr("Готово");
        gamePicker.open();
    }
    function pickedGame(layoutId) {
        if (layoutId && layoutId !== Chiaki.settings.anyplayLayout())
            Chiaki.settings.setAnyplayLayout(layoutId);
        home.layoutRev++;
        if (home.pickerFromKeys && !home.canPlayNow) {
            home.pickerFromKeys = false;
            toast.show(Chiaki.settings.anyplayAskGame === true
                ? qsTr("Розкладка: %1. Перед грою програма спитає знову").arg(home.layout.name)
                : qsTr("Розкладка: %1. Більше не питатимемо, змінити можна тут").arg(home.layout.name));
            home.restoreFocus();
            return;
        }
        home.pickerFromKeys = false;
        playNow();
    }
    function pickerDismissed() {
        if (home.pickerFromKeys)
            toast.show(qsTr("Перед наступною грою програма спитає, у що граєш"));
        home.pickerFromKeys = false;
        home.restoreFocus();
    }
    // після вікна поверх екрана клавіші знову йдуть туди, де були (екран клавіш або головний екран)
    function restoreFocus() {
        if (home.view === "keys" && keysLoader.item)
            keysLoader.item.forceActiveFocus();
        else
            home.forceActiveFocus();
    }
    function playNow() { playHost(consoleIndex()); }
    // підключитись до конкретної PS5 зі списку програми (адмін з кількома приставками обирає, до якої)
    function playHost(i) {
        if (overGame) { backToGame(); return; }
        if (i < 0) { toast.show(qsTr("Шукаємо приставку… зачекай кілька секунд")); Chiaki.refreshPsnToken(); return; }
        const h = Chiaki.hosts[i];
        home.cloud.prepareAutoQuality();   // «Авто»: після довгої чистої гри пробуємо якість вище
        if (h.discovered) Chiaki.connectToHost(i, h.name); else Chiaki.connectToHost(i);
    }
    // адміну: з якого акаунта PSN грає (гратиме) клієнт — свого чи спільного
    function psnLine(b, sep) {
        if (!b || !b.psn)
            return "";
        let t = sep + (b.psnOwn ? qsTr("PSN: %1 (свій акаунт клієнта)").arg(b.psn) : qsTr("PSN: %1 (спільний акаунт AnyPlay)").arg(b.psn));
        if (!b.psnOwn && b.clientPsn)
            t += qsTr("; свій %1 ще підключається").arg(b.clientPsn);
        return t;
    }
    readonly property var levelNames: [qsTr("Економна"), qsTr("Оптимальна"), qsTr("Максимальна"), qsTr("Ультра")]
    readonly property var renderNames: ({ fast: qsTr("проста"), default: qsTr("стандартна"), high: qsTr("висока якість"), ai: qsTr("ШІ-чіткість"), ai2: qsTr("посилена ШІ-чіткість"), custom: qsTr("своя") })
    // перегляд екрана клієнта (AnyPlayPreview): стан тут, бо картки приставок перестворюються з кожним оновленням панелі
    QtObject {
        id: previewStore
        property var booking: 0
        property bool big: false
        property real since: 0
        property string lastImage: ""
        property real frameSeenAt: 0
    }
    property bool menuDemo: false        // «Меню гри: перегляд» (Інструменти): меню паузи як у клієнта, без гри
    // ── адміну: як клієнт грає просто зараз, фішками (пристрій, керування, гра й режим, якість, кадри, швидкість, втрати) ──
    function num1(x) { return (Math.round(Number(x) * 10) / 10).toString().replace(".", ","); }
    // 117: залізо клієнта однією фішкою «Пристрій: …» і підказка з усім по рядках (старі програми цих полів не шлють — фішки немає)
    function hwChip(l) {
        const model = String(l.model || ""), cpu = String(l.cpu || ""), ram = Number(l.ramGb) > 0 ? qsTr("%1 ГБ").arg(l.ramGb) : "";
        let gpu = String(l.gpu || "");
        if (gpu === cpu) gpu = "";   // старі збірки без відеокарти слали замість неї процесор
        const inModel = (x) => x !== "" && model.indexOf(x.replace(/^Apple /, "")) >= 0;   // «MacBook Air 15″ M2» і «Apple M2»
        // у фішці назви коротші («Ryzen 5 4600H», «GTX 1650 Ti»), повні — у підказці
        const brief = (x) => x.replace(/\s+with\s+Radeon.*$/i, "").replace(/^NVIDIA\s+(GeForce\s+)?/i, "").replace(/^(AMD|Intel)\s+/i, "")
                              .replace(/\s+(Laptop GPU|Graphics)$/i, "").trim();
        const parts = [model, inModel(cpu) ? "" : brief(cpu), ram, inModel(gpu) || gpu === cpu ? "" : brief(gpu)].filter((x) => x !== "");
        if (!model && !cpu && !ram) return null;
        const tip = [model ? qsTr("Модель: %1").arg(model) : "", cpu ? qsTr("Процесор: %1").arg(cpu) : "", ram ? qsTr("Пам'ять: %1").arg(ram) : "",
                     l.gpu && l.gpu !== cpu ? qsTr("Відеокарта: %1").arg(l.gpu) : "", l.device ? qsTr("Ім'я в системі: %1").arg(l.device) : ""]
            .filter((x) => x !== "").join("\n");
        return { text: qsTr("Пристрій: %1").arg(parts.join(", ")), tip: tip };
    }
    function liveChips(l, ageMin) {
        if (!l) return [];
        const out = [];
        const healthText = l.healthText || ({ good: qsTr("картинка плавна"), fair: qsTr("картинка підгальмовує"), bad: qsTr("картинка глючить") })[l.health] || "";
        if (ageMin > 0)
            out.push({ text: qsTr("дані %1 хв тому").arg(ageMin), kind: "wait" });
        else if (healthText)
            out.push({ text: "● " + healthText, kind: ({ good: "ok", fair: "wait", bad: "bad" })[l.health] || "" });
        const platform = ({ windows: "Windows", mac: "Mac", mac_intel: "Mac (Intel)", android: "Android", linux: "Linux" })[l.platform] || "";
        const device = [l.device || "", platform, l.build ? qsTr("збірка %1").arg(l.build) : ""].filter((x) => x !== "").join(", ");
        if (device) out.push({ text: device });
        const hw = home.hwChip(l);   // 117: модель, процесор, пам'ять, відеокарта
        if (hw) out.push(hw);
        const input = ({ keyboard: qsTr("клавіатура і миша"), gamepad: qsTr("геймпад"), touch: qsTr("сенсорні кнопки") })[l.input] || "";
        if (input) out.push({ text: input });
        const game = l.layoutName || ({ gta6: "GTA VI", gta5: "GTA V", universal: qsTr("інша гра") })[l.layout] || "";
        const mode = l.input === "gamepad" ? "" : ({ foot: qsTr("пішки"), vehicle: qsTr("транспорт"), air: qsTr("авіація") })[l.mode] || "";
        if (game) out.push({ text: game + (mode ? ", " + mode : ""), icon: home.gameLogo(l.layout) });
        const quality = l.qualityName || home.levelNames[l.quality] || "";
        if (quality) out.push({ text: quality + (l.height > 0 ? " " + l.height + "p" : "") });
        // К18 (115): яку обробку картинки вмикає комп'ютер клієнта і чи встигає (сервер дає готовий рядок renderText;
        // старий сервер — лише render / renderName)
        const slow = l.pcSlow === true || l.renderCapped === true;
        const render = l.renderText || (l.render ? qsTr("обробка: %1").arg(l.renderName || home.renderNames[l.render] || l.render) : "");
        if (render) out.push({ text: render, kind: slow ? "wait" : "" });
        if (l.fpsShown !== undefined) {
            const target = l.quality === 0 ? 30 : 60;
            out.push({ text: l.fpsStream > 0 && l.fpsStream - l.fpsShown >= 2 ? qsTr("%1 з %2 кадр/с").arg(l.fpsShown).arg(l.fpsStream) : qsTr("%1 кадр/с").arg(l.fpsShown),
                       kind: l.fpsShown < target * 0.6 ? "bad" : l.fpsShown < target * 0.9 ? "wait" : "" });
        }
        if (l.bitrate !== undefined) out.push({ text: qsTr("%1 Мбіт/с").arg(home.num1(l.bitrate)) });
        if (l.loss !== undefined) out.push({ text: qsTr("втрати %1%").arg(home.num1(l.loss)), kind: l.loss > 2 ? "bad" : l.loss > 0.5 ? "wait" : "" });
        return out;
    }
    function levelName() { return levelNames[home.cloud.qualityLevel] || levelNames[1]; }
    function qualityName() { return home.cloud.autoQuality ? qsTr("Авто: %1").arg(levelName()) : levelName(); }
    function setQuality(level) {
        if (level < 0)
            home.cloud.autoQuality = true;
        else {
            home.cloud.autoQuality = false;
            home.cloud.setQualityLevel(level);
        }
        toast.show(qsTr("Якість: %1").arg(home.qualityName()));
    }
    // розкладка клавіш під гру (назва й логотип для фішки)
    property int layoutRev: 0
    readonly property var layout: {
        layoutRev; view;
        const id = Chiaki.settings.anyplayLayout();
        const all = Chiaki.settings.anyplayLayouts();
        for (let i = 0; i < all.length; i++)
            if (all[i].id === id)
                return all[i];
        return { id: id, name: id };
    }
    function gameLogo(id) { return "qrc:/anyplay-games/" + (id === "gta6" || id === "gta5" ? id : "other") + ".png"; }   // квадратні логотипи ігор (ресурси екрана клавіш)
    readonly property string psnChipText: !home.cloud.myPsn ? qsTr("спільний")
        : (home.cloud.myPsnStatus === "ready" ? (home.cloud.myPsn.indexOf("PSN-") === 0 ? qsTr("свій") : home.cloud.myPsn) : qsTr("підключається"))

    // ── 115: «Грати тут» — гра йде на іншому пристрої клієнта (часто той уже закрили, а сервер ще чекає його сигналу):
    // забрати гру на цей пристрій. Там гра зупиниться після найближчого сигналу (до 20 с). Потрібне Chiaki.cloud.takeover()
    // (C++, роль «Відео»); поки його немає — лишається «Перевірити ще раз», як у 114.
    readonly property bool canTakeover: home.st === "other_device" && typeof home.cloud.takeover === "function" && home.cloud.canTakeover !== false
    function takeover() {
        home.cloud.takeover();
        toast.show(qsTr("Забираємо гру сюди: на «%1» вона зупиниться за кілька секунд.").arg(home.cloud.otherDevice || qsTr("іншому пристрої")));
    }

    // ── головна дія екрана (Enter) ──
    function primaryAction() {
        if (home.gated || home.gameGate || home.view === "home") {
            switch (home.st) {
            case "play":
                // 116: гру передано другу («Передати повністю»): головна кнопка повертає її, а не підключає вдруге
                if (!home.isAdmin && home.lentAway && !home.overGame) { homeLive.handoffBack(); toast.show(qsTr("Повертаємо гру: у друга вона зупиниться за кілька секунд")); break; }
                home.isAdmin ? adminConnect() : home.play(); break;
            case "login": home.cloud.login(); break;
            case "pairing": home.cloud.cancelLogin(); break;
            case "offline": home.cloud.refresh(); break;
            case "other_device":
                if (home.lentAway) { homeLive.handoffBack(); toast.show(qsTr("Повертаємо гру: у друга вона зупиниться за кілька секунд")); break; }
                if (home.canTakeover) { home.takeover(); break; }
                home.cloud.refresh(); toast.show(qsTr("Перевіряємо… «Грати» з'явиться, щойно на іншому пристрої вийдуть з гри")); break;
            case "no_console": home.cloud.openBot(); break;
            case "update":
                if (home.updater && home.updater.available) home.updater.show(); else home.cloud.openBot();
                break;
            default: home.view = "book";
            }
        }
    }
    // К15: до якої PS5 зі списку програми підключатись за цю приставку (-1 — беремо першу прив'язану, як раніше)
    function unitHostIndex(u) {
        if (!u || u.legacy || !home.multiUnit)
            return -1;
        return home.cloud.adminHostIndex(u);
    }
    function adminConnect(u) {
        if (home.overGame) { home.backToGame(); return; }   // адмін уже в грі: це вікно відкрите з меню гри
        const unit = u || home.units[0];
        const c = unit ? unit.current : home.cur;
        const idx = home.unitHostIndex(unit);
        const go = () => idx >= 0 ? home.playHost(idx) : home.play();
        if (c)
            root.showConfirmDialog(qsTr("Підключитись"), c.live
                ? qsTr("Зараз на приставці грає %1. Якщо підключишся, його трансляція перерветься. Підключитись?").arg(c.user)
                : qsTr("Зараз час броні %1 (він ще не підключився). Поки ти на приставці, клієнт не зможе зайти. Підключитись?").arg(c.user),
                go);
        else
            go();
    }

    // К16: спільні акаунти з сервера (null — старий сервер, тоді один акаунт у adm.console)
    readonly property var sharedList: adm.shared && adm.shared.length !== undefined ? adm.shared : null
    readonly property var sharedActive: {
        const out = [];
        for (let i = 0; sharedList && i < sharedList.length; i++)
            if (sharedList[i].active)
                out.push(sharedList[i].psn_name || qsTr("акаунт"));
        return out;
    }
    function unitLabel(u) {   // приставка в рядку сервера: об'єкт {id,name}, число або рядок
        if (!u && u !== 0) return "";
        if (typeof u === "object") return u.name || (u.id ? qsTr("PS5 №%1").arg(u.id) : "");
        if (typeof u === "number") {
            for (let i = 0; i < home.units.length; i++)
                if (home.units[i].id === u)
                    return home.units[i].name || qsTr("PS5 №%1").arg(u);
            return qsTr("PS5 №%1").arg(u);
        }
        return String(u);
    }
    function toggleClosed() {
        if (home.adm.closed)
            home.cloud.adminSetClosed(false);
        else
            confirmPopup.ask({ title: qsTr("Закрити доступ усім"), name: home.cur ? qsTr("Зараз грає %1").arg(home.cur.user) : "", action: qsTr("Закрити доступ"),
                text: qsTr("Тимчасово закрити доступ усім клієнтам? Хто грає, відключиться, бот показуватиме «технічні роботи», поки не відкриєш знову."),
                run: () => home.cloud.adminSetClosed(true) });
    }
    // адмін: перед тим як забрати в клієнта гру, питаємо ще раз і показуємо, чию саме
    function askKick(current) {
        const c = current || home.cur;
        if (c)
            confirmPopup.ask({ title: qsTr("Завершити гру клієнта"), name: c.user, action: qsTr("Завершити гру"),
                text: qsTr("Приставка відключиться просто зараз, а оплачений час до %1 згорить. Клієнт отримає повідомлення в боті.").arg(home.cloud.formatTime(c.end)),
                run: () => home.cloud.adminKick(c.id) });
    }
    // адмін: подарувати клієнту гру просто зараз (час обирається барабанами)
    function askGift(userId, name) { giftPopup.ask(userId, name); }

    readonly property bool popupOpen: extendPopup.opened || confirmPopup.opened || giftPopup.opened || updateDialog.visible || gamePicker.visible
    Keys.onReturnPressed: if (!popupOpen) primaryAction()
    Keys.onEnterPressed: if (!popupOpen) primaryAction()
    Keys.onEscapePressed: {
        if (updateDialog.visible)
            updateDialog.closeByEscape();
        else if (popupOpen)
            closePopups();
        else if (home.view !== "home" && !home.gated)
            home.view = "home";
        else if (home.overGame)
            home.backToMenu();
        else
            root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit());
    }

    // ── свій акаунт PSN, повернення з інших екранів ──
    property bool qrAutoShown: false
    property bool reopenPsn: false
    property bool reopenShared: false
    // після зміни якості в меню гри підключаємось знову самі, щойно приставка готова
    Timer {
        id: reconnectTimer
        property int tries: 0
        property int idle: 0        // скільки разів поспіль бачили, що стара трансляція вже закрита
        interval: 1000; repeat: true
        running: home.cloud.reconnectOnce && !home.overGame
        onRunningChanged: if (running) { tries = 0; idle = 0; home.view = "home"; toast.show(qsTr("Змінюємо якість: за кілька секунд гра відкриється знову сама.")); }
        onTriggered: {
            if (++tries > 40) {
                home.cloud.reconnectOnce = false;
                toast.show(qsTr("Не вдалося підключитись самому. Натисни «Грати»."));
                return;
            }
            // стара трансляція ще закривається (це кілька секунд): чекаємо, а не скасовуємо повернення в гру
            if (Chiaki.session) { idle = 0; return; }
            if (++idle < 3)     // приставці треба мить, щоб відпустити попереднє підключення
                return;
            if (home.cloud.state === "play" && home.consoleIndex() >= 0) {
                home.cloud.reconnectOnce = false;
                home.playNow();   // без питання «У що граєш?»: гра та сама
            }
        }
    }
    function resume() {
        if (reopenPsn) { reopenPsn = false; home.view = "psn"; }
        if (reopenShared) { reopenShared = false; home.view = "shared"; sharedPage.rev++; }
        home.layoutRev++;
        loadMine();
    }
    function startPsnLogin(create) {
        if (!home.cloud.beginMyPsnLogin())
            return;
        home.reopenPsn = true;
        root.showAnyPlayPsnLogin(create);
    }
    function closePopups() { extendPopup.close(); confirmPopup.close(); giftPopup.close(); }
    onVisibleChanged: if (!visible) closePopups(); else { layoutRev++; loadMine(); }
    Connections {
        target: Chiaki.cloud
        function onChanged() {
            const entry = home.cloud.myPsnQr || home.cloud.myPsnCode !== "" || home.cloud.myPsnLink !== "";
            if (entry && !home.qrAutoShown && home.visible && !home.isAdmin) {
                home.qrAutoShown = true;
                home.view = "psn";
            }
            if (!entry)
                home.qrAutoShown = false;
        }
        // після оплати броні оновлюємо стан (з'являється таймер до гри)
        function onBookChanged() { if (home.view === "book") home.cloud.refresh(); }
        // нова відповідь підтримки, а чат закритий: коротко кажемо (крапка на вкладці лишається)
        function onSupportChanged() {
            const n = home.cloud.supportUnread;
            if (n > home.supportSeen && home.visible && home.view !== "support" && !home.isAdmin)
                toast.show(qsTr("Нова відповідь від підтримки: вкладка «Підтримка»"));
            home.supportSeen = n;
        }
    }
    property int supportSeen: 0

    // ── фон ──
    ApBackground { anchors.fill: parent }

    // ── усе, крім фону, масштабується разом на великих екранах ──
    Item {
        id: zoom
        width: home.width / home.zoomK
        height: home.height / home.zoomK
        scale: home.zoomK
        transformOrigin: Item.TopLeft

        // ── верхня смуга: назва, вкладки, ім'я і «Вийти» ──
        Item {
            id: topBar
            x: home.padX
            y: 16
            width: home.cw
            height: barCol.implicitHeight
            // вкладки в один рядок з назвою: звичайні, а якщо не влазять (вкладка й фішка балансу) — трохи щільніші
            readonly property bool wideFits: brand.implicitWidth + tabsWide.implicitWidth + who.implicitWidth + 84 <= width
            readonly property bool oneLine: wideFits || brand.implicitWidth + tabsTight.implicitWidth + who.implicitWidth + 64 <= width
            readonly property var tabModel: home.isAdmin
                ? [{ id: "home", text: qsTr("Панель") }, ...(home.overGame ? [] : [{ id: "crm", text: qsTr("CRM") }]),
                   { id: "shared", text: qsTr("Спільний PSN") }, { id: "clients", text: qsTr("Свої PSN") },
                   { id: "quality", text: qsTr("Зображення") }, { id: "guide", text: qsTr("Як керувати") }, { id: "keys", text: qsTr("Клавіші") }]
                : clientTabs(home.walletOn, home.cloud.supportUnread, home.friendsOn, homeLive.friendRequests.length + (homeLive.incoming ? 1 : 0))
            // вкладки клієнта; «Баланс» — лише коли сервер його вміє
            function clientTabs(withWallet, unread, withFriends, friendBadge) {
                return [{ id: "home", text: qsTr("Гра") }, { id: "book", text: qsTr("Бронювання") },
                        ...(withWallet ? [{ id: "wallet", text: qsTr("Баланс") }] : []),
                        ...(withFriends ? [{ id: "friends", text: qsTr("Друзі"), badge: friendBadge }] : []),
                        { id: "support", text: qsTr("Підтримка"), badge: unread },
                        { id: "quality", text: qsTr("Зображення") }, { id: "psn", text: qsTr("Мій PSN") },
                        { id: "guide", text: qsTr("Як керувати") }, { id: "keys", text: qsTr("Клавіші") }];
            }
            ColumnLayout {
                id: barCol
                width: parent.width
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 28
                    ColumnLayout {
                        id: brand
                        Layout.alignment: Qt.AlignBottom
                        Layout.bottomMargin: 10
                        spacing: 0
                        Row {
                            spacing: 10
                            Rectangle {   // знак: захід сонця
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8; height: 30; radius: 4
                                gradient: Gradient { GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                            }
                            Text {
                                text: "ANYPLAY"
                                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 30; font.letterSpacing: 3.5
                                color: ap.ink
                            }
                        }
                        Text {
                            Layout.leftMargin: 18
                            text: qsTr("ОРЕНДА PS5: GTA ТА ІНШІ ІГРИ")
                            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 11; font.letterSpacing: 2.2
                            color: ap.faint
                        }
                    }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                    RowLayout {
                        id: who
                        Layout.alignment: Qt.AlignBottom
                        Layout.bottomMargin: 12
                        spacing: 10
                        ApButton {   // вийшла нова версія, а вікно відкладене «Пізніше» — тут його можна відкрити знову
                            visible: !!home.updater && home.updater.available && !home.updater.prompt
                            small: true; ghost: true
                            text: qsTr("Оновлення %1").arg(home.updater ? home.updater.build : "")
                            onClicked: home.updater.show()
                        }
                        BalanceChip {   // скільки на балансі; клік — вкладка «Баланс»
                            visible: home.walletOn && !home.gated
                            onClicked: home.view = "wallet"
                        }
                        Text {
                            visible: home.cloud.loggedIn && home.cloud.userName !== ""
                            Layout.maximumWidth: 180
                            text: home.cloud.userName
                            font.family: ap.body; font.pixelSize: 13
                            color: ap.mute
                            elide: Text.ElideRight
                        }
                        LinkButton {   // повний екран і назад (F11, на Mac ще Ctrl+Cmd+F)
                            visible: !home.overGame && !!home.appWindow
                            text: home.isFullscreen ? qsTr("Вікно") : qsTr("Весь екран")
                            onClicked: home.setFullscreen(!home.isFullscreen)
                        }
                        LinkButton {
                            visible: home.cloud.loggedIn && !home.overGame   // під час гри з акаунта не виходять
                            text: qsTr("Вийти")
                            onClicked: root.showConfirmDialog(qsTr("Вийти з акаунта"), qsTr("Вийти з AnyPlay на цьому комп'ютері?"), () => home.cloud.logout())
                        }
                        LinkButton {
                            text: home.overGame ? qsTr("✕ До меню гри") : "✕"
                            onClicked: home.overGame ? home.backToMenu() : root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit())
                        }
                    }
                }
                ApTabs {   // вузьке вікно: вкладки окремим рядком
                    visible: !topBar.oneLine && !home.gated
                    compact: topBar.width < implicitWidth + 40 || topBar.width < 820
                    model: topBar.tabModel
                    current: home.view
                    onActivated: (id) => home.view = id
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }
            }
            // ширина вкладок звичайних і щільних (лише для розрахунку, не показуються)
            ApTabs { id: tabsWide; visible: false; model: topBar.tabModel }
            ApTabs { id: tabsTight; visible: false; compact: true; model: topBar.tabModel }
            // вкладки в один рядок з назвою — поза розкладкою рядка, щоб їх поява не зсувала решту
            ApTabs {
                id: tabsInline
                compact: !topBar.wideFits
                x: brand.width + (compact ? 18 : 28)
                y: brand.y + brand.height + 10 - height
                visible: topBar.oneLine && !home.gated
                model: topBar.tabModel
                current: home.view
                onActivated: (id) => home.view = id
            }
        }

        // ── вміст під смугою ──
        Item {
            id: body
            anchors { left: parent.left; right: parent.right; top: topBar.bottom; topMargin: 6; bottom: parent.bottom }

            // ═════════ вхід і помилки: по центру, без вкладок ═════════
            Item {
                anchors.fill: parent
                visible: home.gated || (home.gameGate && home.view === "home")
                ColumnLayout {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -20
                    width: Math.min(home.cw, 640)
                    spacing: 12
                    ApText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "eyebrow"
                        color: home.st === "offline" || home.st === "no_console" ? ap.bad : ap.cyan
                        text: {
                            switch (home.st) {
                            case "login": return qsTr("Ласкаво просимо");
                            case "pairing": return qsTr("Підтвердження входу");
                            case "offline": return qsTr("Немає зв'язку");
                            case "no_console": return qsTr("Приставка недоступна");
                            case "update": return qsTr("Вийшла нова версія");
                            case "other_device": return home.lentAway ? qsTr("Гру передано другу") : qsTr("Гра вже йде");
                            default: return home.cloud.loggedIn ? "" : qsTr("Ласкаво просимо");
                            }
                        }
                    }
                    ApText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "big"; size: home.bigSize
                        text: {
                            switch (home.st) {
                            case "pairing": return qsTr("Натисни «Start» у боті");
                            case "offline": return qsTr("Перевір інтернет");
                            case "no_console": return qsTr("Напиши нам у бот");
                            case "update": return qsTr("Онови програму");
                            case "other_device": return home.lentAway ? qsTr("Грає друг") : qsTr("На іншому пристрої");
                            default: return qsTr("Увійди, щоб грати");
                            }
                        }
                    }
                    ApText {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "lead"
                        text: {
                            switch (home.st) {
                            case "pairing": return home.cloud.pairShort
                                ? qsTr("Відскануй QR-код телефоном і натисни «Start» у боті. Або надішли боту %1 цей код:").arg(home.cloud.pairBot || "@play_any_bot")
                                : qsTr("Відкрився бот @play_any_bot. Натисни там «Start» і повертайся сюди.");
                            case "offline": return qsTr("Спробуємо знову за хвилину.");
                            case "no_console": return qsTr("Приставка тимчасово недоступна: кнопка «🆘 Допомога» в боті.");
                            case "update": return home.updater && home.updater.available
                                ? qsTr("Ця версія програми застаріла, і грати з неї вже не можна. Натисни «Оновити програму»: AnyPlay завантажить нову версію, ненадовго закриється і відкриється знову. Вхід і броні збережуться.")
                                : qsTr("Ця версія програми застаріла, і грати з неї вже не можна. Завантаж нову в боті: кнопка «Програма». Встановлюється поверх старої, вхід і броні зберігаються.");
                            // приставка тримає одне підключення: другий пристрій вибив би перший
                            case "other_device": return home.lentAway
                                ? qsTr("Зараз грає %1. Час броні йде, як і йшов. Повернути гру собі можна будь-коли, у друга вона зупиниться за кілька секунд.").arg(homeLive.handoffTo || qsTr("друг"))
                                : home.canTakeover
                                ? qsTr("Гра йде на іншому пристрої: %1. Грати тут? Там гра зупиниться за кілька секунд і продовжиться тут, з того самого місця. Час броні не зміниться.").arg(home.cloud.otherDevice || qsTr("інший пристрій"))
                                : qsTr("Зараз ти граєш на «%1». Приставка тримає лише одне підключення: закрий гру там (меню AnyPlay → «Вийти з гри»), і тут з'явиться кнопка «Грати».").arg(home.cloud.otherDevice);
                            default: return qsTr("Вхід через Telegram, без паролів. Приставка відкриється сама в час твоєї оплаченої броні.");
                            }
                        }
                    }
                    // вхід з телефона: шість цифр великими і QR-код
                    ApText {
                        visible: home.st === "pairing" && home.cloud.pairShort !== ""
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        role: "big"; size: Math.round(home.bigSize * 0.8)
                        color: ap.gold
                        font.letterSpacing: 8
                        text: home.cloud.pairShort.replace(/(\d{3})(\d{3})/, "$1 $2")
                    }
                    Rectangle {
                        visible: home.st === "pairing" && home.cloud.pairQr !== ""
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 4
                        width: 210; height: 210
                        radius: ap.radius
                        color: "#ffffff"
                        Image {
                            anchors.fill: parent
                            anchors.margins: 8
                            source: parent.visible ? home.cloud.pairQr : ""
                            fillMode: Image.PreserveAspectFit
                            smooth: false
                            cache: false
                        }
                    }
                    ApButton {
                        visible: home.st === "pairing" && home.cloud.pairShort !== ""
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 6
                        minWidth: 260
                        text: qsTr("Відкрити Telegram тут")
                        onClicked: home.cloud.openPairLink()
                    }
                    ApButton {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 10
                        minWidth: 260
                        ghost: (home.st === "other_device" && !home.canTakeover && !home.lentAway) || (home.st === "pairing" && home.cloud.pairShort !== "")   // тут нічого не треба робити: «Грати» з'явиться саме
                        text: {
                            switch (home.st) {
                            case "pairing": return qsTr("Скасувати");
                            case "offline": return qsTr("Спробувати ще");
                            case "no_console": return qsTr("Відкрити бота");
                            case "update": return home.updater && home.updater.available ? qsTr("Оновити програму") : qsTr("Завантажити нову версію");
                            case "other_device": return home.lentAway ? qsTr("Повернути собі") : home.canTakeover ? qsTr("▶ Грати тут") : qsTr("Перевірити ще раз");
                            default: return qsTr("Увійти через Telegram");
                            }
                        }
                        onClicked: home.primaryAction()
                    }
                    ApButton {   // 115: «Грати тут» є, але можна й просто дочекатись, поки там вийдуть з гри
                        visible: home.canTakeover && !home.lentAway
                        Layout.alignment: Qt.AlignHCenter
                        minWidth: 260
                        ghost: true
                        text: qsTr("Перевірити ще раз")
                        onClicked: { home.cloud.refresh(); toast.show(qsTr("Перевіряємо… «Грати» з'явиться, щойно на іншому пристрої вийдуть з гри")); }
                    }
                    ApButton {   // Telegram на телефоні, а не на цьому комп'ютері
                        visible: home.st === "login"
                        Layout.alignment: Qt.AlignHCenter
                        minWidth: 260
                        ghost: true
                        text: qsTr("Вхід з телефона: QR-код або код")
                        onClicked: home.cloud.login(false)
                    }
                }
            }

            // ═════════ ГРА (клієнт) ═════════
            TabPage {
                visible: !home.gated && !home.isAdmin && !home.gameGate && home.view === "home"
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    // 116: передана гра — другові («Тобі передали гру») або власнику броні, поки грає друг
                    ApCard {
                        visible: !!homeLive.incoming || home.lentAway
                        Layout.columnSpan: home.twoCol ? 2 : 1
                        Layout.topMargin: 8
                        Layout.bottomMargin: -14
                        accentEdge: homeLive.incoming ? ap.cyan : ap.gold
                        padding: 18
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 18
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                ApText {
                                    role: "cap"
                                    color: homeLive.incoming ? ap.cyan : ap.gold
                                    text: homeLive.incoming ? homeLive.incomingTitle : qsTr("Гру передано другу")
                                }
                                ApText {
                                    Layout.fillWidth: true
                                    role: "body"
                                    text: homeLive.incoming
                                        ? homeLive.incomingText
                                        : homeLive.handoff === "preparing" ? qsTr("Готуємо приставку, грати буде %1…").arg(homeLive.handoffTo)
                                        : qsTr("Зараз грає %1. Повернути гру собі можна будь-коли.").arg(homeLive.handoffTo)
                                }
                            }
                            ApButton {
                                visible: !!homeLive.incoming && !homeLive.incoming.waiting
                                text: qsTr("▶ Грати")
                                onClicked: homeLive.acceptHandoff()
                            }
                            ApButton {   // у грі «Повернути собі» — головна кнопка нижче; тут — коли її немає (не «play»)
                                visible: !homeLive.incoming && homeLive.handoff !== "returning" && home.st !== "play"
                                text: qsTr("Повернути собі")
                                onClicked: { homeLive.handoffBack(); toast.show(qsTr("Повертаємо гру: у друга вона зупиниться за кілька секунд")); }
                            }
                        }
                    }
                    // ліворуч: таймер і головна кнопка
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        id: hero
                        readonly property bool timer: (home.st === "play") || (home.st === "wait" && home.cloud.nextStart > 0 && home.cloud.nextStart - home.nowTs() > 0)
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 8
                        spacing: 12
                        ApText {
                            role: "eyebrow"
                            text: home.guestPlay ? qsTr("Гостьовий доступ")
                                : home.st === "play" ? qsTr("Час твоєї гри") : (home.cloud.nextStart ? qsTr("Твоя наступна гра") : qsTr("Бронювання"))
                        }
                        ApTimer {
                            visible: hero.timer && !home.guestOpen
                            size: home.timerSize
                            color: home.st === "play" ? ap.gold : ap.ink
                            text: home.st === "play" ? home.dur(home.cloud.endTs - home.nowTs()) : home.dur(home.cloud.nextStart - home.nowTs())
                        }
                        ApText {
                            visible: !hero.timer || home.guestOpen
                            Layout.fillWidth: true
                            role: "big"; size: home.bigSize
                            text: home.guestOpen ? qsTr("Приставка вільна")
                                : home.cloud.nextStart ? qsTr("Вже скоро!")
                                : home.cloud.guest === true ? qsTr("Приставка зайнята") : qsTr("Немає оплачених броней")
                        }
                        ApText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 560
                            role: "lead"; rich: true
                            text: {
                                const c = home.cloud;
                                if (home.st === "play" && c.paymentChecking)   // гра в кредит: час броні вийшов, оплату продовження ще перевіряють
                                    return qsTr("Оплату продовження ще перевіряємо, тому гра не зупинилась. Поки що грати можна до <b>%1</b>; щойно оплату підтвердять, час додасться сам.").arg(c.formatTime(c.endTs));
                                if (home.guestPlay)   // гість нічого не оплачує і не продовжує: грає до початку найближчої чужої гри
                                    return (home.guestOpen ? qsTr("Гостьовий доступ: граєш, поки приставка вільна. Якщо хтось забронює час, попередимо за 10 хвилин.")
                                                           : qsTr("Гостьовий доступ: граєш, поки приставка вільна. До <b>%1</b>, потім почнеться оплачена гра іншого гравця.").arg(c.formatTime(c.endTs)))
                                        + (c.playPsn ? " " + (c.playOwn ? qsTr("Акаунт PSN: %1 (твій).") : qsTr("Акаунт PSN: %1 (спільний).")).arg(c.playPsn) : "");
                                if (home.st === "play")
                                    return qsTr("Лишилось до кінця. Гра до <b>%1</b>, потім завершиться сама.").arg(c.formatTime(c.endTs))
                                        + (c.playPsn ? " " + (c.playOwn ? qsTr("Акаунт PSN: %1 (твій).") : qsTr("Акаунт PSN: %1 (спільний).")).arg(c.playPsn) : "");
                                if (c.nextStart)
                                    return qsTr("До початку гри <b>%1–%2</b>. Доступ відкриється сам рівно в цей час, програму можна не закривати.").arg(c.formatTime(c.nextStart)).arg(c.formatTime(c.nextEnd));
                                if (c.guest === true)   // гість, а на приставці зараз чужа оплачена гра
                                    return qsTr("У тебе гостьовий доступ, але зараз на приставці оплачена гра іншого гравця. Кнопка «Грати» з'явиться тут, щойно приставка звільниться. Свій час можна забронювати просто зараз.");
                                return qsTr("Обери час і оплати прямо тут. Приставка відкриється сама в час твоєї гри.");
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            spacing: 10
                            ApButton {
                                id: primaryBtn
                                minWidth: 260
                                text: home.overGame ? qsTr("▶ Повернутись у гру")
                                    : home.st === "play" && home.lentAway ? qsTr("Повернути собі")
                                    : home.st === "play" ? (home.consoleIndex() >= 0 ? qsTr("▶ Грати") : qsTr("Підключаємо приставку…"))
                                    : (home.cloud.nextStart ? qsTr("Забронювати ще") : qsTr("Забронювати час"))
                                onClicked: home.primaryAction()
                            }
                            ApButton {
                                visible: home.st === "play" && !home.cloud.paymentChecking && !home.guestPlay   // у кредит продовження вже оформлене й перевіряється; гостю продовжувати нічого
                                ghost: true
                                height: primaryBtn.height
                                text: qsTr("Продовжити бронювання")
                                onClicked: extendPopup.open()
                            }
                            ApButton {   // гість може забронювати свій час, тоді його ніхто не перерве
                                visible: home.guestPlay
                                ghost: true
                                height: primaryBtn.height
                                text: qsTr("Забронювати свій час")
                                onClicked: home.view = "book"
                            }
                        }
                    }
                    // праворуч: мої броні й налаштування гри
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 12
                        spacing: 0
                        ApText { role: "cap"; text: qsTr("Мої броні"); Layout.bottomMargin: 6 }
                        ApText {
                            visible: home.mine.length === 0
                            role: "hint"
                            topPadding: 10; bottomPadding: 10
                            text: qsTr("Поки порожньо.")
                        }
                        Repeater {
                            model: home.mine.slice(0, 4)
                            ApRow {
                                id: mineRow
                                required property var modelData
                                readonly property var chip: home.bookingChip(modelData)
                                title: home.rangeTitle(modelData.start, modelData.end)
                                subtitle: modelData.title || ""
                                clickable: true
                                onClicked: home.view = "book"
                                ApChip { text: mineRow.chip.text; kind: mineRow.chip.kind }
                            }
                        }
                        ApText {
                            visible: home.mine.length > 4
                            role: "small"; topPadding: 6
                            text: qsTr("Усі броні: вкладка «Бронювання».")
                        }
                        ApRow {
                            visible: home.walletOn
                            Layout.topMargin: 10
                            title: qsTr("Баланс")
                            subtitle: qsTr("плати за гру одним натиском, без переказу щоразу")
                            clickable: true
                            onClicked: home.view = "wallet"
                            ApChip { text: wallet.primaryText }
                        }
                        ApText { role: "cap"; text: qsTr("Налаштування гри"); Layout.topMargin: 22; Layout.bottomMargin: 6 }
                        ApRow {
                            title: qsTr("Клавіші")
                            subtitle: Chiaki.controllers.length ? qsTr("геймпад підключено; розкладка під гру змінюється навіть під час гри")
                                                                : qsTr("розкладка під гру, змінюється навіть під час гри")
                            clickable: true
                            onClicked: home.view = "keys"
                            ApChip { text: home.layout.name || ""; icon: home.gameLogo(home.layout.id) }
                        }
                        ApRow {
                            title: qsTr("Зображення")
                            subtitle: home.cloud.autoQuality ? qsTr("якість сама підлаштовується під інтернет; кольори, обробка") : qsTr("якість стала, обрана вручну; кольори, обробка")
                            clickable: true
                            onClicked: home.view = "quality"
                            ApChip { text: home.cloud.autoQuality ? qsTr("Авто") : home.levelName() }
                        }
                        ApRow {
                            title: qsTr("Акаунт PSN")
                            subtitle: qsTr("на якому акаунті грати")
                            clickable: true
                            onClicked: home.view = "psn"
                            ApChip { text: home.psnChipText; kind: home.cloud.myPsn && home.cloud.myPsnStatus === "ready" ? "ok" : "" }
                        }
                    }
                }
            }

            // ═════════ ПАНЕЛЬ (адмін) ═════════
            TabPage {
                visible: !home.gated && home.isAdmin && home.view === "home"
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ColumnLayout {   // К15: картка на кожну приставку (одна, якщо сервер приставок не віддає)
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: home.colGap
                        Repeater {
                            model: home.units
                            ApCard {   // хто грає зараз на цій приставці і як: головна картка панелі
                                id: unitCard
                                required property var modelData
                                required property int index
                                readonly property var c: modelData.current || null
                                readonly property var l: home.liveOf(c)
                                readonly property int ageMin: home.liveAgeOf(l)
                                readonly property bool off: modelData.enabled === false
                                readonly property int hostIdx: { home.tick; Chiaki.hosts; return home.unitHostIndex(modelData); }
                                Layout.fillWidth: true
                                padding: home.multiUnit ? 24 : 28
                                spacing: 12
                                accentEdge: home.adm.closed || off ? ap.bad : (l ? (l.health === "bad" ? ap.bad : l.health === "fair" ? ap.gold : ap.ok) : "transparent")
                                ApText {
                                    role: "eyebrow"
                                    color: home.adm.closed || unitCard.off ? ap.bad : ap.accent
                                    text: {
                                        const name = home.multiUnit || !unitCard.modelData.legacy && unitCard.modelData.name ? unitCard.modelData.name : "";
                                        const state = home.adm.closed ? qsTr("Доступ клієнтам закрито") : unitCard.off ? qsTr("Вимкнена: не бронюється")
                                                    : unitCard.c ? qsTr("Зараз грає") : home.multiUnit ? qsTr("Вільна") : qsTr("Панель адміна");
                                        return name ? name + ": " + state.toLowerCase() : state;
                                    }
                                }
                                ApText {
                                    Layout.fillWidth: true
                                    role: "big"; size: home.multiUnit ? Math.round(home.bigSize * 0.8) : home.bigSize
                                    font.capitalization: unitCard.c ? Font.MixedCase : Font.AllUppercase
                                    text: unitCard.c ? unitCard.c.user : qsTr("Зараз ніхто не грає")
                                }
                                ApText {
                                    Layout.fillWidth: true
                                    Layout.maximumWidth: 560
                                    role: "lead"
                                    text: {
                                        const c = unitCard.c;
                                        if (c)
                                            return (c.live ? qsTr("у грі") : qsTr("ще не підключився")) + ", "
                                                + qsTr("%1–%2, лишилось %3").arg(home.cloud.formatTime(c.start)).arg(home.cloud.formatTime(c.end)).arg(home.dur(c.end - home.nowTs()))
                                                + home.psnLine(c, "\n");
                                        const n = unitCard.modelData.next || [];
                                        return n.length ? qsTr("Наступна бронь: %1, %2–%3").arg(n[0].user).arg(home.cloud.formatTime(n[0].start)).arg(home.cloud.formatTime(n[0].end)) + home.psnLine(n[0], "\n")
                                                        : qsTr("Найближчих оплачених броней немає.");
                                    }
                                }
                                // як клієнт грає просто зараз (це шле його програма): здоров'я картинки, пристрій, керування, гра, якість, зв'язок
                                Flow {
                                    visible: !!unitCard.l
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: home.liveChips(unitCard.l, unitCard.ageMin)
                                        ApChip {
                                            required property var modelData
                                            text: modelData.text
                                            kind: modelData.kind || ""
                                            icon: modelData.icon || ""
                                            HoverHandler { id: chipHover }   // 117: підказка (у «Пристрій» — усе залізо по рядках)
                                            ToolTip.visible: !!modelData.tip && chipHover.hovered
                                            ToolTip.text: modelData.tip || ""
                                            ToolTip.delay: 300
                                        }
                                    }
                                }
                                // що зараз бачить клієнт: маленьке вікно, оновлюється раз на ~1,5 с (лише поки відкрите)
                                AnyPlayPreview {
                                    visible: !!unitCard.c
                                    Layout.fillWidth: true
                                    Layout.topMargin: 6
                                    bookingId: unitCard.c ? unitCard.c.id : 0
                                    userId: unitCard.c ? (unitCard.c.userId || 0) : 0
                                    live: unitCard.l
                                    store: previewStore
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 10
                                    spacing: 10
                                    ApButton {   // адмін може зайти на приставку будь-коли
                                        id: adminPrimary
                                        minWidth: home.multiUnit ? 220 : 260
                                        text: home.overGame ? qsTr("▶ Повернутись у гру")
                                            : (home.multiUnit ? unitCard.hostIdx >= 0 : home.consoleIndex() >= 0)
                                                ? (home.multiUnit ? qsTr("Підключитись до %1").arg(unitCard.modelData.name || "PS5") : qsTr("Підключитись до приставки"))
                                            : home.multiUnit && home.consoleIndex() >= 0 ? qsTr("Підключитись (PS5 не прив'язана тут)")
                                            : qsTr("Шукаю PS5…")
                                        onClicked: home.adminConnect(unitCard.modelData)
                                    }
                                    ApButton {
                                        visible: !!unitCard.c
                                        ghost: true
                                        height: adminPrimary.height
                                        text: qsTr("Завершити гру клієнта")
                                        onClicked: home.askKick(unitCard.c)
                                    }
                                    ApButton {   // з однією приставкою кнопка доступу тут, як у 112; з кількома — у «Інструментах», бо дія на всі
                                        visible: !home.multiUnit
                                        ghost: true
                                        danger: !home.adm.closed
                                        height: adminPrimary.height
                                        text: home.adm.closed ? qsTr("Відкрити доступ") : qsTr("Закрити доступ усім")
                                        onClicked: home.toggleClosed()
                                    }
                                }
                                ApText {   // К15: цю приставку в програмі ще не прив'язано, тож «Підключитись» піде на першу прив'язану
                                    visible: home.multiUnit && !home.overGame && unitCard.hostIdx < 0
                                    Layout.fillWidth: true
                                    role: "small"
                                    text: qsTr("Щоб підключатись саме до цієї PS5, прив'яжи її в цій програмі: Спільний PSN, крок 2.")
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        id: adminRight
                        // далі: з однією приставкою перша «наступна» вже названа в картці, тож тут з другої; з кількома — усі разом за часом
                        readonly property var later: home.multiUnit ? home.allNext.slice(0, 5) : (home.cur ? home.allNext.slice(0, 3) : home.allNext.slice(1, 4))
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        spacing: home.colGap
                      ApCard {
                        visible: adminRight.later.length > 0
                        title: qsTr("Далі")
                        spacing: 0
                        Repeater {
                            model: adminRight.later
                            ApRow {
                                id: laterRow
                                required property var modelData
                                title: modelData.user
                                subtitle: home.cloud.formatTime(modelData.start) + "–" + home.cloud.formatTime(modelData.end)
                                    + (modelData.unitName ? ", " + modelData.unitName : "") + home.psnLine(modelData, ", ")
                                ApButton {   // подарувати цьому клієнту гру просто зараз (час обирається барабанами)
                                    visible: !!laterRow.modelData.userId
                                    small: true; ghost: true
                                    text: qsTr("Подарувати")
                                    onClicked: home.askGift(laterRow.modelData.userId, laterRow.modelData.user)
                                }
                            }
                        }
                      }
                      ApCard {
                        title: qsTr("Інструменти")
                        spacing: 0
                        ApRow {   // К15: доступ закривається для всіх приставок одразу
                            visible: home.multiUnit
                            title: home.adm.closed ? qsTr("Доступ клієнтам закрито") : qsTr("Доступ клієнтам відкрито")
                            subtitle: home.adm.closed ? qsTr("бот показує «технічні роботи» на всіх приставках") : qsTr("клієнти грають на будь-якій вільній приставці")
                            ApButton {
                                small: true; ghost: true
                                danger: !home.adm.closed
                                text: home.adm.closed ? qsTr("Відкрити") : qsTr("Закрити усім")
                                onClicked: home.toggleClosed()
                            }
                        }
                        ApRow {
                            title: qsTr("Спільний PSN")
                            subtitle: home.sharedList ? qsTr("акаунти, на яких грають клієнти") : qsTr("акаунт, на якому грають клієнти")
                            clickable: true
                            onClicked: home.view = "shared"
                            ApChip {
                                text: home.sharedList
                                    ? (home.sharedActive.length ? home.sharedActive.join(", ") : qsTr("немає активного"))
                                    : home.adm.console ? (home.adm.console.psn_name || qsTr("акаунт на %1").arg(home.adm.console.label || "PS5")) : qsTr("не передано")
                                kind: (home.sharedList ? home.sharedActive.length : home.adm.console) ? "ok" : "bad"
                            }
                        }
                        ApRow {
                            title: qsTr("Свої PSN")
                            subtitle: qsTr("клієнти, які грають на своєму акаунті")
                            clickable: true
                            onClicked: home.view = "clients"
                            ApChip {
                                text: (home.adm.psnClients || []).length ? qsTr("чекають: %1").arg(home.adm.psnClients.length)
                                    : (home.adm.ownPsn || []).length ? qsTr("зі своїм: %1").arg(home.adm.ownPsn.length) : qsTr("немає заявок")
                                kind: (home.adm.psnClients || []).length ? "wait" : ""
                            }
                        }
                        ApRow {   // 115: меню паузи клієнта без гри — подивитись і поклацати, нічого не змінюючи
                            visible: !home.overGame
                            title: qsTr("Меню гри: перегляд")
                            subtitle: qsTr("як клієнт бачить меню паузи, без гри; нічого не змінює")
                            clickable: true
                            onClicked: home.menuDemo = true
                            ApChip { text: qsTr("відкрити") }
                        }
                        ApRow {
                            title: qsTr("CRM")
                            subtitle: home.overGame ? qsTr("броні, клієнти, баланси, адміни: у боті (тут, коли вийдеш з гри)")
                                                    : qsTr("броні, клієнти, баланси, прибуток, адміни з правами")
                            clickable: true
                            onClicked: {
                                if (home.overGame || !home.cloud.webEngine) {
                                    home.cloud.openBot();
                                    toast.show(qsTr("У боті натисни кнопку «CRM» внизу зліва"));
                                } else
                                    home.view = "crm";
                            }
                            hairline: false
                            ApChip { text: qsTr("відкрити") }
                        }
                        ApRow {
                            // технічний екран оригінальної програми: прив'язка тепер у «Спільний PSN», тож кнопку сховано.
                            // Для підтримки лишився прихований вхід: Ctrl+Alt+Shift+S (див. Shortcut на початку файлу)
                            visible: false
                            title: qsTr("Сервіс")
                            subtitle: qsTr("усі налаштування програми")
                            clickable: true
                            onClicked: home.serviceMode = true
                            hairline: false
                            ApChip { text: qsTr("відкрити") }
                        }
                      }
                    }
                }
            }

            // ═════════ CRM (адмін, поза грою): та сама сторінка, що в боті, на всю ширину ═════════
            Loader {
                anchors.fill: parent
                active: home.crmOpened && !home.gated && home.isAdmin && !home.overGame
                visible: home.view === "crm" && !home.gated && home.isAdmin
                sourceComponent: AnyPlayCrm {
                    contentWidth: home.cw
                    onBack: home.view = "home"
                }
            }

            // ═════════ ДРУЗІ (116): друзі, хто грає, «Дивитись», подарунки ═════════
            // створюємо, коли вкладку вперше відкрили (головне вікно поверх гри відкривається так само швидко, як у 115)
            Loader {
                id: friendsLoader
                property bool wanted: false
                anchors.fill: parent
                active: wanted && home.friendsOn
                visible: home.friendsOn && !home.gated && home.view === "friends"
                sourceComponent: AnyPlayFriends {
                    visible: friendsLoader.visible
                    api: homeLive
                    overGame: home.overGame
                    padX: home.padX
                    cw: home.cw
                    twoCol: home.twoCol
                    colGap: home.colGap
                    leftW: home.leftW
                    rightW: home.rightW
                    onToast: (t) => toast.show(t)
                }
            }

            // ═════════ ПІДТРИМКА (клієнт): чат з адміном, і поверх гри теж ═════════
            AnyPlaySupport {
                anchors.fill: parent
                visible: !home.gated && !home.isAdmin && home.view === "support"
                contentWidth: Math.min(home.cw, 860)
            }

            // ═════════ БРОНЮВАННЯ ═════════
            TabPage {
                visible: !home.gated && !home.isAdmin && home.view === "book"
                BookPanel {
                    width: home.cw
                    visible: home.view === "book" && !home.gated && !home.isAdmin
                    onWalletRequested: home.view = "wallet"
                }
            }

            // ═════════ БАЛАНС ═════════
            TabPage {
                visible: !home.gated && home.walletOn && home.view === "wallet"
                WalletPanel {
                    width: home.cw
                    visible: home.view === "wallet" && !home.gated && home.walletOn
                    twoCol: home.twoCol
                    columnSpacing: home.colGap
                    leftW: home.leftW
                    rightW: home.rightW
                    amountSize: Math.max(56, Math.min(88, home.pageW * 0.08))
                }
            }

            // ═════════ ЗОБРАЖЕННЯ (AnyPlay 113: якість з прикладами, кольори, обробка, екран) ═════════
            TabPage {
                visible: !home.gated && home.view === "quality"
                AnyPlayImage {
                    width: home.cw
                    maxW: 1600
                    onQualityPicked: (level) => { if (level !== -2) toast.show(qsTr("Якість: %1").arg(home.qualityName())); }
                }
            }

            // ═════════ МІЙ PSN ═════════
            TabPage {
                id: psnPage
                visible: !home.gated && !home.isAdmin && home.view === "psn"
                readonly property string pst: home.cloud.myPsnStatus
                readonly property bool hasEntry: home.cloud.myPsnQr || home.cloud.myPsnCode !== "" || home.cloud.myPsnLink !== ""
                // 2 — вхід через Sony, 3 — вхід на приставці, 4 — адмін завершує, 5 — готово
                readonly property int step: !home.cloud.myPsnLinked ? 2 : (pst === "ready" ? 5 : (pst === "signed_in" ? 4 : 3))
                // поки чекаємо QR-код або адміна — питаємо сервер кожні 4 секунди, а не раз на хвилину
                Timer {
                    interval: 4000; repeat: true
                    running: psnPage.visible && home.visible && (psnPage.step === 3 || psnPage.step === 4)
                    onTriggered: home.cloud.refresh()
                }
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: 12
                        ApText { role: "h2"; text: qsTr("Мій акаунт PSN") }
                        // крок 1 (вхід на сайті Sony)
                        ApText {
                            visible: psnPage.step === 2
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "lead"
                            text: qsTr("На спільному акаунті AnyPlay грають усі клієнти, тому прогрес там спільний і може змінитись. На своєму акаунті твої збереження, персонаж GTA Online, гроші, авто й трофеї тільки твої, і наступного разу продовжуєш з того самого місця.")
                        }
                        ApText {
                            visible: psnPage.step === 2
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "lead"
                            text: qsTr("Пароль вводиш лише на сайті Sony. Ні ми, ні програма його не бачимо. Акаунт PSN безкоштовний, а гра вже є на нашій приставці: купувати нічого не треба.")
                        }
                        Flow {
                            visible: psnPage.step === 2
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            spacing: 10
                            ApButton { id: psnLoginBtn; minWidth: 260; text: qsTr("Увійти в свій PSN"); onClicked: home.startPsnLogin(false) }
                            ApButton { ghost: true; height: psnLoginBtn.height; text: qsTr("Створити акаунт"); onClicked: home.startPsnLogin(true) }
                        }
                        ApText {
                            visible: psnPage.step === 2
                            Layout.fillWidth: true
                            role: "small"
                            text: qsTr("Вхід і реєстрація відкриваються на сайті Sony у твоєму браузері, програма покаже, що робити далі.")
                        }
                        // крок 2: вхід на приставці — посилання, код цифрами або QR
                        ApText {
                            visible: psnPage.step === 3
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "lead"
                            text: psnPage.hasEntry
                                ? qsTr("Приставка чекає, поки ти підтвердиш вхід у свій акаунт PSN. Пароль вводиш лише на сайті Sony. Застосунок PlayStation для цього не потрібен. Код діє кілька хвилин.")
                                : qsTr("Адміністратор готує приставку. Посилання і QR-код для входу з'являться тут за кілька хвилин (і прийдуть у Telegram). Можна займатись іншим: щойно вони будуть, цей розділ відкриється сам.")
                        }
                        ApButton {
                            visible: psnPage.step === 3 && home.cloud.myPsnLink !== ""
                            text: qsTr("Відкрити сторінку входу")
                            onClicked: home.cloud.openMyPsnLink()
                        }
                        ApText {
                            visible: psnPage.step === 3 && home.cloud.myPsnLink !== ""
                            Layout.fillWidth: true
                            role: "small"
                            text: qsTr("Відкриється сайт Sony у твоєму браузері. Увійди у свій акаунт PSN і підтверди вхід на приставці. Телефон не потрібен.")
                        }
                        ColumnLayout {   // код цифрами
                            visible: psnPage.step === 3 && home.cloud.myPsnCode !== ""
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            spacing: 2
                            ApText { role: "cap"; text: qsTr("Код для входу") }
                            RowLayout {
                                spacing: 14
                                Text {
                                    text: home.cloud.myPsnCode
                                    font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 36; font.letterSpacing: 4
                                    color: ap.ink
                                }
                                ApButton { small: true; ghost: true; text: qsTr("Скопіювати"); onClicked: home.cloud.copyText(home.cloud.myPsnCode) }
                            }
                            ApText {
                                Layout.fillWidth: true
                                role: "small"
                                text: home.cloud.myPsnLink !== ""
                                    ? qsTr("Якщо сайт Sony попросить код, введи цей.")
                                    : qsTr("Це код з екрана приставки. Сайт Sony може попросити його під час входу.")
                            }
                        }
                        Image {   // QR-код звичайною камерою телефона
                            id: psnQr
                            property bool big: false
                            readonly property real side: big ? Math.min(home.leftW, 560) : 280
                            visible: psnPage.step === 3 && home.cloud.myPsnQr
                            source: visible ? home.cloud.qrUrl : ""
                            Layout.preferredWidth: side; Layout.preferredHeight: side
                            fillMode: Image.PreserveAspectFit
                            cache: false
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: psnQr.big = !psnQr.big
                            }
                        }
                        ApText {
                            visible: psnQr.visible
                            role: "small"
                            text: psnQr.big ? qsTr("Натисни на код, щоб зменшити") : qsTr("Натисни на код, щоб збільшити")
                        }
                        ApText {
                            visible: psnPage.step === 3 && home.cloud.myPsnQr
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "hint"
                            text: home.cloud.myPsnLink !== ""
                                ? qsTr("Або з телефона: відкрий звичайну камеру, наведи її на цей QR-код і натисни на посилання, яке з'явиться.")
                                : qsTr("Відкрий звичайну камеру телефона, наведи її на цей QR-код і натисни на посилання, яке з'явиться. Увійди у свій акаунт PSN і підтверди вхід на приставці.")
                        }
                        ApButton {
                            visible: psnPage.step === 3 && psnPage.hasEntry
                            Layout.topMargin: 6
                            ghost: home.cloud.myPsnLink !== ""
                            text: home.cloud.myPsnQr && home.cloud.myPsnLink === "" && home.cloud.myPsnCode === ""
                                ? qsTr("✓ QR-код відскановано, вхід підтвердив")
                                : qsTr("✓ Вхід на приставці підтвердив")
                            onClicked: home.cloud.myPsnDone()
                        }
                        // крок 3: адмін завершує / готово
                        ApText {
                            visible: psnPage.step === 4
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "lead"
                            text: qsTr("Адміністратор завершує підключення, зазвичай 1–2 хвилини. Можна закрити програму чи займатись іншим.")
                        }
                        ApText {
                            visible: psnPage.step === 5
                            Layout.fillWidth: true; Layout.maximumWidth: 560
                            role: "lead"
                            color: ap.ok
                            text: qsTr("Твій акаунт збережено: наступного разу просто бронюй і грай, приставка сама відкриється під ним.")
                        }
                        ApButton {
                            visible: home.cloud.myPsn !== ""
                            Layout.topMargin: 10
                            ghost: true; small: true
                            text: qsTr("Грати на спільному")
                            onClicked: root.showConfirmDialog(qsTr("Спільний акаунт"), qsTr("Перейти на спільний акаунт AnyPlay? Свій акаунт доведеться підключати заново."),
                                                              () => home.cloud.setMyPsn(""))
                        }
                    }
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: home.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
                        spacing: 0
                        ApText { role: "cap"; text: qsTr("Зараз"); Layout.bottomMargin: 6 }
                        ApRow {
                            title: qsTr("Акаунт для гри")
                            subtitle: qsTr("приставка відкриє його сама")
                            ApChip {
                                text: psnPage.step === 5 ? (home.cloud.myPsn.indexOf("PSN-") === 0 ? qsTr("свій") : home.cloud.myPsn) : qsTr("спільний AnyPlay")
                                kind: psnPage.step === 5 ? "ok" : ""
                            }
                        }
                        ApRow {
                            title: qsTr("Прогрес")
                            subtitle: qsTr("збереження в GTA")
                            ApChip { text: psnPage.step === 5 ? qsTr("лише твій") : qsTr("спільний"); kind: psnPage.step === 5 ? "ok" : "wait" }
                        }
                        ApText { role: "cap"; text: qsTr("Як підключити свій"); Layout.topMargin: 22; Layout.bottomMargin: 6 }
                        Repeater {
                            model: [
                                { n: 2, t: psnPage.step > 2 && home.cloud.myPsn && home.cloud.myPsn.indexOf("PSN-") !== 0
                                           ? qsTr("1. Вхід у PSN виконано: %1").arg(home.cloud.myPsn) : qsTr("1. Увійди в PSN на сайті Sony"),
                                  s: qsTr("пароль лише на сайті Sony") },
                                { n: 3, t: qsTr("2. Підтверди вхід у свій акаунт на приставці"), s: qsTr("посилання, код або QR з'являться тут") },
                                { n: 4, t: psnPage.step === 5 ? qsTr("3. Готово! Ти граєш на своєму акаунті") : qsTr("3. Адміністратор завершує підключення"), s: qsTr("1–2 хвилини") }
                            ]
                            ApRow {
                                required property var modelData
                                title: modelData.t
                                subtitle: modelData.s
                                titleColor: psnPage.step >= modelData.n ? ap.ink : ap.mute
                                ApChip {
                                    text: psnPage.step > modelData.n || psnPage.step === 5 ? qsTr("готово") : (psnPage.step === modelData.n ? qsTr("зараз") : qsTr("далі"))
                                    kind: psnPage.step > modelData.n || psnPage.step === 5 ? "ok" : (psnPage.step === modelData.n ? "live" : "")
                                }
                            }
                        }
                    }
                }
            }

            // ═════════ ЯК КЕРУВАТИ ═════════
            TabPage {
                visible: !home.gated && home.view === "guide"
                ColumnLayout {
                    width: home.cw
                    spacing: 16
                    RowLayout {   // 117: заголовок і підказка в один рядок, щоб усі плитки влізли без прокрутки
                        Layout.fillWidth: true
                        spacing: 28
                        ApText { role: "h2"; text: qsTr("Як керувати приставкою") }
                        ApText {
                            Layout.fillWidth: true
                            role: "hint"
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            text: Chiaki.controllers.length ? qsTr("Підключено геймпад, тому тут його кнопки. Клавіатура й миша теж працюють. Під час гри ця довідка є в меню AnyPlay (` під Esc).")
                                                            : qsTr("Праворуч у плитці клавіша на клавіатурі. Працює в будь-якій грі й у меню PS5. Під час гри ця довідка є в меню AnyPlay (` під Esc).")
                        }
                    }
                    AnyPlayGuide {
                        Layout.fillWidth: true
                        columns: home.cw >= 1100 ? 3 : home.twoCol ? 2 : 1
                        menuKey: home.menuKeyText
                    }
                }
            }

            // ═════════ КЛАВІШІ: екран керування з геймпадом (окремий компонент) ═════════
            Loader {
                id: keysLoader
                anchors.fill: parent
                // на всю ширину: вміст з полями сторінки (рівно під краями верхньої смуги),
                // смуга прокрутки біля краю вікна, як і на інших вкладках
                anchors.topMargin: 22
                anchors.bottomMargin: 16
                active: !home.gated && home.view === "keys"
                visible: active
                sourceComponent: Component {
                    AnyPlayControls {
                        inGame: home.overGame
                        sideInset: home.padX
                        onCloseRequested: home.view = "home"
                        onPickerRequested: home.openPickerFromKeys()
                    }
                }
            }

            // ═════════ СПІЛЬНИЙ PSN (адмін) ═════════
            TabPage {
                id: sharedPage
                property int rev: 0   // перечитати, що зараз у цій програмі (вхід PSN, прив'язана PS5)
                readonly property var con: home.adm.console || null
                readonly property var list: home.sharedList                // К16: усі спільні акаунти по приставках (null — старий сервер)
                readonly property bool hasAny: list ? list.length > 0 : !!con
                // К16: групи за приставкою, у порядку приставок сервера; активний акаунт першим
                readonly property var groups: {
                    if (!list) return [];
                    const by = {}, order = [];
                    for (let i = 0; i < list.length; i++) {
                        const r = list[i];
                        const u = r.unit;
                        const key = u && typeof u === "object" ? String(u.id) : String(u === undefined || u === null ? 0 : u);
                        if (!by[key]) { by[key] = { key: key, name: home.unitLabel(u), rows: [] }; order.push(key); }
                        by[key].rows.push(r);
                    }
                    return order.map((k) => { by[k].rows.sort((x, y) => (y.active ? 1 : 0) - (x.active ? 1 : 0)); return by[k]; });
                }
                readonly property var locals: { rev; return home.cloud.localConsoles(); }   // PS5, прив'язані в цій програмі
                property string pickedMac: ""                                              // яку з них передавати (якщо кілька)
                readonly property string localPsn: { rev; return home.cloud.localPsnName(); }
                readonly property string localPs5: { rev; return home.cloud.localConsoleName(sharedPage.pickedMac); }
                readonly property int registState: { rev; return home.cloud.localRegistState(); }   // 0 немає, 1 під цим акаунтом, 2 під іншим
                visible: !home.gated && home.isAdmin && home.view === "shared"
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: 10
                        ApText { role: "h2"; text: sharedPage.list ? qsTr("Спільні акаунти PSN") : qsTr("Спільний акаунт PSN") }
                        ApText {
                            visible: !sharedPage.list || !sharedPage.hasAny
                            role: "cap"; text: qsTr("Зараз роздається клієнтам"); Layout.topMargin: 10
                        }
                        Text {   // старий сервер (один акаунт) або жодного акаунта
                            visible: !sharedPage.list || !sharedPage.hasAny
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 34; font.letterSpacing: 1
                            color: sharedPage.hasAny ? ap.ink : ap.bad
                            text: sharedPage.hasAny ? (sharedPage.con.psn_name || qsTr("акаунт PSN (нік ще не визначено)")) : qsTr("Акаунта немає")
                        }
                        ApText {
                            visible: !sharedPage.list || !sharedPage.hasAny
                            Layout.fillWidth: true
                            role: "lead"
                            text: sharedPage.hasAny
                                ? qsTr("Приставка: %1. Передано на сервер: %2").arg(sharedPage.con.label || "PS5").arg(home.cloud.formatTime(sharedPage.con.updated_at))
                                : qsTr("Клієнти поки не можуть грати. Передай акаунт: три кроки праворуч.")
                        }
                        ApButton {
                            visible: !sharedPage.list && !!sharedPage.con
                            Layout.topMargin: 6
                            ghost: true; danger: true
                            text: qsTr("Видалити")
                            onClicked: confirmPopup.ask({ title: qsTr("Видалити спільний акаунт"), name: sharedPage.con ? (sharedPage.con.psn_name || "PSN") : "", action: qsTr("Видалити"),
                                text: qsTr("Прибрати цей акаунт із сервера? Клієнти не зможуть підключатись, доки не передаси новий акаунт. Хто вже грає, дограє до розриву з'єднання."),
                                run: () => home.cloud.adminDropShared() })
                        }
                        ApText {
                            visible: !!sharedPage.list && sharedPage.hasAny
                            Layout.fillWidth: true
                            role: "lead"
                            text: qsTr("Нові ігри клієнтів ідуть через активний акаунт своєї приставки. Якщо він перестане працювати, зроби активним інший: хто вже грає, дограє на попередньому.")
                        }
                        // К16: акаунти по приставках
                        Repeater {
                            model: sharedPage.groups
                            ColumnLayout {
                                id: grp
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                spacing: 0
                                ApText {
                                    role: "cap"
                                    Layout.topMargin: grp.index === 0 ? 10 : 18
                                    Layout.bottomMargin: 4
                                    text: grp.modelData.name || qsTr("Приставка")
                                }
                                Repeater {
                                    model: grp.modelData.rows
                                    ApRow {
                                        id: accRow
                                        required property var modelData
                                        required property int index
                                        hairline: index < grp.modelData.rows.length - 1
                                        title: modelData.psn_name || qsTr("акаунт PSN (нік ще не визначено)")
                                        subtitle: (modelData.active ? qsTr("активний: на нього йдуть нові ігри") : qsTr("запасний"))
                                            + (modelData.updated_at ? qsTr(", передано %1").arg(home.dayTime(modelData.updated_at)) : "")
                                        ApChip { visible: !!accRow.modelData.active; text: qsTr("активний"); kind: "ok" }
                                        ApButton {
                                            visible: !accRow.modelData.active
                                            small: true; ghost: true
                                            text: qsTr("Зробити активним")
                                            onClicked: home.cloud.adminSharedActive(accRow.modelData.id)
                                        }
                                        ApButton {
                                            small: true; ghost: true; danger: true
                                            text: qsTr("Видалити")
                                            onClicked: confirmPopup.ask({ title: qsTr("Видалити спільний акаунт"), name: accRow.modelData.psn_name || "PSN", action: qsTr("Видалити"),
                                                text: accRow.modelData.active
                                                    ? qsTr("Прибрати активний акаунт із сервера? Якщо іншого на цій приставці немає, клієнти не зможуть підключатись, доки не передаси новий. Хто вже грає, дограє до розриву з'єднання.")
                                                    : qsTr("Прибрати цей запасний акаунт із сервера?"),
                                                run: () => home.cloud.adminSharedRemove(accRow.modelData.id) })
                                        }
                                    }
                                }
                            }
                        }
                    }
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: home.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
                        spacing: 0
                        ApText {
                            role: "cap"; Layout.bottomMargin: 6
                            text: sharedPage.list ? qsTr("Додати ще один акаунт або приставку") : sharedPage.con ? qsTr("Замінити на інший") : qsTr("Додати акаунт")
                        }
                        ApText {
                            Layout.fillWidth: true
                            Layout.bottomMargin: 6
                            role: "hint"
                            text: sharedPage.list ? qsTr("Три кроки по черзі (комп'ютер і PS5 в одній мережі). Новий акаунт додасться до списку; нова PS5 стане окремою приставкою, і клієнти зможуть бронювати її теж.")
                                : sharedPage.con ? qsTr("Три кроки по черзі (комп'ютер і PS5 в одній мережі). Новий акаунт сам замінить старий.")
                                                 : qsTr("Три кроки по черзі (комп'ютер і PS5 в одній мережі).")
                        }
                        ApRow {
                            title: qsTr("1. Увійти в PSN потрібним акаунтом")
                            subtitle: sharedPage.localPsn ? qsTr("у цій програмі увійдено як: %1").arg(sharedPage.localPsn) : qsTr("у цій програмі вхід у PSN ще не виконано")
                            ApButton {
                                small: true; ghost: true
                                enabled: !home.overGame   // вхід у PSN і прив'язка відкривають свої екрани: під час гри їх не чіпаємо
                                text: qsTr("Увійти")
                                onClicked: { home.reopenShared = true; root.showAnyPlayPsnLogin(false); }
                            }
                        }
                        ApRow {
                            title: qsTr("2. Прив'язати PS5 під цим акаунтом")
                            subtitle: (sharedPage.registState === 1 ? qsTr("✓ Приставку %1 прив'язано під цим акаунтом. ").arg(sharedPage.localPs5)
                                       : sharedPage.registState === 2 ? qsTr("Приставку %1 прив'язано під іншим профілем PS5 (або давно, і програма не знає, під яким). Прив'яжи її заново, інакше клієнтів пускатиме в той старий профіль. ").arg(sharedPage.localPs5)
                                       : "")
                                + qsTr("Код: на PS5 перемкнись на профіль цього акаунта → Налаштування → Система → Дистанційне відтворення → Прив'язати пристрій.")
                            ApButton {
                                small: true; ghost: true
                                enabled: !home.overGame
                                text: qsTr("8 цифр")
                                onClicked: { home.reopenShared = true; root.showRegistDialog("255.255.255.255", true); }
                            }
                        }
                        // К15: у цій програмі прив'язано кілька PS5: яку з них передати
                        Flow {
                            visible: sharedPage.locals.length > 1
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            spacing: 8
                            ApText { role: "hint"; text: qsTr("Яку PS5 передати:"); height: 32; verticalAlignment: Text.AlignVCenter }
                            Repeater {
                                model: sharedPage.locals
                                ApButton {
                                    required property var modelData
                                    small: true
                                    ghost: sharedPage.pickedMac !== modelData.mac && !(sharedPage.pickedMac === "" && sharedPage.locals[0].mac === modelData.mac)
                                    text: modelData.name
                                    onClicked: sharedPage.pickedMac = modelData.mac
                                }
                            }
                        }
                        ApButton {
                            Layout.topMargin: 16
                            Layout.fillWidth: true
                            wrap: true
                            text: sharedPage.localPsn && sharedPage.localPsn !== qsTr("акаунт PSN")
                                ? qsTr("3. Роздавати клієнтам «%1»").arg(sharedPage.localPsn) : qsTr("3. Передати PS5 на сервер")
                            enabled: sharedPage.registState === 1 && sharedPage.localPsn !== ""
                            onClicked: { home.cloud.uploadConsole(sharedPage.pickedMac); home.view = "home"; }
                        }
                        ApText {
                            visible: home.overGame
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            role: "small"
                            text: qsTr("Кроки 1 і 2 відкривають свої екрани, тому доступні після виходу з гри.")
                        }
                    }
                }
            }

            // ═════════ СВОЇ PSN КЛІЄНТІВ (адмін) ═════════
            TabPage {
                id: clientsPage
                property string result: ""
                property bool resultOk: true
                readonly property var own: home.adm.ownPsn && home.adm.ownPsn.length !== undefined ? home.adm.ownPsn : null   // К17
                visible: !home.gated && home.isAdmin && home.view === "clients"
                Connections {
                    target: Chiaki.cloud
                    function onLinkResult(ok, text) { clientsPage.result = text; clientsPage.resultOk = ok; }
                }
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: 10
                        ApText { role: "h2"; text: qsTr("Клієнти зі своїм PSN") }
                        ApText {
                            Layout.fillWidth: true
                            role: "lead"
                            text: qsTr("1) Бот надішле тобі заявку. Натисни «Надіслати QR клієнту» і сфотографуй екран PS5 з QR-кодом (Перемкнути користувача → Додати користувача → Увійти).\n2) Клієнт підтверджує вхід у свій акаунт.\n3) На PS5 перемкнись на його профіль → Налаштування → Система → Дистанційне відтворення → Прив'язати пристрій. Введи 8 цифр тут або напиши їх боту.")
                        }
                        ApText {
                            Layout.fillWidth: true
                            role: "small"
                            text: qsTr("У тій самій мережі, що й PS5, має бути лише цей комп'ютер. Клієнтові це не потрібно. Код потрібен один раз для кожного акаунта.")
                        }
                    }
                    ApCard {   // дизайн 112: блок сторінки на скляній панелі
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: home.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
                        spacing: 0
                        ApText { role: "cap"; text: qsTr("Заявки"); Layout.bottomMargin: 6 }
                        ApText {
                            visible: !(home.adm.psnClients || []).length
                            role: "hint"
                            topPadding: 10; bottomPadding: 10
                            text: qsTr("Зараз заявок немає.")
                        }
                        Repeater {
                            model: home.adm.psnClients || []
                            ColumnLayout {
                                id: cRow
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 8
                                ApRow {
                                    hairline: false
                                    ApButton {
                                        visible: !!cRow.modelData.userId
                                        small: true; ghost: true
                                        text: qsTr("Подарувати гру")
                                        onClicked: home.askGift(cRow.modelData.userId, cRow.modelData.user)
                                    }
                                    title: qsTr("%1, PSN: %2").arg(cRow.modelData.user).arg(cRow.modelData.psn)
                                    subtitle: {
                                        const m = cRow.modelData;
                                        const acc = m.accountId ? qsTr("увійшов у PSN у програмі ✓") : qsTr("ще не увійшов у PSN у програмі");
                                        const s = { requested: qsTr("Чекає QR-код"), qr_sent: qsTr("Код надіслано, чекаємо входу"),
                                                    signed_in: qsTr("Увійшов на PS5, лишилось прив'язати") }[m.status] || m.status;
                                        return s + ". " + acc[0].toUpperCase() + acc.slice(1) + ".";
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.bottomMargin: 12
                                    spacing: 10
                                    ApField {
                                        id: pinField
                                        Layout.preferredWidth: 180
                                        placeholderText: qsTr("8 цифр з PS5")
                                        inputMethodHints: Qt.ImhDigitsOnly
                                        maximumLength: 9
                                    }
                                    ApButton {
                                        small: true
                                        Layout.preferredHeight: pinField.implicitHeight
                                        text: home.cloud.busy ? qsTr("Прив'язую…") : qsTr("Прив'язати")
                                        enabled: !home.cloud.busy && !!cRow.modelData.accountId && pinField.text.replace(/\D/g, "").length === 8
                                        onClicked: { clientsPage.result = ""; home.cloud.linkClientConsole(cRow.modelData.userId, cRow.modelData.accountId, pinField.text); }
                                    }
                                }
                                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }
                            }
                        }
                        ApText {
                            Layout.fillWidth: true
                            Layout.topMargin: 12
                            visible: clientsPage.result !== ""
                            text: clientsPage.result
                            color: clientsPage.resultOk ? ap.ok : ap.bad
                            font.weight: Font.Medium
                        }
                        // К17: усі клієнти зі своїм акаунтом PSN (старий сервер цього списку не віддає: тоді нічого не показуємо)
                        ApText {
                            visible: !!clientsPage.own
                            role: "cap"; Layout.topMargin: 22; Layout.bottomMargin: 6
                            text: qsTr("Клієнти зі своїм PSN")
                        }
                        ApText {
                            visible: !!clientsPage.own && !clientsPage.own.length
                            role: "hint"
                            topPadding: 10; bottomPadding: 10
                            text: qsTr("Поки ніхто не грає на своєму акаунті.")
                        }
                        Repeater {
                            model: clientsPage.own || []
                            ApRow {
                                id: ownRow
                                required property var modelData
                                required property int index
                                hairline: index < clientsPage.own.length - 1
                                title: (modelData.name || modelData.username || qsTr("Клієнт")) + (modelData.username && modelData.name ? " (" + modelData.username + ")" : "")
                                subtitle: {
                                    const m = ownRow.modelData;
                                    const parts = [qsTr("PSN: %1").arg(m.psn || "—")];
                                    const unit = home.unitLabel(m.unit);
                                    if (unit) parts.push(unit);
                                    if (m.lastPlay) parts.push(qsTr("остання гра %1").arg(home.dayTime(m.lastPlay)));
                                    return parts.join(", ");
                                }
                                ApChip {
                                    text: ({ ready: qsTr("готово"), requested: qsTr("чекає QR"), qr_sent: qsTr("чекаємо входу"), signed_in: qsTr("лишилось прив'язати"), pin_wait: qsTr("чекає 8 цифр") })[ownRow.modelData.status] || ownRow.modelData.status || ""
                                    kind: ownRow.modelData.status === "ready" ? "ok" : "wait"
                                }
                                ApButton {
                                    visible: !!ownRow.modelData.userId
                                    small: true; ghost: true
                                    text: qsTr("Подарувати")
                                    onClicked: home.askGift(ownRow.modelData.userId, ownRow.modelData.name || ownRow.modelData.username || "")
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── продовження гри (з вкладки «Гра») ──
        HomePopup {
            id: extendPopup
            maxW: 640
            contentItem: ColumnLayout {
                spacing: 16
                ExtendPanel { Layout.fillWidth: true; visible: extendPopup.opened }
                RowLayout {
                    Layout.fillWidth: true
                    ApButton { ghost: true; text: qsTr("Забронювати ще"); onClicked: { extendPopup.close(); home.view = "book"; } }
                    Item { Layout.fillWidth: true }
                    ApButton { ghost: true; text: qsTr("Закрити"); onClicked: extendPopup.close() }
                }
            }
        }

        // ── підтвердження дії адміна: що саме станеться і з ким (ім'я клієнта великими літерами) ──
        HomePopup {
            id: confirmPopup
            maxW: 520
            property string title: ""
            property string name: ""
            property string text: ""
            property string actionText: ""
            property var run: null
            function ask(o) {
                title = o.title || ""; name = o.name || ""; text = o.text || ""; actionText = o.action || qsTr("Так"); run = o.run || null;
                open();
                confirmCancel.forceActiveFocus(Qt.TabFocusReason);   // Enter одразу після відкриття нічого не руйнує
            }
            function accept() { const f = run; run = null; close(); if (f) f(); }
            onOpenedChanged: if (!opened && home.visible) home.restoreFocus()
            contentItem: ColumnLayout {
                spacing: 12
                ApText { role: "cap"; color: ap.bad; text: confirmPopup.title }
                ApText {
                    visible: confirmPopup.name !== ""
                    Layout.fillWidth: true
                    Layout.rightMargin: 24
                    role: "big"; size: 38
                    font.capitalization: Font.MixedCase
                    lineHeight: 0.9
                    text: confirmPopup.name
                }
                ApText { Layout.fillWidth: true; role: "lead"; text: confirmPopup.text }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    spacing: 10
                    ApButton {
                        id: confirmOk
                        danger: true
                        text: confirmPopup.actionText
                        onClicked: confirmPopup.accept()
                        KeyNavigation.right: confirmCancel
                    }
                    ApButton {
                        id: confirmCancel
                        ghost: true
                        Layout.preferredHeight: confirmOk.height
                        text: qsTr("Скасувати")
                        onClicked: confirmPopup.close()
                        KeyNavigation.left: confirmOk
                    }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // ── подарувати гру на точний час: два барабани, години й хвилини (як у будильнику) ──
        HomePopup {
            id: giftPopup
            maxW: 480
            property var userId: 0
            property string name: ""
            readonly property int minutes: Math.min(2880, giftHours.value * 60 + giftMins.value)   // сервер приймає 10…2880 хв з кроком 5
            readonly property bool valid: minutes >= 10
            function ask(uid, who) {
                userId = uid; name = who || "";
                giftHours.setValue(2); giftMins.setValue(0);
                open();
                giftHours.forceActiveFocus(Qt.TabFocusReason);
            }
            function durText(m) {
                const h = Math.floor(m / 60), x = m % 60;
                return h && x ? qsTr("%1 год %2 хв").arg(h).arg(x) : h ? qsTr("%1 год").arg(h) : qsTr("%1 хв").arg(x);
            }
            function send() {
                if (!valid) return;
                home.cloud.adminGrant(userId, minutes, name);
                close();
            }
            onOpenedChanged: if (!opened && home.visible) home.restoreFocus()
            contentItem: ColumnLayout {
                spacing: 10
                ApText { role: "cap"; text: qsTr("Подарувати гру") }
                ApText {
                    Layout.fillWidth: true
                    Layout.rightMargin: 24
                    role: "big"; size: 38
                    font.capitalization: Font.MixedCase
                    lineHeight: 0.9
                    text: giftPopup.name
                }
                ApText {
                    Layout.fillWidth: true
                    role: "lead"
                    text: qsTr("Гра почнеться просто зараз, без оплати. Клієнт отримає повідомлення в боті.")
                }
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 4
                    spacing: 6
                    ApTumbler {
                        id: giftHours
                        count: 49
                        label: qsTr("годин")
                        KeyNavigation.right: giftMins
                        Keys.onReturnPressed: giftPopup.send()
                        Keys.onEnterPressed: giftPopup.send()
                    }
                    Text {
                        y: giftHours.drumItem.height / 2 - height / 2 - 2
                        text: ":"
                        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 30
                        color: ap.mute
                    }
                    ApTumbler {
                        id: giftMins
                        count: 12
                        step: 5
                        twoDigits: true
                        label: qsTr("хвилин")
                        KeyNavigation.left: giftHours
                        Keys.onReturnPressed: giftPopup.send()
                        Keys.onEnterPressed: giftPopup.send()
                    }
                }
                ApText {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    horizontalAlignment: Text.AlignHCenter
                    font.weight: Font.Medium
                    color: giftPopup.valid ? ap.gold : ap.bad
                    text: !giftPopup.valid ? qsTr("Щонайменше 10 хвилин")
                        : (giftHours.value * 60 + giftMins.value > 2880 ? qsTr("Найбільше 48 год, приблизно до %1") : qsTr("%2, приблизно до %1"))
                            .arg(home.cloud.formatTime(home.nowTs() + giftPopup.minutes * 60)).arg(giftPopup.durText(giftPopup.minutes))
                }
                ApText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    role: "small"
                    text: qsTr("Якщо раніше почнеться чиясь бронь, подарунок триватиме до неї.")
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    spacing: 10
                    ApButton {
                        id: giftOk
                        enabled: giftPopup.valid
                        text: qsTr("Подарувати")
                        onClicked: giftPopup.send()
                    }
                    Item { Layout.fillWidth: true }
                    ApButton {
                        ghost: true
                        Layout.preferredHeight: giftOk.height
                        text: qsTr("Скасувати")
                        onClicked: giftPopup.close()
                    }
                }
            }
        }

        // ── сповіщення ──
        Rectangle {
            id: toast
            property string message: ""
            z: 600
            function show(t) { message = t; toastTimer.restart(); }
            visible: message !== ""
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 24 }
            width: Math.min(zoom.width - 40, 560, toastText.implicitWidth + 34)
            height: toastText.implicitHeight + 24
            radius: ap.radius
            color: ap.dialog
            border.color: ap.edgeHi
            Rectangle {   // смужка заходу сонця зліва
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 8 }
                width: 3; radius: 1.5
                gradient: Gradient { GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
            Text {
                id: toastText
                anchors.centerIn: parent
                width: Math.min(zoom.width - 74, 526, implicitWidth)
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: toast.message
                color: ap.ink
                font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 15
            }
            Timer { id: toastTimer; interval: 8000; onTriggered: toast.message = "" }
            Connections {
                target: Chiaki.cloud
                function onMessage(text) { toast.show(text); }
            }
            Connections {
                target: Chiaki.updater
                function onMessage(text) { toast.show(text); }
            }
            // геймпад підключили або від'єднали — кажемо, чим тепер керувати
            property int padCount: Chiaki.controllers.length
            property bool padSeen: false
            onPadCountChanged: {
                if (padSeen || padCount > 0)
                    toast.show(padCount > 0 ? qsTr("Геймпад підключено: грай ним, як на приставці. Клавіатура й мишка теж працюють, програма перемикається сама.")
                                            : qsTr("Геймпад від'єднано: керування клавіатурою і мишкою."));
                padSeen = true;
            }
        }

        // ── оновлення програми: саме вискакує, коли вийшла нова версія (але не під час гри) ──
        AnyPlayUpdateDialog {
            id: updateDialog
            anchors.fill: parent
            // клавіші (Esc — «Пізніше») ідуть у вікно, навіть якщо воно вискочило на екрані клавіш
            onVisibleChanged: if (visible) home.forceActiveFocus(); else if (home.visible) home.restoreFocus()
        }
    }

    // ── 115: «Меню гри: перегляд» — справжнє меню паузи (AnyPlayStreamMenu, demo: true) на заглушках, на весь екран ──
    Loader {
        id: menuDemoLoader
        anchors.fill: parent
        z: 650
        active: home.menuDemo && home.isAdmin && !home.overGame
        visible: active
        sourceComponent: MenuDemo { onClosed: home.menuDemo = false }
        onLoaded: item.forceActiveFocus()
        onActiveChanged: if (!active && home.visible) home.restoreFocus()
    }

    // ── «У що граєш?» перед грою: розкладка клавіш під гру (на все вікно) ──
    AnyPlayGamePicker {
        id: gamePicker
        anchors.fill: parent
        z: 700
        onPicked: (layoutId) => home.pickedGame(layoutId)
        onDismissed: home.pickerDismissed()
    }

    // ── 115: «Меню гри: перегляд» (адмін, Інструменти) — справжнє меню паузи клієнта без гри ──
    // Екран клієнта обраного розміру (1280×720, MacBook Air 1512×982, 1920×1080) зменшений під це вікно: картинка гри 16:9
    // з чорними смугами, як у грі, меню поверх неї. Меню вантажимо за адресою (Loader.source), а не як тип: AnyPlayStreamMenu
    // сам відкриває AnyPlayHome поверх гри, і пряме посилання тут дало б коло між файлами. demo: true — дані з заглушок,
    // нічого не надсилається на сервер і не змінюється в налаштуваннях; що сталося б у грі, пишемо рядком унизу.
    component MenuDemo: FocusScope {
        id: md
        signal closed()
        property string size: "1512"
        property bool asAdmin: false
        property string note: ""
        readonly property var dims: ({ "1280": [1280, 720], "1512": [1512, 982], "1920": [1920, 1080] })
        readonly property real sw: dims[size][0]
        readonly property real sh: dims[size][1]
        function say(t) { note = t; noteTimer.restart(); }
        Timer { id: noteTimer; interval: 6000; onTriggered: md.note = "" }

        Rectangle { anchors.fill: parent; color: ap.bg1 }
        MouseArea {   // нічого не проходить до панелі під переглядом
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: (wheel) => wheel.accepted = true
        }
        ColumnLayout {
            anchors { fill: parent; leftMargin: 24; rightMargin: 24; topMargin: 16; bottomMargin: 14 }
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 18
                ApText { role: "cap"; text: qsTr("Меню гри: перегляд") }
                ApTabs {
                    compact: true
                    model: [{ id: "1280", text: "1280×720" }, { id: "1512", text: "1512×982" }, { id: "1920", text: "1920×1080" }]
                    current: md.size
                    onActivated: (id) => md.size = id
                }
                ApTabs {
                    compact: true
                    model: [{ id: "client", text: qsTr("Клієнт") }, { id: "admin", text: qsTr("Адмін") }]
                    current: md.asAdmin ? "admin" : "client"
                    onActivated: (id) => md.asAdmin = id === "admin"
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                ApButton { small: true; ghost: true; text: qsTr("Закрити"); onClicked: md.closed() }
            }
            ApText {
                Layout.fillWidth: true
                role: "small"; color: ap.mute
                text: qsTr("Так меню паузи бачить %1 на екрані %2×%3: картинка гри 16:9, чорні смуги як у грі. Клацай і ходи стрілками: нічого не надсилається і не зберігається.")
                    .arg(md.asAdmin ? qsTr("адмін") : qsTr("клієнт")).arg(md.sw).arg(md.sh)
            }
            Item {
                id: stage
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                Item {
                    id: screen
                    width: md.sw; height: md.sh
                    readonly property real k: Math.min(stage.width / md.sw, stage.height / md.sh)
                    scale: k
                    transformOrigin: Item.TopLeft
                    x: Math.round((stage.width - md.sw * k) / 2)
                    y: Math.round((stage.height - md.sh * k) / 2)
                    Rectangle { anchors.fill: parent; color: "black" }
                    Image {   // «гра»: оригінальна сцена AnyPlay (не кадр з гри), вписана 16:9
                        readonly property real gw: Math.min(md.sw, md.sh * 16 / 9)
                        width: gw; height: gw * 9 / 16
                        anchors.centerIn: parent
                        source: "qrc:/anyplay-quality/q2.jpg"
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Loader {
                        id: menuL
                        anchors.fill: parent
                        focus: true
                        Component.onCompleted: setSource(Qt.resolvedUrl("AnyPlayStreamMenu.qml"), { demo: true, demoAdmin: md.asAdmin })
                        onLoaded: { item.demoAdmin = Qt.binding(() => md.asAdmin); item.focusFirst(); }
                    }
                    Connections {
                        target: menuL.item
                        ignoreUnknownSignals: true
                        function onResume() { md.say(qsTr("У грі тут меню закрилось би і гра продовжилась (те саме робить Esc на пунктах ліворуч).")); }
                        function onExit() { md.say(qsTr("У грі тут трансляція закрилась би, час броні йде далі.")); }
                        function onDemoEvent(text) { md.say(text); }
                    }
                }
                Rectangle {   // рамка «екрана»
                    x: screen.x - 1; y: screen.y - 1
                    width: md.sw * screen.k + 2; height: md.sh * screen.k + 2
                    color: "transparent"
                    border.width: 1; border.color: ap.edge
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                spacing: 10
                ApChip { visible: md.note !== ""; kind: "live"; text: qsTr("у грі") }
                ApText {
                    Layout.fillWidth: true
                    role: "small"
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    text: md.note !== "" ? md.note : qsTr("Розмір і роль перемикаються вгорі. Закрити: кнопка «Закрити».")
                    color: md.note !== "" ? ap.ink : ap.faint
                }
            }
        }
    }

    // ── сторінка вкладки: прокручується, якщо вміст вищий за вікно; вміст по центру з полями ──
    component TabPage: Flickable {
        id: pg
        default property alias content: pgInner.data
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: pgInner.childrenRect.height + 48
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        onVisibleChanged: if (visible) contentY = 0
        ScrollBar.vertical: ScrollBar {
            policy: pg.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
        }
        Item {
            id: pgInner
            x: home.padX
            y: 22
            width: home.cw
            height: childrenRect.height
        }
    }

    // ── фішка балансу у верхній смузі: «БАЛАНС 320 ₴» ──
    component BalanceChip: Rectangle {
        id: bc
        signal clicked()
        implicitWidth: bcRow.implicitWidth + 24
        implicitHeight: bcRow.implicitHeight + 14
        radius: ap.radiusSmall
        color: bcMouse.containsMouse ? ap.glassHi : ap.glass
        border.color: bcMouse.containsMouse ? ap.edgeHi : ap.edge
        transform: Translate { y: bcMouse.pressed ? 1 : (bcMouse.containsMouse ? -ap.lift : 0); Behavior on y { NumberAnimation { duration: ap.tHover } } }
        Row {
            id: bcRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.baseline: bcValue.baseline
                text: qsTr("Баланс")
                font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 12
                font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                color: ap.mute
            }
            Text {
                id: bcValue
                text: wallet.primaryText
                font.family: ap.body; font.weight: Font.Bold; font.pixelSize: 15
                color: ap.gold
            }
        }
        MouseArea { id: bcMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: bc.clicked() }
    }

    // ── маленька кнопка-посилання у верхній смузі («Вийти», хрестик) ──
    component LinkButton: Rectangle {
        id: lb
        property string text
        signal clicked()
        implicitWidth: lbText.implicitWidth + 24
        implicitHeight: lbText.implicitHeight + 14
        radius: ap.radiusSmall
        color: lbMouse.containsMouse ? ap.glassHi : ap.glass
        border.color: lbMouse.containsMouse ? ap.edgeHi : ap.edge
        transform: Translate { y: lbMouse.pressed ? 1 : (lbMouse.containsMouse ? -ap.lift : 0); Behavior on y { NumberAnimation { duration: ap.tHover } } }
        Text {
            id: lbText
            anchors.centerIn: parent
            text: lb.text
            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 14
            color: ap.ink
        }
        MouseArea { id: lbMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lb.clicked() }
    }

    // ── вікно поверх екрана: по центру, висота за вмістом, закривається хрестиком, Esc або «Закрити» ──
    component HomePopup: Item {
        id: hp
        property real maxW: 640
        property real padding: 28
        property bool opened: false
        property Item contentItem
        function open() { opened = true; }
        function close() { opened = false; }
        anchors.fill: parent
        z: 500
        visible: opened
        enabled: opened
        onContentItemChanged: if (contentItem) contentItem.parent = hpHolder.contentItem
        Rectangle { anchors.fill: parent; color: ap.veil }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onWheel: (wheel) => { wheel.accepted = true; }
        }
        Rectangle {
            id: hpCard
            readonly property real want: (hp.contentItem ? hp.contentItem.implicitHeight : 0) + 2 * hp.padding
            anchors.centerIn: parent
            width: Math.max(200, Math.min(hp.width - 40, hp.maxW))
            height: Math.max(80, Math.min(hp.height - 40, want))
            radius: ap.cardRadius
            color: ap.dialog
            border.color: ap.edgeHi
            Rectangle {   // відблиск угорі: скло
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
                height: 60; radius: ap.cardRadius - 1
                gradient: Gradient { GradientStop { position: 0; color: "#14ffffff" } GradientStop { position: 1; color: "#00ffffff" } }
            }
            Rectangle {   // лінія заходу сонця вгорі
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: ap.cardRadius; rightMargin: ap.cardRadius }
                height: 3; radius: 1.5
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
            MouseArea {   // кліки всередині вікна його не закривають
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: (wheel) => { wheel.accepted = true; }
            }
            Flickable {
                id: hpHolder
                anchors { fill: parent; margins: hp.padding }
                clip: true
                contentWidth: width
                contentHeight: hp.contentItem ? hp.contentItem.implicitHeight : 0
                interactive: contentHeight > height + 1
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                    policy: hpHolder.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
                }
            }
            Binding { target: hp.contentItem; property: "width"; value: hpHolder.width - (hpHolder.interactive ? 12 : 0); when: !!hp.contentItem }
            Rectangle {   // хрестик
                anchors { top: parent.top; right: parent.right; margins: 10 }
                width: 28; height: 28
                radius: ap.radius
                color: hpClose.containsMouse ? "#22ffffff" : "transparent"
                border.color: hpClose.containsMouse ? ap.edge : "transparent"
                Text { anchors.centerIn: parent; text: "✕"; color: ap.ink; font.family: ap.body; font.pixelSize: 14 }
                MouseArea { id: hpClose; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp.close() }
            }
        }
    }
}
