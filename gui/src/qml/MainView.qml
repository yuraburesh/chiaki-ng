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
        if(!Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
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
                visible: typeof Chiaki.createSteamShortcut === "function"
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
                visible: Chiaki.settings.psnAuthToken
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 400
                flat: true
                focusPolicy: Qt.NoFocus
                Material.roundedScale: Material.SmallScale
                visible: !Chiaki.settings.psnAuthToken
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 300
                flat: true
                text: "Додати консоль вручну"
                focusPolicy: Qt.NoFocus
                onClicked: root.showManualHostDialog()
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
