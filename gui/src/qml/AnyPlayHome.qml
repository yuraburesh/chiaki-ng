// AnyPlay: головний екран для клієнтів оренди.
// Лише те, що потрібно гравцю: увійти, грати в час броні, якість, клавіші, свій акаунт PSN.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: home
    property var cloud: Chiaki.cloud
    property int tick: 0
    signal openKeys()
    color: "#0b0618"
    focus: visible

    // ── кольори бренду (як у міні-апках) ──
    readonly property color cPink: "#ff2e9a"
    readonly property color cOrange: "#ff9a3c"
    readonly property color cSun: "#ffd23f"
    readonly property color cCyan: "#22e4ff"
    readonly property color cViolet: "#7b2cff"
    readonly property color cPanel: "#160d2b"
    readonly property color cDim: "#bfaed8"

    Timer { interval: 1000; running: home.visible; repeat: true; onTriggered: home.tick++ }

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
        Chiaki.settings.resolutionRemotePS5 = res; Chiaki.settings.fpsRemotePS5 = fps; Chiaki.settings.bitrateRemotePS5 = 0;
        Chiaki.settings.resolutionLocalPS5 = res;  Chiaki.settings.fpsLocalPS5 = fps;  Chiaki.settings.bitrateLocalPS5 = 0;
    }

    Keys.onReturnPressed: primary.clicked()
    Keys.onEnterPressed: primary.clicked()
    Keys.onEscapePressed: root.showConfirmDialog(qsTr("Вийти"), qsTr("Закрити AnyPlay?"), () => Qt.quit())

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
                text: qsTr("ОРЕНДА PS5 · GTA ТА ІНШІ ІГРИ")
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
                    case "play": return qsTr("лишилось · гра до %1, потім завершиться сама").arg(c.formatTime(c.endTs));
                    case "login": return qsTr("Вхід через Telegram — без паролів. Приставка відкриється сама в час твоєї оплаченої броні.");
                    case "pairing": return qsTr("Відкрився бот @play_any_bot. Натисни там «Start» і повертайся сюди.");
                    case "offline": return qsTr("Спробуємо знову за хвилину.");
                    case "no_console": return qsTr("Приставка тимчасово недоступна — кнопка «🆘 Допомога» в боті.");
                    default: return c.nextStart
                        ? qsTr("до початку · %1–%2 · доступ відкриється автоматично, програму можна не закривати").arg(c.formatTime(c.nextStart)).arg(c.formatTime(c.nextEnd))
                        : qsTr("Забронюй час у боті — після оплати повертайся сюди.");
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
                    default: return qsTr("Забронювати час");
                    }
                }
                onClicked: {
                    switch (home.cloud.state) {
                    case "play": home.play(); break;
                    case "login": home.cloud.login(); break;
                    case "pairing": home.cloud.cancelLogin(); break;
                    case "offline": home.cloud.refresh(); break;
                    default: home.cloud.openBot();
                    }
                }
            }
        }
    }

    // ── нижня панель: якість, клавіші, свій PSN, бронювання ──
    RowLayout {
        id: tiles
        anchors { horizontalCenter: parent.horizontalCenter; top: card.bottom; topMargin: 22 }
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
            visible: home.cloud.loggedIn
            icon: "🎮"; title: qsTr("Мій PSN")
            subtitle: home.cloud.myPsn ? home.cloud.myPsn : qsTr("спільний акаунт")
            onClicked: psnPopup.open()
        }
        HomeTile {
            visible: home.cloud.loggedIn && home.cloud.state === "play"
            icon: "📅"; title: qsTr("Бронювання"); subtitle: qsTr("у боті")
            onClicked: home.cloud.openBot()
        }
    }

    // ── сповіщення ──
    Rectangle {
        id: toast
        property string message: ""
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
    Popup {
        id: qualityPopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(home.width - 60, 640)
        modal: true
        padding: 28
        background: Rectangle { radius: 24; color: home.cPanel; border.color: "#44ffffff" }
        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label { text: qsTr("Якість картинки"); font.pixelSize: 24; font.bold: true; color: "white" }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; color: home.cDim; font.pixelSize: 14
                text: qsTr("Якщо картинка гальмує чи сиплеться — обери нижчу якість. Зміни діють з наступного підключення.")
            }
            Repeater {
                model: [
                    { name: qsTr("Економна"), info: qsTr("540p · 30 кадр/с — для слабкого чи мобільного інтернету"), res: 2, fps: 30 },
                    { name: qsTr("Оптимальна"), info: qsTr("720p · 60 кадр/с — рекомендовано (від 15 Мбіт/с)"), res: 3, fps: 60 },
                    { name: qsTr("Максимальна"), info: qsTr("1080p · 60 кадр/с — швидкий інтернет (від 30 Мбіт/с, краще кабель)"), res: 4, fps: 60 }
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

    // ── свій акаунт PSN ──
    Popup {
        id: psnPopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(home.width - 60, 640)
        modal: true
        padding: 28
        background: Rectangle { radius: 24; color: home.cPanel; border.color: "#44ffffff" }
        onOpened: { psnField.text = home.cloud.myPsn; psnField.forceActiveFocus(); }
        ColumnLayout {
            anchors.fill: parent
            spacing: 14
            Label { text: qsTr("Мій акаунт PSN"); font.pixelSize: 24; font.bold: true; color: "white" }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; color: home.cDim; font.pixelSize: 15
                text: home.cloud.myPsn
                    ? (home.cloud.myPsnReady
                        ? qsTr("Твій профіль уже на приставці — після підключення обери його на PS5.")
                        : qsTr("Ми отримали твій акаунт. Щойно додамо його на приставку, бот надішле в Telegram QR-код для входу."))
                    : qsTr("Зараз ти граєш на спільному акаунті AnyPlay — нічого налаштовувати не треба. Хочеш свої збереження, трофеї й друзів? Впиши свій PSN ID (нік у PlayStation Network).")
            }
            TextField {
                id: psnField
                Layout.fillWidth: true
                placeholderText: qsTr("Наприклад, MyNickname_7")
                font.pixelSize: 18
                onAccepted: psnSave.clicked()
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13; color: home.cDim; opacity: 0.85
                text: qsTr("🔒 Пароль від PSN вводити не треба — ніде й нікому. Вхід ти підтверджуєш сам на приставці за QR-кодом.")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                HomeButton {
                    visible: home.cloud.myPsn !== ""
                    text: qsTr("Грати на спільному")
                    onClicked: { home.cloud.setMyPsn(""); psnPopup.close(); }
                }
                Item { Layout.fillWidth: true }
                HomeButton { text: qsTr("Скасувати"); onClicked: psnPopup.close() }
                HomeButton {
                    id: psnSave
                    primary: true
                    text: qsTr("Зберегти")
                    enabled: psnField.text.trim().length >= 3
                    onClicked: { home.cloud.setMyPsn(psnField.text); psnPopup.close(); }
                }
            }
        }
    }

    // ── компоненти в стилі бренду ──
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

    component HomeTile: Rectangle {
        id: tile
        property string icon
        property string title
        property string subtitle
        signal clicked()
        implicitWidth: 172; implicitHeight: 104
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
