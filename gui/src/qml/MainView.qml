import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Pane {
    padding: 0
    id: consolePane
    StackView.onActivated: {
        forceActiveFocus(Qt.TabFocusReason);
        if(!Chiaki.cloud.admin)
            anyplayHome.forceActiveFocus();
        if(Chiaki.cloud.admin && !Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
        {
            root.initialAsk = true;
            if(Chiaki.settings.addSteamShortcutAsk && (typeof Chiaki.createSteamShortcut === "function"))
                root.showRemindDialog(qsTr("Офіційне оформлення Steam + розкладка геймпада"), qsTr("Створити нову гру поза Steam для AnyPlay\nабо оновити наявну офіційним оформленням і розкладкою геймпада?") + "\n\n" + qsTr("(Якщо зараз відмовитеся, зробити це можна пізніше кнопкою або R3 у головному меню.)"), false, () => root.showSteamShortcutDialog(true));
            else if(Chiaki.settings.remotePlayAsk)
            {
                if(!Chiaki.settings.psnRefreshToken || !Chiaki.settings.psnAuthToken || !Chiaki.settings.psnAuthTokenExpiry || !Chiaki.settings.psnAccountId)
                    root.showRemindDialog(qsTr("Remote Play через PSN"), qsTr("Підключитися до PSN?\nЦе дає:\n- автоматичну прив'язку\n- гру не з домашньої мережі без перенаправлення портів") + "\n\n" + qsTr("(Якщо зараз відмовитеся, зробити це можна пізніше в розділі «Конфігурація» налаштувань.)"), true, () => root.showPSNTokenDialog(false));
                else
                    Chiaki.settings.remotePlayAsk = false;
            }
        }
    }
    Keys.onUpPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.decrementCurrentIndex()
            while(!hostsView.currentItem.visible)
                hostsView.decrementCurrentIndex()
        }
    }
    Keys.onDownPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.incrementCurrentIndex()
            while(!hostsView.currentItem.visible)
                 hostsView.incrementCurrentIndex()
        }
    }
    Keys.onMenuPressed: settingsButton.clicked()
    Keys.onReturnPressed: if (hostsView.currentItem) hostsView.currentItem.connectToHost()
    Keys.onYesPressed: if (hostsView.currentItem) hostsView.currentItem.wakeUpHost()
    Keys.onNoPressed: if (hostsView.currentItem) hostsView.currentItem.deleteHost()
    Keys.onEscapePressed: root.showConfirmDialog(qsTr("Вийти"), qsTr("Точно вийти?"), () => Qt.quit())
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            if (hostsView.currentItem) hostsView.currentItem.setConsolePin();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            if (Chiaki.settings.psnAuthToken) Chiaki.refreshPsnToken();
            event.accepted = true;
            break;
        case Qt.Key_F1:
            if (typeof Chiaki.createSteamShortcut === "function") root.showSteamShortcutDialog(false);
            event.accepted = true;
            break;
        case Qt.Key_F2:
            root.showManualHostDialog();
            event.accepted = true;
            break;
        }
    }

    ToolBar {
        id: toolBar
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 80

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 10
                rightMargin: 10
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 100
                flat: true
                text: "×"
                font.pixelSize: 60
                focusPolicy: Qt.NoFocus
                onClicked: Qt.quit()
                Material.roundedScale: Material.SmallScale
            }

            Item { Layout.fillWidth: true }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 350
                flat: true
                text: "Створити ярлик у Steam"
                focusPolicy: Qt.NoFocus
                onClicked: root.showSteamShortcutDialog(false)
                Material.roundedScale: Material.SmallScale
                visible: typeof Chiaki.createSteamShortcut === "function" && !Chiaki.cloud.clientMode
                Image {
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 12
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l3.svg"
                }
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 400
                flat: true
                text: "Оновити консолі PSN"
                icon.source: "qrc:/icons/r1.svg"
                focusPolicy: Qt.NoFocus
                onClicked: Chiaki.refreshPsnToken();
                Material.roundedScale: Material.SmallScale
                visible: Chiaki.settings.psnAuthToken && !Chiaki.cloud.clientMode
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 400
                flat: true
                focusPolicy: Qt.NoFocus
                Material.roundedScale: Material.SmallScale
                visible: !Chiaki.settings.psnAuthToken && !Chiaki.cloud.clientMode
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 300
                flat: true
                text: "Додати консоль вручну"
                focusPolicy: Qt.NoFocus
                onClicked: root.showManualHostDialog()
                Material.roundedScale: Material.SmallScale
                visible: !Chiaki.cloud.clientMode
                Image {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 12
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r3.svg"
                }
            }

            Button {
                id: settingsButton
                Layout.fillHeight: true
                Layout.preferredWidth: 100
                flat: true
                icon.source: "qrc:/icons/settings-20px.svg";
                icon.width: 50
                icon.height: 50
                focusPolicy: Qt.NoFocus
                onClicked: root.showSettingsDialog()
                Material.roundedScale: Material.SmallScale
            }
        }
    }

    ListView {
        id: hostsView
        keyNavigationWraps: true
        anchors {
            top: toolBar.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            bottomMargin: 50
        }
        clip: true
        model: Chiaki.hosts
        onCountChanged: {
            if(!hostsView.currentItem)
                hostsView.incrementCurrentIndex();
            if(!hostsView.currentItem)
                return;
            if(!hostsView.currentItem.visible)
            {
                for(var i = 0; i < hostsView.count; i++)
                {
                    hostsView.incrementCurrentIndex()
                    if(hostsView.currentItem.visible)
                    {
                        break;
                    }
                }
            }
        }
        delegate: ItemDelegate {
            visible: modelData.display
            id: delegate
            width: parent ? parent.width : 0
            height: modelData.display ? 180 : 0
            highlighted: ListView.isCurrentItem
            onClicked: connectToHost()

            function connectToHost() {
                if(modelData.discovered)
                    Chiaki.connectToHost(index, modelData.name);
                else
                    Chiaki.connectToHost(index);
            }

            function wakeUpHost() {
                if(!modelData.discovered && !modelData.duid)
                    Chiaki.wakeUpHost(index);
            }

            function deleteHost() {
                if (modelData.manual)
                    root.showConfirmDialog(qsTr("Видалити консоль"), qsTr("Точно видалити цю консоль?"), () => {Chiaki.deleteHost(index)});
                        
                else if (modelData.discovered && !modelData.registered)
                    root.showConfirmDialog(qsTr("Сховати консоль"), qsTr("Точно сховати цю консоль?") + "\n\n" + qsTr("Показати знову можна в налаштуваннях: «Консолі» → «Приховані консолі»"), () => Chiaki.hideHost(modelData.mac, modelData.name));

            }

            function setConsolePin() {
                root.showConsolePinDialog(index);
            }

            RowLayout {
                anchors {
                    fill: parent
                    leftMargin: 30
                    rightMargin: 10
                    topMargin: 10
                    bottomMargin: 10
                }
                spacing: 50

                Image {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 150
                    fillMode: Image.PreserveAspectFit
                    source: "image://svg/console-ps" + (modelData.ps5 ? "5" : "4") + (modelData.state == "standby" ? "#light_standby" : "#light_on")
                    sourceSize: Qt.size(width, height)
                }

                Label {
                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                    text: {
                        let t = "";
                        if (modelData.name)
                            t += modelData.name + "\n";
                        if (modelData.address)
                            t += qsTr("Адреса: %1").arg(Chiaki.settings.streamerMode ? "hidden" : modelData.address);
                        if (modelData.mac)
                            t += "\n" + qsTr("ID: %1 (%2)").arg(Chiaki.settings.streamerMode ? "hidden" : modelData.mac).arg(modelData.registered ? qsTr("прив'язана") : qsTr("не прив'язана"));
                        if (modelData.duid)
                        {
                            if(modelData.discovered)
                                t += "\n" + qsTr("Доступна автоматична реєстрація");
                            else
                                t += "\n" + qsTr("Віддалене підключення через PSN");
                        } 
                        else
                        {
                            t += "\n";
                            if(modelData.discovered)
                            {
                                if(modelData.manual)
                                    t += qsTr("знайдені + вручну")
                                else
                                    t += qsTr("знайдені");
                            }
                            else
                                t += qsTr("вручну");
                        }
                        return t;
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                    text: {
                        let t = "";
                        if(modelData.duid)
                            return t;
                        t += qsTr("Стан: %1").arg(modelData.state);
                        if(!modelData.discovered)
                            return t;
                        if (modelData.app)
                            t += "\n" + qsTr("Програма: %1").arg(modelData.app);
                        if (modelData.titleId)
                            t += "\n" + qsTr("ID гри: %1").arg(modelData.titleId);
                        return t;
                    }
                }

                Item { Layout.fillWidth: true }

                ColumnLayout {
                    Layout.fillHeight: true
                    spacing: 0

                    Button {
                        Layout.alignment: Qt.AlignCenter
                        text: modelData.manual ? qsTr("Видалити") : qsTr("Сховати")
                        flat: true
                        padding: 20
                        leftPadding: delegate.highlighted ? 50 : undefined
                        focusPolicy: Qt.NoFocus
                        visible: modelData.manual || (modelData.discovered && !modelData.registered)
                        onClicked: delegate.deleteHost()
                        Material.roundedScale: Material.SmallScale

                        Image {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                            }
                            width: 28
                            height: 28
                            sourceSize: Qt.size(width, height)
                            source: root.controllerButton("box")
                            visible: delegate.highlighted
                        }
                    }

                    Button {
                        Layout.alignment: Qt.AlignCenter
                        text: qsTr("Розбудити")
                        flat: true
                        padding: 20
                        leftPadding: delegate.highlighted ? 50 : undefined
                        visible: modelData.registered && !modelData.duid && !modelData.discovered
                        focusPolicy: Qt.NoFocus
                        onClicked: delegate.wakeUpHost()
                        Material.roundedScale: Material.SmallScale

                        Image {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                            }
                            width: 28
                            height: 28
                            sourceSize: Qt.size(width, height)
                            source: root.controllerButton("pyramid")
                            visible: delegate.highlighted
                        }
                    }

                    Button {
                        Layout.alignment: Qt.AlignCenter
                        text: qsTr("Оновити PIN консолі")
                        flat: true
                        padding: 20
                        leftPadding: delegate.highlighted ? 50 : undefined
                        visible: modelData.registered
                        focusPolicy: Qt.NoFocus
                        onClicked: delegate.setConsolePin()
                        Material.roundedScale: Material.SmallScale

                        Image {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                            }
                            width: 28
                            height: 28
                            sourceSize: Qt.size(width, height)
                            source: "qrc:/icons/l1.svg"
                            visible: delegate.highlighted
                        }
                    }
                } 
            } 
        }
    }     

    RoundButton {
        anchors {
            left: parent.left
            bottom: parent.bottom
            margins: 20
        }
        icon.source: "qrc:/icons/discover-" + (checked ? "" : "off-") + "24px.svg"
        icon.width: 50
        icon.height: 50
        padding: 20
        focusPolicy: Qt.NoFocus
        checkable: true
        checked: Chiaki.discoveryEnabled
        onToggled: Chiaki.discoveryEnabled = !Chiaki.discoveryEnabled
        Material.background: Material.accent
    }

    Label {
        anchors {
            right: parent.right
            bottom: parent.bottom
            margins: 20
        }
        text: Qt.application.version
    }

    // ── AnyPlay: головний екран клієнта (адмін бачить повний інтерфейс під ним) ──
    AnyPlayHome {
        id: anyplayHome
        anchors.fill: parent
        z: 100
        visible: !Chiaki.cloud.admin
        onVisibleChanged: if (visible) forceActiveFocus()
        onOpenKeys: root.showSettingsDialogTab(5)
    }

    // ── AnyPlay: вхід через Telegram і час броні ──
    Rectangle {
        id: anyplayPanel
        property var cloud: Chiaki.cloud
        property int tick: 0
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: 24
        }
        width: Math.min(parent.width - 220, 760)
        height: anyplayCol.implicitHeight + 28
        radius: 18
        z: 5
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "#3b1a8f" }
            GradientStop { position: 1.0; color: "#b0247a" }
        }
        border.color: "#ffffff30"

        Timer { interval: 1000; running: true; repeat: true; onTriggered: anyplayPanel.tick++ }

        function left() {
            tick;
            const now = Math.floor(Date.now() / 1000) + cloud.clockSkew;
            const s = Math.max(0, cloud.endTs - now);
            const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
            return (h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0");
        }

        ColumnLayout {
            id: anyplayCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 18 }
            spacing: 8

            RowLayout {
                spacing: 14
                Image {
                    source: "qrc:/icons/anyplay-icon.png"
                    Layout.preferredWidth: 44; Layout.preferredHeight: 44
                    sourceSize: Qt.size(88, 88)
                }
                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Label {
                        Layout.fillWidth: true
                        font.pixelSize: 19; font.bold: true; color: "white"
                        wrapMode: Text.WordWrap
                        text: {
                            const c = anyplayPanel.cloud;
                            switch (c.state) {
                            case "login": return qsTr("Увійди через Telegram, щоб грати");
                            case "pairing": return qsTr("Підтверди вхід у Telegram — натисни «Start» у боті");
                            case "offline": return qsTr("Немає зв'язку із сервером AnyPlay");
                            case "no_console": return qsTr("Приставка ще не підключена до сервера");
                            case "play": return c.admin ? qsTr("Режим адміна · %1").arg(c.userName)
                                                        : qsTr("Можна грати! Лишилось %1").arg(anyplayPanel.left());
                            default: return c.nextStart ? qsTr("Твоя гра: %1–%2").arg(c.formatTime(c.nextStart)).arg(c.formatTime(c.nextEnd))
                                                        : qsTr("Немає оплачених броней");
                            }
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        font.pixelSize: 14; color: "#ffe6f6"
                        wrapMode: Text.WordWrap
                        text: {
                            const c = anyplayPanel.cloud;
                            switch (c.state) {
                            case "login": return qsTr("Приставка відкриється автоматично в час твоєї оплаченої броні.");
                            case "pairing": return qsTr("Відкрився Telegram з ботом @play_any_bot. Після «Start» повернись сюди.");
                            case "play": return c.admin ? qsTr("Тут можна передати свою PS5 і вхід PSN на сервер для клієнтів.")
                                                        : qsTr("Натисни на PS5 у списку вгорі. До %1, потім гра завершиться сама.").arg(c.formatTime(c.endTs));
                            case "no_console": return qsTr("Напиши консультанту в боті — кнопка «🆘 Допомога».");
                            case "offline": return qsTr("Перевір інтернет — спробуємо ще раз за хвилину.");
                            default: return c.nextStart ? qsTr("Доступ відкриється за кілька хвилин до початку. Програму можна не закривати.")
                                                        : qsTr("Забронюй час у боті — і повертайся сюди.");
                            }
                        }
                    }
                }
            }
            RowLayout {
                spacing: 10
                Button {
                    visible: anyplayPanel.cloud.state === "login"
                    text: qsTr("Увійти через Telegram")
                    highlighted: true
                    onClicked: anyplayPanel.cloud.login()
                }
                Button {
                    visible: anyplayPanel.cloud.state === "pairing"
                    text: qsTr("Скасувати")
                    onClicked: anyplayPanel.cloud.cancelLogin()
                }
                Button {
                    visible: anyplayPanel.cloud.loggedIn && anyplayPanel.cloud.state !== "play"
                    text: qsTr("Забронювати в боті")
                    onClicked: anyplayPanel.cloud.openBot()
                }
                Button {
                    visible: anyplayPanel.cloud.admin
                    text: qsTr("Передати PS5 на сервер")
                    onClicked: anyplayPanel.cloud.uploadConsole()
                }
                Button {
                    visible: anyplayPanel.cloud.clientMode
                    text: anyplayPanel.cloud.myPsn ? qsTr("Мій акаунт PSN: %1").arg(anyplayPanel.cloud.myPsn)
                                                   : qsTr("Додати свій акаунт PSN")
                    onClicked: psnAccountDialog.open()
                }
                Item { Layout.fillWidth: true }
                Button {
                    visible: anyplayPanel.cloud.loggedIn
                    flat: true
                    text: qsTr("Вийти")
                    onClicked: anyplayPanel.cloud.logout()
                }
            }
            Label {
                id: anyplayToast
                Layout.fillWidth: true
                visible: text !== ""
                color: "#fff3a6"; font.pixelSize: 14; font.bold: true
                wrapMode: Text.WordWrap
                Timer { id: anyplayToastTimer; interval: 8000; onTriggered: anyplayToast.text = "" }
                Connections {
                    target: Chiaki.cloud
                    function onMessage(text) { anyplayToast.text = text; anyplayToastTimer.restart(); }
                }
            }
        }
    }

    Dialog {
        id: psnAccountDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 620
        modal: true
        title: qsTr("Свій акаунт PSN")
        standardButtons: Dialog.NoButton
        onOpened: { psnField.text = Chiaki.cloud.myPsn; psnField.forceActiveFocus(); }

        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Chiaki.cloud.myPsn
                    ? (Chiaki.cloud.myPsnReady
                        ? qsTr("Твій профіль уже доданий на приставку — обирай його на PS5 після підключення.")
                        : qsTr("Ми отримали твій акаунт. Щойно додамо його на приставку, бот надішле код для входу в Telegram."))
                    : qsTr("За замовчуванням гра йде на спільному акаунті AnyPlay. Якщо хочеш свої збереження, трофеї та друзів — впиши свій PSN ID (нік у PlayStation Network).")
            }
            TextField {
                id: psnField
                Layout.fillWidth: true
                placeholderText: qsTr("Наприклад, MyNickname_7")
                onAccepted: saveButton.clicked()
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 13
                opacity: 0.75
                text: qsTr("Пароль від PSN вводити не треба — ніколи й нікому. Вхід підтверджуєш сам на приставці за QR-кодом, який надішле бот.")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Button {
                    visible: Chiaki.cloud.myPsn !== ""
                    text: qsTr("Грати на спільному")
                    onClicked: { Chiaki.cloud.setMyPsn(""); psnAccountDialog.close(); }
                }
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("Скасувати")
                    onClicked: psnAccountDialog.close()
                }
                Button {
                    id: saveButton
                    text: qsTr("Зберегти")
                    highlighted: true
                    enabled: psnField.text.trim().length >= 3
                    onClicked: { Chiaki.cloud.setMyPsn(psnField.text); psnAccountDialog.close(); }
                }
            }
        }
    }

    Image {
        id: logoImage
        anchors.centerIn: parent
        source: "qrc:/icons/anyplay-logo.png"
        sourceSize: Qt.size(Math.min(parent.width, parent.height) / 2.4, Math.min(parent.width, parent.height) / 2.4)

        PropertyAnimation {
            target: logoImage
            property: "opacity"
            from: 0.1
            to: 0.55
            duration: 1000
            easing.type: Easing.OutCubic
            running: true
        }
    }
}
