// AnyPlay: головний екран програми.
// Клієнт: увійти, грати в час броні, якість, клавіші, свій акаунт PSN.
// Адмін: хто грає зараз, завершити гру, закрити доступ усім, спільний акаунт PSN, CRM.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: home
    property var cloud: Chiaki.cloud
    property int tick: 0
    property bool serviceMode: false     // адмін тимчасово відкрив повний (сервісний) інтерфейс
    readonly property bool isAdmin: cloud.loggedIn && cloud.admin
    readonly property var adm: cloud.adminInfo || ({})
    readonly property var cur: adm.current || null
    readonly property int tileCount: isAdmin ? 6 : 5
    readonly property real tileW: Math.min(172, (width - 60 - 14 * (tileCount - 1)) / tileCount)
    signal openKeys()
    color: "#0b0618"
    focus: visible

    // Фон нічого не пропускає крізь себе: кліки, колесо й наведення не доходять до списку консолей під ним
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        preventStealing: true
        onWheel: (wheel) => wheel.accepted = true
        onPressed: (mouse) => { mouse.accepted = true; home.forceActiveFocus(); }
    }

    // ── кольори бренду (як у міні-апках) ──
    readonly property color cPink: "#ff2e9a"
    readonly property color cOrange: "#ff9a3c"
    readonly property color cSun: "#ffd23f"
    readonly property color cCyan: "#22e4ff"
    readonly property color cViolet: "#7b2cff"
    readonly property color cPanel: "#160d2b"
    readonly property color cDim: "#bfaed8"

    Timer { interval: 1000; running: home.visible; repeat: true; onTriggered: home.tick++ }
    Timer { interval: 15000; running: home.visible && home.isAdmin; repeat: true; triggeredOnStart: true; onTriggered: home.cloud.refreshAdmin() }

    function nowTs() { tick; return Math.floor(Date.now() / 1000) + cloud.clockSkew; }
    function dur(s) {
        s = Math.max(0, s);
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
        if (d > 0) return qsTr("%1 д %2 год").arg(d).arg(h);
        return (h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0");
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
    function play() {
        const i = consoleIndex();
        if (i < 0) { toast.show(qsTr("Шукаємо приставку… зачекай кілька секунд")); Chiaki.refreshPsnToken(); return; }
        const h = Chiaki.hosts[i];
        if (h.discovered) Chiaki.connectToHost(i, h.name); else Chiaki.connectToHost(i);
    }
    function qualityName() {
        const r = Chiaki.settings.resolutionRemotePS5, f = Chiaki.settings.fpsRemotePS5;
        if (r <= 2) return qsTr("Економна");
        if (r >= 4) return qsTr("Максимальна");
        return f >= 60 ? qsTr("Оптимальна") : qsTr("Економна");
    }
    function setQuality(res, fps) {
        const br = res >= 4 ? 25000 : 0;   // «Максимальна» — підвищений бітрейт, щоб картинка була чіткішою
        Chiaki.settings.resolutionRemotePS5 = res; Chiaki.settings.fpsRemotePS5 = fps; Chiaki.settings.bitrateRemotePS5 = br;
        Chiaki.settings.resolutionLocalPS5 = res;  Chiaki.settings.fpsLocalPS5 = fps;  Chiaki.settings.bitrateLocalPS5 = br;
    }

    readonly property bool popupOpen: qualityPopup.opened || psnPopup.opened || extendPopup.opened || clientsPopup.opened || sharedPopup.opened || bookPopup.opened
    Keys.onReturnPressed: if (!popupOpen) primary.clicked()
    Keys.onEnterPressed: if (!popupOpen) primary.clicked()
    Keys.onEscapePressed: {
        if (popupOpen)
            closePopups();
        else
            root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit());
    }

    // ── фон: нічне небо → неонове сонце, як у міні-апці ──
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#2b0a4f" }
            GradientStop { position: 0.55; color: "#1a0b33" }
            GradientStop { position: 1.0; color: "#0b0618" }
        }
    }
    Item {
        id: sun
        width: Math.min(home.width, home.height) * 0.62; height: width
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: -height * 0.6
        opacity: 0.38
        Rectangle {
            anchors.fill: parent; radius: width / 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: home.cSun }
                GradientStop { position: 0.55; color: "#ff7a3c" }
                GradientStop { position: 1.0; color: home.cPink }
            }
        }
        Repeater {   // смуги на сонці
            model: 9
            Rectangle {
                width: sun.width; height: 4 + index * 1.6
                y: sun.height * 0.42 + index * sun.height * 0.065
                color: "#0b0618"
            }
        }
    }
    // ── верхня смуга ──
    RowLayout {
        id: topBar
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 28 }
        spacing: 14
        Image {
            source: "qrc:/icons/anyplay-icon.png"
            Layout.preferredWidth: 56; Layout.preferredHeight: 56
            sourceSize: Qt.size(112, 112)
        }
        ColumnLayout {
            spacing: 0
            Item {
                implicitWidth: brand.implicitWidth; implicitHeight: brand.implicitHeight
                Label {   // неонове світіння
                    x: 2; y: 2; text: brand.text; font: brand.font; color: home.cPink; opacity: 0.7
                }
                Label {
                    id: brand
                    text: "ANYPLAY"
                    font.pixelSize: 34; font.bold: true; font.letterSpacing: 3
                    color: "white"
                }
            }
            Label {
                text: qsTr("ОРЕНДА PS5: GTA ТА ІНШІ ІГРИ")
                font.pixelSize: 12; font.bold: true; font.letterSpacing: 3
                color: "#ffe7f6"; opacity: 0.85
            }
        }
        Item { Layout.fillWidth: true }
        Label {
            visible: home.cloud.loggedIn && home.cloud.userName !== ""
            text: "👤 " + home.cloud.userName
            color: home.cDim; font.pixelSize: 15; font.bold: true
        }
        HomeButton {
            visible: home.cloud.loggedIn
            text: qsTr("Вийти")
            flat: true
            onClicked: root.showConfirmDialog(qsTr("Вийти з акаунта"), qsTr("Вийти з AnyPlay на цьому комп'ютері?"), () => home.cloud.logout())
        }
        HomeButton {
            text: "✕"
            flat: true
            onClicked: root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit())
        }
    }

    // ── головна картка ──
    Rectangle {
        id: card
        visible: !home.isAdmin
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -20
        width: Math.min(parent.width - 80, 720)
        height: cardCol.implicitHeight + 64
        radius: 28
        color: "#cc160d2b"
        border.color: home.cloud.state === "play" ? home.cPink : "#33ffffff"
        border.width: home.cloud.state === "play" ? 2 : 1

        ColumnLayout {
            id: cardCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 36 }
            spacing: 14

            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 15; font.bold: true; font.letterSpacing: 2
                color: home.cCyan
                text: {
                    switch (home.cloud.state) {
                    case "play": return qsTr("ЧАС ТВОЄЇ ГРИ");
                    case "login": return qsTr("ЛАСКАВО ПРОСИМО");
                    case "pairing": return qsTr("ПІДТВЕРДЖЕННЯ ВХОДУ");
                    case "offline": return qsTr("НЕМАЄ ЗВ'ЯЗКУ");
                    case "no_console": return qsTr("ПРИСТАВКА НЕДОСТУПНА");
                    case "update": return qsTr("ВИЙШЛА НОВА ВЕРСІЯ");
                    default: return home.cloud.nextStart ? qsTr("ТВОЯ НАСТУПНА ГРА") : qsTr("БРОНЮВАННЯ");
                    }
                }
            }
            Label {   // великий таймер або головний напис
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.bold: true
                font.pixelSize: (home.cloud.state === "play" || (home.cloud.state === "wait" && home.cloud.nextStart)) ? 72 : 34
                color: home.cloud.state === "play" ? home.cSun : "white"
                text: {
                    const c = home.cloud;
                    switch (c.state) {
                    case "play": return c.admin ? qsTr("Режим адміна") : home.dur(c.endTs - home.nowTs());
                    case "login": return qsTr("Увійди, щоб грати");
                    case "pairing": return qsTr("Натисни «Start» у боті");
                    case "offline": return qsTr("Перевір інтернет");
                    case "no_console": return qsTr("Напиши нам у бот");
                    case "update": return qsTr("Онови програму");
                    default:
                        if (!c.nextStart) return qsTr("Немає оплачених броней");
                        const left = c.nextStart - home.nowTs();
                        return left > 0 ? home.dur(left) : qsTr("Вже скоро!");
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.pixelSize: 16
                color: home.cDim
                text: {
                    const c = home.cloud;
                    switch (c.state) {
                    case "play": return qsTr("Лишилось до кінця. Гра до %1, потім завершиться сама.").arg(c.formatTime(c.endTs))
                        + (!c.admin && c.playPsn ? "\n" + (c.playOwn ? qsTr("Акаунт PSN: %1 (твій)") : qsTr("Акаунт PSN: %1 (спільний)")).arg(c.playPsn) : "");
                    case "login": return qsTr("Вхід через Telegram — без паролів. Приставка відкриється сама в час твоєї оплаченої броні.");
                    case "pairing": return qsTr("Відкрився бот @play_any_bot. Натисни там «Start» і повертайся сюди.");
                    case "offline": return qsTr("Спробуємо знову за хвилину.");
                    case "no_console": return qsTr("Приставка тимчасово недоступна — кнопка «🆘 Допомога» в боті.");
                    case "update": return qsTr("Ця версія програми застаріла, і грати з неї вже не можна. Завантаж нову в боті: кнопка «💻 Програма». Встановлюється поверх старої, вхід і броні зберігаються.");
                    default: return c.nextStart
                        ? qsTr("До початку гри (%1–%2). Доступ відкриється автоматично, програму можна не закривати.").arg(c.formatTime(c.nextStart)).arg(c.formatTime(c.nextEnd))
                        : qsTr("Обери час і оплати прямо тут — кнопка нижче.");
                    }
                }
            }
            Item { Layout.preferredHeight: 6 }
            HomeButton {
                id: primary
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(card.width - 72, 440)
                Layout.preferredHeight: 68
                primary: true
                font.pixelSize: 22
                text: {
                    switch (home.cloud.state) {
                    case "play": return home.consoleIndex() >= 0 ? qsTr("▶  ГРАТИ") : qsTr("Підключаємо приставку…");
                    case "login": return qsTr("Увійти через Telegram");
                    case "pairing": return qsTr("Скасувати");
                    case "offline": return qsTr("Спробувати ще");
                    case "no_console": return qsTr("Відкрити бота");
                    case "update": return qsTr("Завантажити нову версію");
                    default: return qsTr("Забронювати час");
                    }
                }
                onClicked: {
                    switch (home.cloud.state) {
                    case "play": home.play(); break;
                    case "login": home.cloud.login(); break;
                    case "pairing": home.cloud.cancelLogin(); break;
                    case "offline": home.cloud.refresh(); break;
                    case "no_console": home.cloud.openBot(); break;
                    case "update": home.cloud.openBot(); break;
                    default: bookPopup.open();
                    }
                }
            }
        }
    }

    // ── картка адміна: хто грає, завершити гру, закрити доступ ──
    Rectangle {
        id: adminCard
        visible: home.isAdmin
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -20
        width: Math.min(parent.width - 80, 760)
        height: adminCol.implicitHeight + 56
        radius: 28
        color: "#cc160d2b"
        border.color: home.adm.closed ? "#ff4d6d" : (home.cur ? home.cPink : "#33ffffff")
        border.width: home.adm.closed || home.cur ? 2 : 1

        ColumnLayout {
            id: adminCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 32 }
            spacing: 10

            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 15; font.bold: true; font.letterSpacing: 2
                color: home.adm.closed ? "#ff4d6d" : home.cCyan
                text: home.adm.closed ? qsTr("🔒 ДОСТУП КЛІЄНТАМ ЗАКРИТО") : qsTr("ПАНЕЛЬ АДМІНА")
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.pixelSize: home.cur ? 40 : 30; font.bold: true
                color: "white"
                text: home.cur ? home.cur.user : qsTr("Зараз ніхто не грає")
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.pixelSize: 16; color: home.cDim
                text: {
                    const c = home.cur;
                    if (c)
                        return (c.live ? qsTr("🟢 у грі") : qsTr("⚪ ще не підключився")) + ", "
                            + qsTr("%1–%2, лишилось %3").arg(home.cloud.formatTime(c.start)).arg(home.cloud.formatTime(c.end)).arg(home.dur(c.end - home.nowTs()));
                    const n = home.adm.next || [];
                    return n.length ? qsTr("Наступна бронь: %1, %2–%3").arg(n[0].user).arg(home.cloud.formatTime(n[0].start)).arg(home.cloud.formatTime(n[0].end))
                                    : qsTr("Найближчих оплачених броней немає.");
                }
            }
            Repeater {   // ще дві наступні броні
                model: home.cur ? (home.adm.next || []).slice(0, 2) : (home.adm.next || []).slice(1, 3)
                Label {
                    required property var modelData
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14; color: home.cDim; opacity: 0.8
                    text: qsTr("далі: %1, %2–%3").arg(modelData.user).arg(home.cloud.formatTime(modelData.start)).arg(home.cloud.formatTime(modelData.end))
                }
            }
            Item { Layout.preferredHeight: 6 }
            HomeButton {   // адмін може зайти на приставку будь-коли
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 60
                Layout.preferredWidth: Math.min(adminCol.width, 460)
                primary: true
                font.pixelSize: 19
                text: home.consoleIndex() >= 0 ? qsTr("🎮 Підключитись до приставки") : qsTr("Шукаю PS5…")
                onClicked: {
                    const c = home.cur;
                    if (c)
                        root.showConfirmDialog(qsTr("Підключитись"), c.live
                            ? qsTr("Зараз на приставці грає %1. Якщо підключишся — його трансляція перерветься. Підключитись?").arg(c.user)
                            : qsTr("Зараз час броні %1 (він ще не підключився). Поки ти на приставці, клієнт не зможе зайти. Підключитись?").arg(c.user),
                            () => home.play());
                    else
                        home.play();
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 12
                HomeButton {
                    visible: !!home.cur
                    Layout.preferredHeight: 52
                    font.pixelSize: 16
                    text: qsTr("⛔ Завершити гру клієнта")
                    onClicked: {
                        const c = home.cur;
                        if (c)
                            root.showConfirmDialog(qsTr("Завершити гру"), qsTr("Завершити гру %1 просто зараз? Приставка відключиться, клієнт отримає повідомлення в боті.").arg(c.user),
                                                   () => home.cloud.adminKick(c.id));
                    }
                }
                HomeButton {
                    Layout.preferredHeight: 52
                    font.pixelSize: 16
                    text: home.adm.closed ? qsTr("🔓 Відкрити доступ") : qsTr("🔒 Закрити доступ усім")
                    onClicked: {
                        if (home.adm.closed)
                            home.cloud.adminSetClosed(false);
                        else
                            root.showConfirmDialog(qsTr("Закрити доступ"), qsTr("Тимчасово закрити доступ усім клієнтам? Хто грає — відключиться, бот показуватиме «технічні роботи», поки не відкриєш знову."),
                                                   () => home.cloud.adminSetClosed(true));
                    }
                }
            }
        }
    }

    // ── нижня панель: якість, клавіші, свій PSN, бронювання ──
    RowLayout {
        id: tiles
        anchors { horizontalCenter: parent.horizontalCenter; top: home.isAdmin ? adminCard.bottom : card.bottom; topMargin: 22 }
        spacing: 14
        HomeTile {
            icon: "⚙"; title: qsTr("Якість"); subtitle: home.qualityName()
            onClicked: qualityPopup.open()
        }
        HomeTile {
            icon: "⌨"; title: qsTr("Клавіші"); subtitle: qsTr("керування")
            onClicked: home.openKeys()
        }
        HomeTile {
            visible: home.isAdmin
            icon: "👤"; title: qsTr("Спільний PSN")
            subtitle: home.adm.console ? (home.adm.console.psn_name || qsTr("акаунт на %1").arg(home.adm.console.label || "PS5")) : qsTr("⚠ не передано")
            onClicked: sharedPopup.open()
        }
        HomeTile {
            visible: home.isAdmin
            icon: "🎮"; title: qsTr("Свої PSN")
            subtitle: (home.adm.psnClients || []).length ? qsTr("чекають: %1").arg(home.adm.psnClients.length) : qsTr("немає заявок")
            onClicked: clientsPopup.open()
        }
        HomeTile {
            visible: home.isAdmin
            icon: "📊"; title: qsTr("CRM"); subtitle: qsTr("броні й клієнти")
            onClicked: { home.cloud.openBot(); toast.show(qsTr("У боті натисни кнопку «📊 CRM» внизу зліва")); }
        }
        HomeTile {
            visible: home.isAdmin
            icon: "🔧"; title: qsTr("Сервіс"); subtitle: qsTr("усі налаштування")
            onClicked: home.serviceMode = true
        }
        HomeTile {
            visible: home.cloud.loggedIn && !home.isAdmin
            icon: "🎮"; title: qsTr("Мій PSN")
            subtitle: !home.cloud.myPsn ? qsTr("спільний акаунт") : (home.cloud.myPsnStatus === "ready" ? (home.cloud.myPsn.indexOf("PSN-") === 0 ? qsTr("свій акаунт") : home.cloud.myPsn) + " ✅" : qsTr("ще підключається"))
            onClicked: psnPopup.open()
        }
        HomeTile {
            visible: home.cloud.loggedIn && !home.isAdmin && home.cloud.state === "play"
            icon: "⏱"; title: qsTr("Продовжити"); subtitle: qsTr("+1, +2, +3 год")
            onClicked: extendPopup.open()
        }
        HomeTile {
            visible: home.cloud.loggedIn && !home.isAdmin
            icon: "📅"; title: qsTr("Бронювання"); subtitle: qsTr("час і оплата")
            onClicked: bookPopup.open()
        }
    }

    // ── сповіщення ──
    Rectangle {
        id: toast
        property string message: ""
        z: 600
        function show(t) { message = t; toastTimer.restart(); }
        visible: message !== ""
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
        width: Math.min(home.width - 80, toastText.implicitWidth + 48)
        height: toastText.implicitHeight + 24
        radius: 16
        color: "#e6000000"
        border.color: home.cPink
        Label {
            id: toastText
            anchors.centerIn: parent
            width: Math.min(home.width - 128, implicitWidth)
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: toast.message; color: "white"; font.pixelSize: 16; font.bold: true
        }
        Timer { id: toastTimer; interval: 8000; onTriggered: toast.message = "" }
        Connections {
            target: Chiaki.cloud
            function onMessage(text) { toast.show(text); }
        }
    }

    // ── якість: три зрозумілі варіанти ──
    HomePopup {
        id: qualityPopup
        closeOnOutside: true
        maxW: 640
        contentItem: ColumnLayout {
            spacing: 12
            Label { text: qsTr("Якість картинки"); font.pixelSize: 24; font.bold: true; color: "white" }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; color: home.cDim; font.pixelSize: 14
                text: qsTr("Якщо картинка гальмує чи сиплеться, обери нижчу якість. Під час гри її можна змінити в меню гри (кнопка «Якість»).")
            }
            Repeater {
                model: [
                    { name: qsTr("Економна"), info: qsTr("540p, 30 кадр/с — для слабкого чи мобільного інтернету"), res: 2, fps: 30 },
                    { name: qsTr("Оптимальна"), info: qsTr("720p, 60 кадр/с — рекомендовано (від 15 Мбіт/с)"), res: 3, fps: 60 },
                    { name: qsTr("Максимальна"), info: qsTr("1080p, 60 кадр/с, найчіткіша картинка — швидкий інтернет (від 40 Мбіт/с, краще кабель)"), res: 4, fps: 60 }
                ]
                delegate: Rectangle {
                    id: qItem
                    required property var modelData
                    readonly property bool on: home.qualityName() === modelData.name
                    Layout.fillWidth: true
                    implicitHeight: qRow.implicitHeight + 28
                    radius: 16
                    color: on ? "#3a1a6e" : "#1f1240"
                    border.color: on ? home.cCyan : "#22ffffff"
                    border.width: on ? 2 : 1
                    RowLayout {
                        id: qRow
                        anchors { fill: parent; margins: 14 }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: qItem.modelData.name; font.pixelSize: 18; font.bold: true; color: "white" }
                            Label { text: qItem.modelData.info; font.pixelSize: 13; color: home.cDim; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        }
                        Label { text: qItem.on ? "✓" : ""; font.pixelSize: 22; font.bold: true; color: home.cCyan }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { home.setQuality(qItem.modelData.res, qItem.modelData.fps); qualityPopup.close(); toast.show(qsTr("Якість: %1").arg(qItem.modelData.name)); }
                    }
                }
            }
        }
    }

    // ── свій акаунт PSN: навіщо + 4 кроки ──
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
                home.play();
            } else if (++tries > 25) {
                home.cloud.reconnectOnce = false;
                toast.show(qsTr("Не вдалося підключитись самому. Натисни «Грати»."));
            }
        }
    }
    function resume() {
        if (reopenPsn) { reopenPsn = false; psnPopup.open(); }
        if (reopenShared) { reopenShared = false; sharedPopup.open(); }
    }
    function startPsnLogin(create) {
        if (!home.cloud.beginMyPsnLogin())
            return;
        home.reopenPsn = true;
        psnPopup.close();
        root.showAnyPlayPsnLogin(create);
    }
    function closePopups() { qualityPopup.close(); psnPopup.close(); extendPopup.close(); clientsPopup.close(); sharedPopup.close(); bookPopup.close(); }
    onVisibleChanged: if (!visible) closePopups()
    Connections {
        target: Chiaki.cloud
        function onChanged() {
            const entry = home.cloud.myPsnQr || home.cloud.myPsnCode !== "" || home.cloud.myPsnLink !== "";
            if (entry && !home.qrAutoShown && home.visible && !home.isAdmin) {
                home.qrAutoShown = true;
                psnPopup.open();
            }
            if (!entry)
                home.qrAutoShown = false;
        }
    }
    HomePopup {
        id: psnPopup
        maxW: 720
        // поки чекаємо QR-код або адміна — питаємо сервер кожні 4 секунди, а не раз на хвилину
        Timer {
            interval: 4000; repeat: true
            running: psnPopup.opened && (psnPopup.step === 3 || psnPopup.step === 4)
            onTriggered: home.cloud.refresh()
        }
        readonly property string st: home.cloud.myPsnStatus
        readonly property bool hasEntry: home.cloud.myPsnQr || home.cloud.myPsnCode !== "" || home.cloud.myPsnLink !== ""
        // 2 — вхід через Sony, 3 — QR на приставці, 4 — адмін завершує, 5 — готово (нік вписувати не треба)
        readonly property int step: !home.cloud.myPsnLinked ? 2 : (st === "ready" ? 5 : (st === "signed_in" ? 4 : 3))
        contentItem: Item {
            implicitHeight: psnCol.implicitHeight
            ColumnLayout {
                id: psnCol
                width: parent.width
                spacing: 12
                Label { text: qsTr("🎮 Мій акаунт PSN"); font.pixelSize: 24; font.bold: true; color: "white" }

                // навіщо свій акаунт
                Rectangle {
                    Layout.fillWidth: true
                    visible: psnPopup.step <= 2
                    radius: 16; color: "#1f1240"
                    implicitHeight: whyCol.implicitHeight + 24
                    ColumnLayout {
                        id: whyCol
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                        spacing: 4
                        Label { text: qsTr("Навіщо грати на своєму акаунті?"); font.bold: true; font.pixelSize: 16; color: home.cSun }
                        Repeater {
                            model: [
                                qsTr("💾 Твій прогрес — лише твій: сюжет, персонаж GTA Online, гроші, авто й нерухомість."),
                                qsTr("🔒 Ніхто з інших орендарів не зайде у твого персонажа і не зіпсує збереження."),
                                qsTr("🔁 Наступна оренда — продовжуєш з того самого місця, нічого не налаштовуючи."),
                                qsTr("👥 Твої друзі, трофеї й гра з друзями онлайн."),
                                qsTr("🆓 Акаунт PSN безкоштовний, а гра вже є на нашій приставці — купувати нічого не треба.")
                            ]
                            Label { required property string modelData; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: modelData; color: "white"; font.pixelSize: 14 }
                        }
                        Label {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13; color: home.cDim
                            text: qsTr("На спільному акаунті AnyPlay грають усі клієнти — прогрес там спільний і може змінитися.")
                        }
                    }
                }

                // крок 2: вхід у PSN через сторінку Sony
                PsnStep {
                    num: 1; done: psnPopup.step > 2; active: psnPopup.step === 2
                    title: psnPopup.step > 2 && home.cloud.myPsn && home.cloud.myPsn.indexOf("PSN-") !== 0
                           ? qsTr("Вхід у PSN виконано: %1").arg(home.cloud.myPsn)
                           : qsTr("Увійди в PSN — на офіційній сторінці Sony")
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; visible: psnPopup.step === 2
                    color: home.cDim; font.pixelSize: 14
                    text: qsTr("🔒 Пароль вводиш лише на сайті Sony — ні ми, ні програма його не бачимо. Це потрібно, щоб приставка відкривалась саме під твоїм акаунтом.")
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: psnPopup.step === 2
                    spacing: 12
                    HomeButton {
                        Layout.fillWidth: true
                        primary: true
                        text: qsTr("У мене є акаунт — увійти")
                        onClicked: home.startPsnLogin(false)
                    }
                    HomeButton {
                        Layout.fillWidth: true
                        text: qsTr("Створити акаунт PSN")
                        onClicked: home.startPsnLogin(true)
                    }
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; visible: psnPopup.step === 2
                    color: home.cDim; font.pixelSize: 13
                    text: qsTr("Вхід і реєстрація відкриваються на сайті Sony у твоєму браузері — програма покаже, що робити далі. Акаунт PSN безкоштовний.")
                }

                // крок 3: вхід на приставці — посилання, код цифрами або QR
                PsnStep {
                    num: 2; done: psnPopup.step > 3; active: psnPopup.step === 3
                    title: qsTr("Підтверди вхід у свій акаунт на приставці")
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    visible: psnPopup.step === 3 && !psnPopup.hasEntry
                    color: home.cDim; font.pixelSize: 14
                    text: qsTr("⏳ Адміністратор готує приставку. Посилання і QR-код для входу з'являться тут за кілька хвилин (і прийдуть у Telegram). Вікно можна закрити: щойно вони будуть, воно відкриється саме.")
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    visible: psnPopup.step === 3 && psnPopup.hasEntry
                    color: "white"; font.pixelSize: 14
                    text: qsTr("Приставка чекає, поки ти підтвердиш вхід у свій акаунт PSN. Пароль вводиш лише на сайті Sony. Застосунок PlayStation для цього не потрібен. Код діє кілька хвилин.")
                }
                // спосіб 1: відкрити сторінку входу просто на цьому комп'ютері
                HomeButton {
                    Layout.fillWidth: true
                    visible: psnPopup.step === 3 && home.cloud.myPsnLink !== ""
                    primary: true
                    text: qsTr("🌐 Відкрити сторінку входу на цьому комп'ютері")
                    onClicked: home.cloud.openMyPsnLink()
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    visible: psnPopup.step === 3 && home.cloud.myPsnLink !== ""
                    color: home.cDim; font.pixelSize: 13
                    text: qsTr("Відкриється сайт Sony у твоєму браузері. Увійди у свій акаунт PSN і підтверди вхід на приставці. Телефон не потрібен.")
                }
                // спосіб 2: код цифрами
                Rectangle {
                    Layout.fillWidth: true
                    visible: psnPopup.step === 3 && home.cloud.myPsnCode !== ""
                    radius: 16; color: "#1f1240"; border.color: "#33ffffff"
                    implicitHeight: codeRow.implicitHeight + 24
                    RowLayout {
                        id: codeRow
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                        spacing: 12
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: qsTr("КОД ДЛЯ ВХОДУ"); color: home.cCyan; font.pixelSize: 12; font.bold: true; font.letterSpacing: 2 }
                            Label { text: home.cloud.myPsnCode; color: "white"; font.pixelSize: 30; font.bold: true; font.letterSpacing: 3 }
                            Label {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                color: home.cDim; font.pixelSize: 13
                                text: home.cloud.myPsnLink !== ""
                                    ? qsTr("Якщо сайт Sony попросить код, введи цей.")
                                    : qsTr("Це код з екрана приставки. Сайт Sony може попросити його під час входу.")
                            }
                        }
                        HomeButton { text: qsTr("Скопіювати"); onClicked: home.cloud.copyText(home.cloud.myPsnCode) }
                    }
                }
                // спосіб 3: QR-код звичайною камерою телефона
                Image {
                    id: psnQr
                    property bool big: false
                    readonly property real side: big ? Math.min(psnCol.width, 620) : 320
                    Layout.alignment: Qt.AlignHCenter
                    visible: psnPopup.step === 3 && home.cloud.myPsnQr
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
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    visible: psnQr.visible
                    color: home.cDim; font.pixelSize: 12
                    text: psnQr.big ? qsTr("Натисни на код, щоб зменшити") : qsTr("Натисни на код, щоб збільшити")
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    visible: psnPopup.step === 3 && home.cloud.myPsnQr
                    color: "white"; font.pixelSize: 14
                    text: home.cloud.myPsnLink !== ""
                        ? qsTr("Або з телефона: відкрий звичайну камеру, наведи її на цей QR-код і натисни на посилання, яке з'явиться.")
                        : qsTr("Відкрий звичайну камеру телефона, наведи її на цей QR-код і натисни на посилання, яке з'явиться. Увійди у свій акаунт PSN і підтверди вхід на приставці.")
                }
                HomeButton {
                    visible: psnPopup.step === 3 && psnPopup.hasEntry
                    primary: true
                    text: home.cloud.myPsnQr && home.cloud.myPsnLink === "" && home.cloud.myPsnCode === ""
                        ? qsTr("✅ QR-код відскановано, підключення приставки підтвердив")
                        : qsTr("✅ Підключення приставки до акаунта підтвердив")
                    onClicked: home.cloud.myPsnDone()
                }

                // крок 4: адмін завершує
                PsnStep {
                    num: 3; done: psnPopup.step > 4; active: psnPopup.step === 4
                    title: psnPopup.step === 5 ? qsTr("Готово! Ти граєш на своєму акаунті ✅") : qsTr("Адміністратор завершує підключення (1–2 хв)")
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; visible: psnPopup.step === 5
                    color: "#3dff9a"; font.pixelSize: 15
                    text: qsTr("Твій акаунт збережено: наступного разу просто бронюй і грай — приставка сама відкриється під ним.")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    HomeButton {
                        visible: home.cloud.myPsn !== ""
                        flat: true
                        text: qsTr("Грати на спільному")
                        onClicked: root.showConfirmDialog(qsTr("Спільний акаунт"), qsTr("Перейти на спільний акаунт AnyPlay? Свій акаунт доведеться підключати заново."),
                                                          () => { home.cloud.setMyPsn(""); psnPopup.close(); })
                    }
                    Item { Layout.fillWidth: true }
                    HomeButton { text: qsTr("Закрити"); onClicked: psnPopup.close() }
                }
            }
        }
    }

    // ── продовження гри ──
    HomePopup {
        id: extendPopup
        maxW: 660
        contentItem: ColumnLayout {
            spacing: 14
            ExtendPanel { Layout.fillWidth: true; visible: extendPopup.opened }
            RowLayout {
                Layout.fillWidth: true
                HomeButton { text: qsTr("📅 Забронювати ще"); onClicked: { extendPopup.close(); bookPopup.open(); } }
                Item { Layout.fillWidth: true }
                HomeButton { text: qsTr("Закрити"); flat: true; onClicked: extendPopup.close() }
            }
        }
    }

    // ── бронювання й оплата прямо в програмі ──
    HomePopup {
        id: bookPopup
        maxW: 760
        cardHeight: bookFlick.contentHeight + 56
        contentItem: Flickable {
            id: bookFlick
            clip: true
            contentHeight: bookPanel.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: bookFlick.contentHeight > bookFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
            BookPanel { id: bookPanel; width: bookFlick.width - 12; visible: bookPopup.opened }
        }
    }
    // після оплати броні оновлюємо головний екран (з'являється таймер до гри)
    Connections {
        target: Chiaki.cloud
        function onBookChanged() { if (bookPopup.opened) home.cloud.refresh(); }
    }

    // ── адмін: клієнти зі своїм PSN — прив'язати приставку до їхнього акаунта ──
    HomePopup {
        id: clientsPopup
        maxW: 760
        property string result: ""
        property bool resultOk: true
        onOpenedChanged: if (opened) { result = ""; home.cloud.refreshAdmin(); }
        Connections {
            target: Chiaki.cloud
            function onLinkResult(ok, text) { clientsPopup.result = text; clientsPopup.resultOk = ok; }
        }
        contentItem: Item {
            implicitHeight: clientsCol.implicitHeight
            ColumnLayout {
                id: clientsCol
                width: parent.width
                spacing: 12
                Label { text: qsTr("Клієнти зі своїм PSN"); font.pixelSize: 24; font.bold: true; color: "white" }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: home.cDim; font.pixelSize: 14
                    text: qsTr("1) Бот надішле тобі заявку. Натисни «📷 Надіслати QR клієнту» і сфотографуй екран PS5 з QR-кодом (Перемкнути користувача → Додати користувача → Увійти).\n2) Клієнт підтверджує вхід у свій акаунт.\n3) На PS5 перемкнись на його профіль → Налаштування → Система → Дистанційне відтворення → Прив'язати пристрій. Введи 8 цифр тут або напиши їх боту.\n\nУ тій самій мережі, що й PS5, має бути лише цей комп'ютер. Клієнтові це не потрібно. Код потрібен один раз для кожного акаунта.")
                }
                Label {
                    visible: !(home.adm.psnClients || []).length
                    text: qsTr("Зараз заявок немає.")
                    color: "white"; font.pixelSize: 16
                }
                Repeater {
                    model: home.adm.psnClients || []
                    Rectangle {
                        id: cRow
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 16; color: "#1f1240"; border.color: "#33ffffff"
                        implicitHeight: cCol.implicitHeight + 24
                        ColumnLayout {
                            id: cCol
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                            spacing: 8
                            Label {
                                text: qsTr("%1, PSN: %2").arg(cRow.modelData.user).arg(cRow.modelData.psn)
                                color: "white"; font.bold: true; font.pixelSize: 17
                            }
                            Label {
                                color: home.cDim; font.pixelSize: 14
                                text: {
                                    const m = cRow.modelData;
                                    const acc = m.accountId ? qsTr("увійшов у PSN у програмі ✅") : qsTr("ще не увійшов у PSN у програмі");
                                    const st = { requested: qsTr("Чекає QR-код"), qr_sent: qsTr("Код надіслано, чекаємо входу"),
                                                 signed_in: qsTr("Увійшов на PS5, лишилось прив'язати ⬇") }[m.status] || m.status;
                                    return st + ". " + acc[0].toUpperCase() + acc.slice(1) + ".";
                                }
                            }
                            RowLayout {
                                spacing: 10
                                TextField {
                                    id: pinField
                                    placeholderText: qsTr("8 цифр з PS5")
                                    inputMethodHints: Qt.ImhDigitsOnly
                                    maximumLength: 9
                                    Layout.preferredWidth: 200
                                    font.pixelSize: 18
                                }
                                HomeButton {
                                    primary: true
                                    text: home.cloud.busy ? qsTr("Прив'язую…") : qsTr("🔗 Прив'язати")
                                    enabled: !home.cloud.busy && !!cRow.modelData.accountId && pinField.text.replace(/\D/g, "").length === 8
                                    onClicked: { clientsPopup.result = ""; home.cloud.linkClientConsole(cRow.modelData.userId, cRow.modelData.accountId, pinField.text); }
                                }
                            }
                        }
                    }
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    visible: clientsPopup.result !== ""
                    text: clientsPopup.result
                    color: clientsPopup.resultOk ? "#3dff9a" : "#ff4d6d"; font.pixelSize: 15; font.bold: true
                }
                HomeButton { Layout.alignment: Qt.AlignRight; text: qsTr("Закрити"); onClicked: clientsPopup.close() }
            }
        }
    }

    // ── адмін: спільний акаунт PSN для всіх клієнтів ──
    HomePopup {
        id: sharedPopup
        maxW: 700
        property int rev: 0   // перечитати, що зараз у цій програмі (вхід PSN, прив'язана PS5)
        readonly property var con: home.adm.console || null
        readonly property string localPsn: { rev; return home.cloud.localPsnName(); }
        readonly property string localPs5: { rev; return home.cloud.localConsoleName(); }
        readonly property int registState: { rev; return home.cloud.localRegistState(); }   // 0 немає, 1 під цим акаунтом, 2 під іншим
        onOpenedChanged: if (opened) { rev++; home.cloud.refreshAdmin(); }
        contentItem: ColumnLayout {
            spacing: 10
            Label { text: qsTr("Спільний акаунт PSN"); font.pixelSize: 24; font.bold: true; color: "white" }
            Rectangle {   // який акаунт зараз роздається клієнтам
                Layout.fillWidth: true
                radius: 16
                color: "#1f1240"
                border.color: sharedPopup.con ? "#3dff9a" : "#ff4d6d"
                border.width: 2
                implicitHeight: sharedCur.implicitHeight + 28
                ColumnLayout {
                    id: sharedCur
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 16 }
                    spacing: 4
                    Label {
                        text: qsTr("ЗАРАЗ РОЗДАЄТЬСЯ КЛІЄНТАМ")
                        color: home.cCyan; font.pixelSize: 12; font.bold: true; font.letterSpacing: 2
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            font.pixelSize: 26; font.bold: true
                            color: sharedPopup.con ? "white" : "#ff8fa3"
                            text: sharedPopup.con ? (sharedPopup.con.psn_name || qsTr("акаунт PSN (нік ще не визначено)")) : qsTr("Акаунта немає")
                        }
                        HomeButton {
                            visible: !!sharedPopup.con
                            text: qsTr("🗑 Видалити")
                            onClicked: root.showConfirmDialog(qsTr("Видалити спільний акаунт"),
                                qsTr("Прибрати акаунт «%1» із сервера? Клієнти не зможуть підключатись, доки не передаси новий акаунт. Хто вже грає — дограє до розриву з'єднання.")
                                    .arg(sharedPopup.con ? (sharedPopup.con.psn_name || "PSN") : ""),
                                () => home.cloud.adminDropShared())
                        }
                    }
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap; color: home.cDim; font.pixelSize: 14
                        text: sharedPopup.con
                            ? qsTr("Приставка: %1. Передано на сервер: %2").arg(sharedPopup.con.label || "PS5").arg(home.cloud.formatTime(sharedPopup.con.updated_at))
                            : qsTr("Клієнти поки не можуть грати. Передай акаунт — три кроки нижче.")
                    }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; color: "white"; font.pixelSize: 15
                text: sharedPopup.con ? qsTr("Замінити на інший акаунт — три кроки по черзі (комп'ютер і PS5 в одній мережі). Новий акаунт сам замінить старий:")
                                      : qsTr("Додати акаунт — три кроки по черзі (комп'ютер і PS5 в одній мережі):")
            }
            HomeButton {
                Layout.fillWidth: true
                text: qsTr("1. Увійти в PSN потрібним акаунтом")
                onClicked: { home.reopenShared = true; sharedPopup.close(); root.showAnyPlayPsnLogin(false); }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13
                color: sharedPopup.localPsn ? "#3dff9a" : home.cDim
                text: sharedPopup.localPsn ? qsTr("✓ У цій програмі зараз увійдено як: %1").arg(sharedPopup.localPsn) : qsTr("У цій програмі вхід у PSN ще не виконано.")
            }
            HomeButton {
                Layout.fillWidth: true
                text: qsTr("2. Прив'язати PS5 під цим акаунтом (8-значний код з приставки)")
                onClicked: { home.reopenShared = true; sharedPopup.close(); root.showRegistDialog("255.255.255.255", true); }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13
                color: sharedPopup.registState === 1 ? "#3dff9a" : (sharedPopup.registState === 2 ? "#ffb347" : home.cDim)
                text: (sharedPopup.registState === 1 ? qsTr("✓ Приставку %1 прив'язано під цим акаунтом. ").arg(sharedPopup.localPs5)
                       : sharedPopup.registState === 2 ? qsTr("⚠ Приставку %1 прив'язано під іншим профілем PS5 (або давно, і програма не знає, під яким). Прив'яжи її заново, інакше клієнтів пускатиме в той старий профіль. ").arg(sharedPopup.localPs5)
                       : "")
                    + qsTr("Код: на PS5 перемкнись на профіль цього акаунта → Налаштування → Система → Дистанційне відтворення → Прив'язати пристрій.")
            }
            HomeButton {
                Layout.fillWidth: true
                primary: true
                text: sharedPopup.localPsn && sharedPopup.localPsn !== qsTr("акаунт PSN")
                    ? qsTr("3. Роздавати клієнтам акаунт «%1»").arg(sharedPopup.localPsn) : qsTr("3. Передати PS5 на сервер для клієнтів")
                enabled: sharedPopup.registState === 1 && sharedPopup.localPsn !== ""
                opacity: enabled ? 1 : 0.45
                onClicked: { sharedPopup.close(); home.cloud.uploadConsole(); }
            }
        }
    }

    // ── компоненти в стилі бренду ──
    // Спливне вікно AnyPlay: завжди по центру, висота за вмістом, закривається хрестиком, Esc або кліком повз
    component HomePopup: Item {
        id: hp
        property real maxW: 640
        property real padding: 28
        property real cardHeight: -1        // -1 — за вмістом (із прокруткою, якщо не влазить)
        property bool opened: false
        property bool closeOnOutside: false   // клік повз вікно закриває його (лише для простих вікон)
        property Item contentItem
        function open() { opened = true; }
        function close() { opened = false; }
        anchors.fill: parent
        z: 500
        visible: opened
        enabled: opened
        onContentItemChanged: if (contentItem) contentItem.parent = hpHolder.contentItem
        // затемнення; клік повз вікно закриває лише прості вікна (closeOnOutside)
        Rectangle { anchors.fill: parent; color: "#c8080312" }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onClicked: if (hp.closeOnOutside) hp.close()
            onWheel: (wheel) => { wheel.accepted = true; }
        }
        Rectangle {
            id: hpCard
            readonly property real want: hp.cardHeight >= 0 ? hp.cardHeight
                                        : (hp.contentItem ? hp.contentItem.implicitHeight : 0) + 2 * hp.padding
            anchors.centerIn: parent
            width: Math.max(200, Math.min(hp.width - 60, hp.maxW))
            height: Math.max(80, Math.min(hp.height - 40, want))
            radius: 24
            color: "#160d2b"
            border.color: "#44ffffff"
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
                contentHeight: hp.cardHeight >= 0 ? height : (hp.contentItem ? hp.contentItem.implicitHeight : 0)
                interactive: contentHeight > height + 1
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: hpHolder.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
            }
            Binding { target: hp.contentItem; property: "width"; value: hpHolder.width - (hpHolder.interactive ? 12 : 0); when: !!hp.contentItem }
            Binding { target: hp.contentItem; property: "height"; value: hpHolder.height; when: !!hp.contentItem && hp.cardHeight >= 0 }
            Rectangle {
                anchors { top: parent.top; right: parent.right; margins: 10 }
                width: 34; height: 34; radius: 17
                color: hpClose.containsMouse ? "#33ffffff" : "#18ffffff"
                Label { anchors.centerIn: parent; text: "✕"; color: "white"; font.pixelSize: 15; font.bold: true }
                MouseArea { id: hpClose; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp.close() }
            }
        }
    }

    component HomeButton: Button {
        id: hb
        property bool primary: false
        focusPolicy: Qt.NoFocus
        font.bold: true
        font.pixelSize: 16
        padding: 14
        leftPadding: 24; rightPadding: 24
        contentItem: Label {
            text: hb.text; font: hb.font
            color: hb.enabled ? "white" : "#88ffffff"
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: hb.primary ? 18 : 14
            opacity: hb.enabled ? (hb.down ? 0.8 : 1) : 0.45
            color: hb.flat ? (hb.hovered ? "#22ffffff" : "transparent") : "#26ffffff"
            border.color: hb.flat ? "transparent" : "#22ffffff"
            gradient: hb.primary ? primaryGradient : null
            Gradient {
                id: primaryGradient
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#ff9a3c" }
                GradientStop { position: 0.5; color: "#ff2e9a" }
                GradientStop { position: 1.0; color: "#7b2cff" }
            }
        }
    }

    component PsnStep: RowLayout {
        id: ps
        property int num
        property string title
        property bool done
        property bool active
        Layout.fillWidth: true
        spacing: 10
        Rectangle {
            width: 30; height: 30; radius: 15
            color: ps.done ? "#3dff9a" : (ps.active ? "#ff2e9a" : "#33ffffff")
            Label { anchors.centerIn: parent; text: ps.done ? "✓" : ps.num; color: ps.done ? "#0b0618" : "white"; font.bold: true }
        }
        Label {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: ps.title; font.pixelSize: 16; font.bold: ps.active
            color: ps.active || ps.done ? "white" : "#88ffffff"
        }
    }

    component HomeTile: Rectangle {
        id: tile
        property string icon
        property string title
        property string subtitle
        signal clicked()
        implicitWidth: home.tileW; implicitHeight: 104
        radius: 20
        color: tileMouse.containsMouse ? "#2a1650" : "#cc160d2b"
        border.color: tileMouse.containsMouse ? "#22e4ff" : "#33ffffff"
        ColumnLayout {
            anchors.centerIn: parent
            spacing: 2
            Label { Layout.alignment: Qt.AlignHCenter; text: tile.icon; font.pixelSize: 28; color: "white" }
            Label { Layout.alignment: Qt.AlignHCenter; text: tile.title; font.pixelSize: 16; font.bold: true; color: "white" }
            Label {
                Layout.alignment: Qt.AlignHCenter; Layout.maximumWidth: tile.width - 16
                text: tile.subtitle; font.pixelSize: 12; color: "#bfaed8"; elide: Text.ElideRight
            }
        }
        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.clicked()
        }
    }
}
