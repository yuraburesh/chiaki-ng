// AnyPlay: головний екран програми (новий дизайн: вечірній градієнт, вкладки, рядки з тонкими лініями).
// Клієнт: «Гра» (таймер, мої броні, налаштування гри), «Бронювання», «Якість», «Мій PSN», «Як керувати», «Клавіші».
// Адмін: «Панель» (хто грає, завершити гру, закрити доступ), «Спільний PSN», «Свої PSN», а також «Якість», «Як керувати», «Клавіші».
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Rectangle {
    id: home
    property var cloud: Chiaki.cloud
    property var updater: Chiaki.updater
    readonly property var speed: Chiaki.speedTest || null
    property int tick: 0
    property bool serviceMode: false     // адмін тимчасово відкрив повний (сервісний) інтерфейс
    readonly property bool isAdmin: cloud.loggedIn && cloud.admin
    readonly property var adm: cloud.adminInfo || ({})
    readonly property var cur: adm.current || null
    readonly property string st: cloud.state
    // без входу чи без зв'язку з сервером — лише екран входу / помилки, без вкладок
    readonly property bool gated: !cloud.loggedIn || st === "login" || st === "pairing" || st === "offline"
    // клієнт увійшов, але грати зараз не можна (застаріла програма, приставка недоступна) — замість вкладки «Гра»
    readonly property bool gameGate: !isAdmin && (st === "update" || st === "no_console")
    readonly property var mine: (cloud.bookInfo && cloud.bookInfo.mine) || []
    property string view: "home"         // home | book | quality | psn | guide | keys | (адмін) shared | clients
    signal openKeys()                    // лишився для сумісності: клавіші тепер окрема вкладка
    color: ap.bg1
    focus: visible

    AnyPlayStyle { id: ap }

    // ── розміри: до 1600 px як у макеті, на великих екранах (2K, 4K без масштабу системи) усе пропорційно більше ──
    readonly property real zoomK: Math.max(1, Math.min(2.2, Math.min(width / 1600, height / 1000)))
    readonly property real pageW: zoom.width
    readonly property real padX: Math.max(pageW < 1100 ? 20 : 28, (pageW - 1240) / 2)
    readonly property real cw: pageW - 2 * padX                      // ширина вмісту
    readonly property bool twoCol: cw >= 840
    readonly property real colGap: cw > 1000 ? 64 : 40
    readonly property real leftW: twoCol ? Math.floor((cw - colGap) * 1.25 / 2.25) : cw
    readonly property real rightW: twoCol ? cw - colGap - leftW : cw
    readonly property real timerSize: Math.max(64, Math.min(120, pageW * 0.1))
    readonly property real bigSize: Math.max(34, Math.min(52, pageW * 0.05))
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
        if (view === "shared") { sharedPage.rev++; home.cloud.refreshAdmin(); }
        if (view === "clients") { clientsPage.result = ""; home.cloud.refreshAdmin(); }
    }
    onIsAdminChanged: view = "home"
    Component.onCompleted: loadMine()

    function nowTs() { tick; return Math.floor(Date.now() / 1000) + cloud.clockSkew; }
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
        return { text: qsTr("оплачено"), kind: "ok" };
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
    function playNow() {
        const i = consoleIndex();
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

    // ── головна дія екрана (Enter) ──
    function primaryAction() {
        if (home.gated || home.gameGate || home.view === "home") {
            switch (home.st) {
            case "play": home.isAdmin ? adminConnect() : home.play(); break;
            case "login": home.cloud.login(); break;
            case "pairing": home.cloud.cancelLogin(); break;
            case "offline": home.cloud.refresh(); break;
            case "no_console": home.cloud.openBot(); break;
            case "update":
                if (home.updater && home.updater.available) home.updater.show(); else home.cloud.openBot();
                break;
            default: home.view = "book";
            }
        }
    }
    function adminConnect() {
        const c = home.cur;
        if (c)
            root.showConfirmDialog(qsTr("Підключитись"), c.live
                ? qsTr("Зараз на приставці грає %1. Якщо підключишся, його трансляція перерветься. Підключитись?").arg(c.user)
                : qsTr("Зараз час броні %1 (він ще не підключився). Поки ти на приставці, клієнт не зможе зайти. Підключитись?").arg(c.user),
                () => home.play());
        else
            home.play();
    }

    readonly property bool popupOpen: extendPopup.opened || updateDialog.visible || gamePicker.visible
    Keys.onReturnPressed: if (!popupOpen) primaryAction()
    Keys.onEnterPressed: if (!popupOpen) primaryAction()
    Keys.onEscapePressed: {
        if (updateDialog.visible)
            updateDialog.closeByEscape();
        else if (popupOpen)
            closePopups();
        else if (home.view !== "home" && !home.gated)
            home.view = "home";
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
        interval: 1200; repeat: true
        running: home.cloud.reconnectOnce && home.visible
        onRunningChanged: if (running) tries = 0
        onTriggered: {
            if (Chiaki.session) { home.cloud.reconnectOnce = false; return; }
            if (home.cloud.state === "play" && home.consoleIndex() >= 0) {
                home.cloud.reconnectOnce = false;
                home.playNow();   // без питання «У що граєш?»: гра та сама
            } else if (++tries > 25) {
                home.cloud.reconnectOnce = false;
                toast.show(qsTr("Не вдалося підключитись самому. Натисни «Грати»."));
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
    function closePopups() { extendPopup.close(); }
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
    }

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
            readonly property bool oneLine: brand.implicitWidth + tabsInline.implicitWidth + who.implicitWidth + 84 <= width
            readonly property var tabModel: home.isAdmin
                ? [{ id: "home", text: qsTr("Панель") }, { id: "shared", text: qsTr("Спільний PSN") }, { id: "clients", text: qsTr("Свої PSN") },
                   { id: "quality", text: qsTr("Якість") }, { id: "guide", text: qsTr("Як керувати") }, { id: "keys", text: qsTr("Клавіші") }]
                : [{ id: "home", text: qsTr("Гра") }, { id: "book", text: qsTr("Бронювання") }, { id: "quality", text: qsTr("Якість") },
                   { id: "psn", text: qsTr("Мій PSN") }, { id: "guide", text: qsTr("Як керувати") }, { id: "keys", text: qsTr("Клавіші") }]
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
                        Text {
                            text: "ANYPLAY"
                            font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 24; font.letterSpacing: 3
                            color: ap.ink
                        }
                        Text {
                            text: qsTr("ОРЕНДА PS5: GTA ТА ІНШІ ІГРИ")
                            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 11; font.letterSpacing: 2
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
                        Text {
                            visible: home.cloud.loggedIn && home.cloud.userName !== ""
                            Layout.maximumWidth: 180
                            text: home.cloud.userName
                            font.family: ap.body; font.pixelSize: 13
                            color: ap.mute
                            elide: Text.ElideRight
                        }
                        LinkButton {
                            visible: home.cloud.loggedIn
                            text: qsTr("Вийти")
                            onClicked: root.showConfirmDialog(qsTr("Вийти з акаунта"), qsTr("Вийти з AnyPlay на цьому комп'ютері?"), () => home.cloud.logout())
                        }
                        LinkButton {
                            text: "✕"
                            onClicked: root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit())
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
            // вкладки в один рядок з назвою — поза розкладкою рядка, щоб їх поява не зсувала решту
            ApTabs {
                id: tabsInline
                x: brand.width + 28
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
                            case "pairing": return qsTr("Відкрився бот @play_any_bot. Натисни там «Start» і повертайся сюди.");
                            case "offline": return qsTr("Спробуємо знову за хвилину.");
                            case "no_console": return qsTr("Приставка тимчасово недоступна: кнопка «🆘 Допомога» в боті.");
                            case "update": return home.updater && home.updater.available
                                ? qsTr("Ця версія програми застаріла, і грати з неї вже не можна. Натисни «Оновити програму»: AnyPlay завантажить нову версію, ненадовго закриється і відкриється знову. Вхід і броні збережуться.")
                                : qsTr("Ця версія програми застаріла, і грати з неї вже не можна. Завантаж нову в боті: кнопка «Програма». Встановлюється поверх старої, вхід і броні зберігаються.");
                            default: return qsTr("Вхід через Telegram, без паролів. Приставка відкриється сама в час твоєї оплаченої броні.");
                            }
                        }
                    }
                    ApButton {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 10
                        minWidth: 260
                        text: {
                            switch (home.st) {
                            case "pairing": return qsTr("Скасувати");
                            case "offline": return qsTr("Спробувати ще");
                            case "no_console": return qsTr("Відкрити бота");
                            case "update": return home.updater && home.updater.available ? qsTr("Оновити програму") : qsTr("Завантажити нову версію");
                            default: return qsTr("Увійти через Telegram");
                            }
                        }
                        onClicked: home.primaryAction()
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
                    // ліворуч: таймер і головна кнопка
                    ColumnLayout {
                        id: hero
                        readonly property bool timer: (home.st === "play") || (home.st === "wait" && home.cloud.nextStart > 0 && home.cloud.nextStart - home.nowTs() > 0)
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 8
                        spacing: 12
                        ApText {
                            role: "eyebrow"
                            text: home.st === "play" ? qsTr("Час твоєї гри") : (home.cloud.nextStart ? qsTr("Твоя наступна гра") : qsTr("Бронювання"))
                        }
                        ApTimer {
                            visible: hero.timer
                            size: home.timerSize
                            color: home.st === "play" ? ap.gold : ap.ink
                            text: home.st === "play" ? home.dur(home.cloud.endTs - home.nowTs()) : home.dur(home.cloud.nextStart - home.nowTs())
                        }
                        ApText {
                            visible: !hero.timer
                            Layout.fillWidth: true
                            role: "big"; size: home.bigSize
                            text: home.cloud.nextStart ? qsTr("Вже скоро!") : qsTr("Немає оплачених броней")
                        }
                        ApText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 560
                            role: "lead"; rich: true
                            text: {
                                const c = home.cloud;
                                if (home.st === "play")
                                    return qsTr("Лишилось до кінця. Гра до <b>%1</b>, потім завершиться сама.").arg(c.formatTime(c.endTs))
                                        + (c.playPsn ? " " + (c.playOwn ? qsTr("Акаунт PSN: %1 (твій).") : qsTr("Акаунт PSN: %1 (спільний).")).arg(c.playPsn) : "");
                                if (c.nextStart)
                                    return qsTr("До початку гри <b>%1–%2</b>. Доступ відкриється сам рівно в цей час, програму можна не закривати.").arg(c.formatTime(c.nextStart)).arg(c.formatTime(c.nextEnd));
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
                                text: home.st === "play" ? (home.consoleIndex() >= 0 ? qsTr("▶ Грати") : qsTr("Підключаємо приставку…"))
                                    : (home.cloud.nextStart ? qsTr("Забронювати ще") : qsTr("Забронювати час"))
                                onClicked: home.primaryAction()
                            }
                            ApButton {
                                visible: home.st === "play"
                                ghost: true
                                height: primaryBtn.height
                                text: qsTr("Продовжити гру")
                                onClicked: extendPopup.open()
                            }
                        }
                    }
                    // праворуч: мої броні й налаштування гри
                    ColumnLayout {
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
                            title: qsTr("Якість картинки")
                            subtitle: home.cloud.autoQuality ? qsTr("сама підлаштовується під інтернет") : qsTr("стала, обрана вручну")
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
                    ColumnLayout {
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 8
                        spacing: 12
                        ApText {
                            role: "eyebrow"
                            color: home.adm.closed ? ap.bad : ap.cyan
                            text: home.adm.closed ? qsTr("Доступ клієнтам закрито") : qsTr("Панель адміна")
                        }
                        ApText {
                            Layout.fillWidth: true
                            role: "big"; size: home.bigSize
                            font.capitalization: home.cur ? Font.MixedCase : Font.AllUppercase
                            text: home.cur ? home.cur.user : qsTr("Зараз ніхто не грає")
                        }
                        ApText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 560
                            role: "lead"
                            text: {
                                const c = home.cur;
                                if (c)
                                    return (c.live ? qsTr("у грі") : qsTr("ще не підключився")) + ", "
                                        + qsTr("%1–%2, лишилось %3").arg(home.cloud.formatTime(c.start)).arg(home.cloud.formatTime(c.end)).arg(home.dur(c.end - home.nowTs()))
                                        + home.psnLine(c, "\n");
                                const n = home.adm.next || [];
                                return n.length ? qsTr("Наступна бронь: %1, %2–%3").arg(n[0].user).arg(home.cloud.formatTime(n[0].start)).arg(home.cloud.formatTime(n[0].end)) + home.psnLine(n[0], "\n")
                                                : qsTr("Найближчих оплачених броней немає.");
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            spacing: 10
                            ApButton {   // адмін може зайти на приставку будь-коли
                                id: adminPrimary
                                minWidth: 260
                                text: home.consoleIndex() >= 0 ? qsTr("Підключитись до приставки") : qsTr("Шукаю PS5…")
                                onClicked: home.adminConnect()
                            }
                            ApButton {
                                visible: !!home.cur
                                ghost: true
                                height: adminPrimary.height
                                text: qsTr("Завершити гру клієнта")
                                onClicked: {
                                    const c = home.cur;
                                    if (c)
                                        root.showConfirmDialog(qsTr("Завершити гру"), qsTr("Завершити гру %1 просто зараз? Приставка відключиться, клієнт отримає повідомлення в боті.").arg(c.user),
                                                               () => home.cloud.adminKick(c.id));
                                }
                            }
                            ApButton {
                                ghost: true
                                danger: !home.adm.closed
                                height: adminPrimary.height
                                text: home.adm.closed ? qsTr("Відкрити доступ") : qsTr("Закрити доступ усім")
                                onClicked: {
                                    if (home.adm.closed)
                                        home.cloud.adminSetClosed(false);
                                    else
                                        root.showConfirmDialog(qsTr("Закрити доступ"), qsTr("Тимчасово закрити доступ усім клієнтам? Хто грає, відключиться, бот показуватиме «технічні роботи», поки не відкриєш знову."),
                                                               () => home.cloud.adminSetClosed(true));
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        id: adminRight
                        readonly property var later: home.cur ? (home.adm.next || []).slice(0, 3) : (home.adm.next || []).slice(1, 4)
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 12
                        spacing: 0
                        ApText { visible: adminRight.later.length > 0; role: "cap"; text: qsTr("Далі"); Layout.bottomMargin: 6 }
                        Repeater {
                            model: adminRight.later
                            ApRow {
                                required property var modelData
                                title: modelData.user
                                subtitle: home.cloud.formatTime(modelData.start) + "–" + home.cloud.formatTime(modelData.end) + home.psnLine(modelData, ", ")
                            }
                        }
                        ApText { role: "cap"; text: qsTr("Інструменти"); Layout.topMargin: adminRight.later.length > 0 ? 22 : 0; Layout.bottomMargin: 6 }
                        ApRow {
                            title: qsTr("Спільний PSN")
                            subtitle: qsTr("акаунт, на якому грають клієнти")
                            clickable: true
                            onClicked: home.view = "shared"
                            ApChip {
                                text: home.adm.console ? (home.adm.console.psn_name || qsTr("акаунт на %1").arg(home.adm.console.label || "PS5")) : qsTr("не передано")
                                kind: home.adm.console ? "ok" : "bad"
                            }
                        }
                        ApRow {
                            title: qsTr("Свої PSN")
                            subtitle: qsTr("клієнти, які грають на своєму акаунті")
                            clickable: true
                            onClicked: home.view = "clients"
                            ApChip {
                                text: (home.adm.psnClients || []).length ? qsTr("чекають: %1").arg(home.adm.psnClients.length) : qsTr("немає заявок")
                                kind: (home.adm.psnClients || []).length ? "wait" : ""
                            }
                        }
                        ApRow {
                            title: qsTr("CRM")
                            subtitle: qsTr("броні й клієнти, у боті")
                            clickable: true
                            onClicked: { home.cloud.openBot(); toast.show(qsTr("У боті натисни кнопку «CRM» внизу зліва")); }
                            ApChip { text: qsTr("відкрити") }
                        }
                        ApRow {
                            title: qsTr("Сервіс")
                            subtitle: qsTr("усі налаштування програми")
                            clickable: true
                            onClicked: home.serviceMode = true
                            ApChip { text: qsTr("відкрити") }
                        }
                    }
                }
            }

            // ═════════ БРОНЮВАННЯ ═════════
            TabPage {
                visible: !home.gated && !home.isAdmin && home.view === "book"
                BookPanel {
                    width: home.cw
                    visible: home.view === "book" && !home.gated && !home.isAdmin
                }
            }

            // ═════════ ЯКІСТЬ ═════════
            TabPage {
                visible: !home.gated && home.view === "quality"
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ColumnLayout {
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: 6
                        ApText { role: "h2"; text: qsTr("Якість картинки") }
                        ApText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 560
                            role: "hint"
                            text: qsTr("«Авто» сама знижує якість, коли зв'язок слабшає, щоб гра не відставала. Якщо обереш інше, якість буде сталою. Під час гри її можна змінити в меню AnyPlay.")
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            spacing: 0
                            Repeater {
                                model: [
                                    { level: -1, name: qsTr("Авто (радимо)"), info: qsTr("сама підбирає під твій інтернет, зараз: %1").arg(home.levelName()) },
                                    { level: 0, name: qsTr("Економна"), info: qsTr("540p, 30 кадр/с, для слабкого чи мобільного інтернету") },
                                    { level: 1, name: qsTr("Оптимальна"), info: qsTr("720p, 60 кадр/с, підходить більшості (від 15 Мбіт/с)") },
                                    { level: 2, name: qsTr("Максимальна"), info: qsTr("1080p, 60 кадр/с, швидкий інтернет (від 30 Мбіт/с, краще кабель)") },
                                    { level: 3, name: qsTr("Ультра"), info: qsTr("1080p, 60 кадр/с і ШІ-чіткість на великому екрані; якщо ноутбук не встигає, обробка спроститься сама") }
                                ]
                                ApOpt {
                                    required property var modelData
                                    text: modelData.name
                                    sub: modelData.info
                                    checked: modelData.level < 0 ? home.cloud.autoQuality : (!home.cloud.autoQuality && home.cloud.qualityLevel === modelData.level)
                                    onClicked: home.setQuality(modelData.level)
                                }
                            }
                        }
                    }
                    // праворуч: необов'язкова перевірка інтернету
                    ColumnLayout {
                        id: speedCol
                        readonly property var sp: home.speed
                        readonly property bool done: !!sp && sp.stage === "done" && sp.downMbps >= 0
                        readonly property int rec: done ? sp.recommendedLevel : -1
                        // «Максимальна або Ультра»: якщо вже стоїть «Ультра», лишаємо її
                        readonly property int applyLevel: rec === 2 && home.cloud.qualityLevel === 3 ? 3 : rec
                        visible: !!sp
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: home.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
                        spacing: 10
                        function fmt(x) { return x >= 100 ? Math.round(x).toString() : x.toFixed(1).replace(".", ","); }
                        ApText { role: "cap"; text: qsTr("Перевірити інтернет") }
                        ApText {
                            Layout.fillWidth: true
                            role: "small"
                            text: qsTr("Необов'язково. Перевіряє інтернет цього комп'ютера: швидкість і затримку. Гра ще залежить від того, Wi-Fi чи кабель: з кабелем стабільніше.")
                        }
                        ApButton {
                            ghost: true
                            text: speedCol.sp && speedCol.sp.running ? qsTr("Зупинити") : (speedCol.done ? qsTr("Перевірити ще раз") : qsTr("Перевірити інтернет"))
                            onClicked: speedCol.sp.running ? speedCol.sp.cancel() : speedCol.sp.start(true)
                        }
                        Rectangle {   // смуга прогресу
                            visible: !!speedCol.sp && speedCol.sp.running
                            Layout.fillWidth: true
                            Layout.preferredHeight: 2
                            color: ap.hair
                            Rectangle {
                                height: parent.height
                                width: parent.width * (speedCol.sp ? speedCol.sp.progress : 0)
                                color: ap.ink
                            }
                        }
                        ApText {
                            visible: !!speedCol.sp && speedCol.sp.running
                            role: "small"
                            text: !speedCol.sp ? "" : speedCol.sp.stage === "ping" ? qsTr("Міряємо затримку…")
                                : speedCol.sp.stage === "down" ? qsTr("Міряємо швидкість завантаження…") : qsTr("Міряємо віддачу…")
                        }
                        ApText {
                            visible: !!speedCol.sp && speedCol.sp.error !== ""
                            Layout.fillWidth: true
                            color: ap.bad
                            text: speedCol.sp ? speedCol.sp.error : ""
                        }
                        ColumnLayout {
                            visible: speedCol.done
                            Layout.fillWidth: true
                            spacing: 0
                            ApText {
                                Layout.fillWidth: true
                                Layout.bottomMargin: 4
                                font.weight: Font.Medium
                                text: speedCol.done ? qsTr("Швидкість %1 Мбіт/с, затримка %2 мс").arg(speedCol.fmt(speedCol.sp.downMbps)).arg(Math.round(speedCol.sp.pingMs)) : ""
                            }
                            ApRow {
                                title: qsTr("Швидкість")
                                ApChip { text: speedCol.done ? qsTr("%1 Мбіт/с").arg(speedCol.fmt(speedCol.sp.downMbps)) : "" }
                            }
                            ApRow {
                                title: qsTr("Затримка")
                                subtitle: qsTr("до 40 мс добре, понад 80 мс гра може відставати")
                                ApChip {
                                    text: speedCol.done && speedCol.sp.pingMs >= 0 ? qsTr("%1 мс").arg(Math.round(speedCol.sp.pingMs)) : qsTr("невідомо")
                                    kind: speedCol.done && speedCol.sp.pingMs >= 0 ? (speedCol.sp.pingMs <= 40 ? "ok" : (speedCol.sp.pingMs > 80 ? "wait" : "")) : ""
                                }
                            }
                            ApRow {
                                visible: speedCol.done && speedCol.sp.upMbps >= 0
                                title: qsTr("Віддача")
                                ApChip { text: speedCol.done ? qsTr("%1 Мбіт/с").arg(speedCol.fmt(speedCol.sp.upMbps)) : "" }
                            }
                            ApRow {
                                title: qsTr("Підійде")
                                subtitle: qsTr("радимо за швидкістю")
                                ApChip {
                                    kind: "ok"
                                    text: speedCol.rec === 2 ? qsTr("Максимальна або Ультра") : speedCol.rec === 1 ? qsTr("Оптимальна") : qsTr("Економна")
                                }
                            }
                            ApButton {
                                Layout.topMargin: 14
                                readonly property bool same: !home.cloud.autoQuality && home.cloud.qualityLevel === speedCol.applyLevel
                                enabled: speedCol.rec >= 0 && !same
                                text: same ? qsTr("Застосовано") : qsTr("Застосувати: %1").arg(home.levelNames[Math.max(0, speedCol.applyLevel)])
                                onClicked: home.setQuality(speedCol.applyLevel)
                            }
                            ApText {
                                Layout.fillWidth: true
                                Layout.topMargin: 6
                                role: "small"
                                visible: home.cloud.autoQuality
                                text: qsTr("Зараз увімкнено «Авто». Якщо застосуєш пораду, якість стане сталою.")
                            }
                        }
                    }
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
                    ColumnLayout {
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
                    ColumnLayout {
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
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        ApText { role: "h2"; text: qsTr("Як керувати приставкою") }
                        ApText {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 760
                            role: "hint"
                            text: (Chiaki.controllers.length ? qsTr("Підключено геймпад, тому нижче кнопки геймпада. Клавіатура й мишка теж працюють: програма сама перемикається на те, чим ти щойно натиснув. ")
                                                             : qsTr("Меню PS, як закрити гру і запустити іншу. Клавіші на клавіатурі вказано праворуч. "))
                                + qsTr("Це працює в будь-якій грі й у меню PS5. Під час гри ця довідка є в меню AnyPlay (відкривається клавішею ` під Esc), пункт «Керування приставкою».")
                        }
                    }
                    AnyPlayGuide {
                        Layout.fillWidth: true
                        columns: home.twoCol ? 2 : 1
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
                        inGame: false
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
                readonly property string localPsn: { rev; return home.cloud.localPsnName(); }
                readonly property string localPs5: { rev; return home.cloud.localConsoleName(); }
                readonly property int registState: { rev; return home.cloud.localRegistState(); }   // 0 немає, 1 під цим акаунтом, 2 під іншим
                visible: !home.gated && home.isAdmin && home.view === "shared"
                GridLayout {
                    width: home.cw
                    columns: home.twoCol ? 2 : 1
                    columnSpacing: home.colGap
                    rowSpacing: 28
                    ColumnLayout {
                        Layout.preferredWidth: home.leftW
                        Layout.maximumWidth: home.leftW
                        Layout.alignment: Qt.AlignTop
                        spacing: 10
                        ApText { role: "h2"; text: qsTr("Спільний акаунт PSN") }
                        ApText { role: "cap"; text: qsTr("Зараз роздається клієнтам"); Layout.topMargin: 10 }
                        Text {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 34; font.letterSpacing: 1
                            color: sharedPage.con ? ap.ink : ap.bad
                            text: sharedPage.con ? (sharedPage.con.psn_name || qsTr("акаунт PSN (нік ще не визначено)")) : qsTr("Акаунта немає")
                        }
                        ApText {
                            Layout.fillWidth: true
                            role: "lead"
                            text: sharedPage.con
                                ? qsTr("Приставка: %1. Передано на сервер: %2").arg(sharedPage.con.label || "PS5").arg(home.cloud.formatTime(sharedPage.con.updated_at))
                                : qsTr("Клієнти поки не можуть грати. Передай акаунт: три кроки праворуч.")
                        }
                        ApButton {
                            visible: !!sharedPage.con
                            Layout.topMargin: 6
                            ghost: true; danger: true
                            text: qsTr("Видалити")
                            onClicked: root.showConfirmDialog(qsTr("Видалити спільний акаунт"),
                                qsTr("Прибрати акаунт «%1» із сервера? Клієнти не зможуть підключатись, доки не передаси новий акаунт. Хто вже грає, дограє до розриву з'єднання.")
                                    .arg(sharedPage.con ? (sharedPage.con.psn_name || "PSN") : ""),
                                () => home.cloud.adminDropShared())
                        }
                    }
                    ColumnLayout {
                        Layout.preferredWidth: home.rightW
                        Layout.maximumWidth: home.rightW
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: home.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
                        spacing: 0
                        ApText { role: "cap"; text: sharedPage.con ? qsTr("Замінити на інший") : qsTr("Додати акаунт"); Layout.bottomMargin: 6 }
                        ApText {
                            Layout.fillWidth: true
                            Layout.bottomMargin: 6
                            role: "hint"
                            text: sharedPage.con ? qsTr("Три кроки по черзі (комп'ютер і PS5 в одній мережі). Новий акаунт сам замінить старий.")
                                                 : qsTr("Три кроки по черзі (комп'ютер і PS5 в одній мережі).")
                        }
                        ApRow {
                            title: qsTr("1. Увійти в PSN потрібним акаунтом")
                            subtitle: sharedPage.localPsn ? qsTr("у цій програмі увійдено як: %1").arg(sharedPage.localPsn) : qsTr("у цій програмі вхід у PSN ще не виконано")
                            ApButton {
                                small: true; ghost: true
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
                                text: qsTr("8 цифр")
                                onClicked: { home.reopenShared = true; root.showRegistDialog("255.255.255.255", true); }
                            }
                        }
                        ApButton {
                            Layout.topMargin: 16
                            Layout.fillWidth: true
                            wrap: true
                            text: sharedPage.localPsn && sharedPage.localPsn !== qsTr("акаунт PSN")
                                ? qsTr("3. Роздавати клієнтам «%1»").arg(sharedPage.localPsn) : qsTr("3. Передати PS5 на сервер")
                            enabled: sharedPage.registState === 1 && sharedPage.localPsn !== ""
                            onClicked: { home.cloud.uploadConsole(); home.view = "home"; }
                        }
                    }
                }
            }

            // ═════════ СВОЇ PSN КЛІЄНТІВ (адмін) ═════════
            TabPage {
                id: clientsPage
                property string result: ""
                property bool resultOk: true
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
                    ColumnLayout {
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
                    ColumnLayout {
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

        // ── сповіщення ──
        Rectangle {
            id: toast
            property string message: ""
            z: 600
            function show(t) { message = t; toastTimer.restart(); }
            visible: message !== ""
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 24 }
            width: Math.min(zoom.width - 40, 560, toastText.implicitWidth + 34)
            height: toastText.implicitHeight + 20
            radius: 4
            color: "#f2221d2e"
            border.color: "#66ffffff"
            Text {
                id: toastText
                anchors.centerIn: parent
                width: Math.min(zoom.width - 74, 526, implicitWidth)
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: toast.message
                color: ap.ink
                font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 14
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

    // ── «У що граєш?» перед грою: розкладка клавіш під гру (на все вікно) ──
    AnyPlayGamePicker {
        id: gamePicker
        anchors.fill: parent
        z: 700
        onPicked: (layoutId) => home.pickedGame(layoutId)
        onDismissed: home.pickerDismissed()
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

    // ── маленька кнопка-посилання у верхній смузі («Вийти», хрестик) ──
    component LinkButton: Rectangle {
        id: lb
        property string text
        signal clicked()
        implicitWidth: lbText.implicitWidth + 22
        implicitHeight: lbText.implicitHeight + 10
        radius: ap.radius
        color: "#0affffff"
        border.color: lbMouse.containsMouse ? ap.ink : ap.edge
        Text {
            id: lbText
            anchors.centerIn: parent
            text: lb.text
            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
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
            radius: 4
            color: ap.dialog
            border.color: ap.edge
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
