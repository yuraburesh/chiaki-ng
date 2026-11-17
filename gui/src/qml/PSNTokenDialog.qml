import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property var psnurl
    property var expired
    property bool closing: false
    title: {
        if(expired)
            qsTr("Вхід у PSN застарів — увійди ще раз (сторінка Sony)")
        else
            qsTr("Вхід у PSN: офіційна сторінка Sony")
    }
    buttonText: qsTr("Налаштувати")
    buttonEnabled: url.text.trim()
    buttonVisible: false
    property bool submitted: false
    onAccepted: {
        if (submitted)
            return;
        submitted = true;
        logDialog.open()
        Chiaki.initPsnAuth(url.text.trim(), function(msg, ok, done) {
            if(ok)
                Chiaki.settings.remotePlayAsk = false;
            if (!done)
                logArea.text += msg + "\n";
            else
            {
                logArea.text += msg + "\n";
                logDialog.standardButtons = Dialog.Close;
                if (!ok)
                    dialog.submitted = false;   // можна спробувати ще раз
            }
        });
    }
    StackView.onActivated: {
        Chiaki.settings.remotePlayAsk = true;
        nativeTokenForm.visible = true;
        nativeTokenForm.forceActiveFocus(Qt.TabFocusReason);
        if(Qt.platform.os == "linux")
            extBrowserButton.clicked();
    }
    // AnyPlay: якщо клієнт увійшов у звичайному браузері й скопіював адресу сторінки
    // «redirect» — підхоплюємо її з буфера обміну і продовжуємо самі.
    property Timer anyplayClipWatchTimer: Timer {
        id: anyplayClipWatch
        interval: 700
        repeat: true
        running: dialog.buttonVisible
        property string last: ""
        onTriggered: {
            const t = Chiaki.clipboardText();
            if (!t || t === last)
                return;
            last = t;
            if (Chiaki.checkPsnRedirectURL(t) && url.text.trim() !== t)
                url.text = t;   // далі спрацює onTextChanged поля
        }
    }
    function sonyBlocked() {
        if (!webView.visible)
            return;
        extReason.text = qsTr("Sony не дала увійти у вбудованому вікні (таке буває) — тому відкриваємо вхід у твоєму звичайному браузері.");
        extBrowserButton.clicked();
    }
    function close() {
        if(webView.web)
        {
            dialog.closing = true;
            if(Chiaki.settings.remotePlayAsk)
                reloadTimer.start();
            else
                cacheClearTimer.start();
        }
        else
            root.closeDialog();
    }

    Item {
        Item {
            id: nativeTokenForm
            visible: false
            Keys.onPressed: (event) => {
                if (event.modifiers)
                    return;
                switch (event.key) {
                case Qt.Key_PageUp:
                    reloadButton.clicked();
                    event.accepted = true;
                    break;
                case Qt.Key_PageDown:
                    extBrowserButton.clicked();
                    event.accepted = true;
                    break;
                }
            }
            anchors.fill: parent
            ToolBar {
                id: psnTokenToolbar
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                }
                height: 46
                Material.primary: "#160d2b"
                Material.background: "#160d2b"
                Material.foreground: "#bfaed8"

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    Button {
                        id: reloadButton
                        Layout.fillHeight: true
                        Layout.preferredWidth: 220
                        flat: true
                        font.pixelSize: 14
                        text: "↻ Оновити сторінку"
                        Image {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                            }
                            width: 28
                            height: 28
                            sourceSize: Qt.size(width, height)
                            visible: false
                            source: "qrc:/icons/l1.svg"
                        }
                        onClicked: reloadTimer.start()
                        Material.roundedScale: Material.SmallScale
                        focusPolicy: Qt.NoFocus
                    }
                    ProgressBar {
                        id: browserProgresss
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        value: webView.web.loadProgress
                        Material.roundedScale: Material.SmallScale
                        focusPolicy: Qt.NoFocus
                    }
                    Button {
                        id: extBrowserButton
                        Layout.fillHeight: true
                        Layout.preferredWidth: 300
                        flat: true
                        Image {
                            anchors {
                                left: parent.left
                                verticalCenter: parent.verticalCenter
                                leftMargin: 12
                            }
                            width: 28
                            height: 28
                            sourceSize: Qt.size(width, height)
                            visible: false
                            source: "qrc:/icons/r1.svg"
                        }
                        focusPolicy: Qt.NoFocus
                        font.pixelSize: 14
                        text: "Не вантажиться? Відкрити в браузері ↗"
                        onClicked: {
                            nativeTokenForm.visible = false;
                            psnTokenToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            linkgrid.visible = true;
                            dialog.buttonVisible = true;
                            psnurl = Chiaki.openPsnLink();
                            pasteUrl.forceActiveFocus(Qt.TabFocusReason);
                        }
                    }
                }
            }
            Timer {
                id: reloadTimer
                interval: 0
                running: false
                onTriggered: {
                    Chiaki.clearCookies(webView.web.profile);
                    webView.web.profile.clearHttpCache();
                }
            }

            Timer {
                id: cacheClearTimer
                interval: 0
                running: false
                onTriggered: {
                    webView.web.profile.clearHttpCache();
                }
            }

            GridLayout {
                id: nativeErrorGrid
                visible: false
                anchors {
                    top: psnTokenToolbar.bottom
                    left: parent.left
                    right: parent.right
                    topMargin: 50
                }
                columns: 2
                rowSpacing: 10
                columnSpacing: 20
                Label {
                    id: nativeErrorHeader
                    text: "Не вдалося отримати ID акаунта PSN, помилка: "
                    Layout.fillHeight: true
                    Layout.preferredWidth: 400
                    Layout.leftMargin: 20
                }

                Label {
                    id: nativeErrorLabel
                    Layout.fillHeight: true
                    Layout.preferredWidth: 400
                    Layout.leftMargin: 20
                }

                Label {
                    id: retryButton
                    text: "Повторити"
                    Layout.fillHeight: true
                    Layout.preferredWidth: 300
                    Layout.leftMargin: 20
                }
                C.Button {
                    firstInFocusChain: true
                    lastInFocusChain: true
                    text: "Ще раз"
                    onClicked: {
                        nativeErrorGrid.visible = false;
                        nativeErrorLabel.text = "";
                        nativeErrorLabel.visible = false;
                        webView.visible = true;
                        webView.web.url = Chiaki.psnLoginUrl();
                    }
                    Layout.preferredWidth: 200
                    Layout.fillHeight: true
                    Layout.leftMargin: 20
                }
            }
            Item {
                id: webView
                property Item web: null
                anchors {
                    top: psnTokenToolbar.bottom
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                    leftMargin: 10
                    rightMargin: 10
                }
                property bool started: false
                Component.onCompleted: {
                    try {
                        web = Qt.createQmlObject("
                        import QtQuick
                        import QtWebEngine
                        import QtQuick.Controls
                        import org.streetpea.chiaking
                        WebEngineView {
                            id: wev
                            profile {
                                offTheRecord: false
                                storageName: 'psn-token'
                                onClearHttpCacheCompleted: {
                                    if(dialog.closing)
                                        root.closeDialog();
                                    else
                                        webView.web.reload();
                                }
                            }
                            settings {
                                // Load larger touch icons
                                touchIconsEnabled: true
                                localContentCanAccessRemoteUrls: true
                            }

                            onContextMenuRequested: (request) => request.accepted = true;
                            onNavigationRequested: (request) => {
                                if (Chiaki.checkPsnRedirectURL(request.url)) {
                                    logDialog.open()
                                    Chiaki.initPsnAuth(request.url, function(msg, ok, done) {
                                        if (!done)
                                            logArea.text += msg + '\n';
                                        else
                                        {
                                            logArea.text += msg + '\n';
                                            logDialog.standardButtons = Dialog.Close;
                                        }
                                    });
                                    request.reject();
                                }
                                else
                                    request.accept();
                            }
                            onCertificateError: console.error(error.description);
                            // AnyPlay: Sony інколи відмовляє вбудованому вікну («connection to the server timed out»)
                            Timer {
                                interval: 1500; repeat: true; running: webView.visible && !dialog.closing
                                onTriggered: wev.runJavaScript('document.body ? document.body.innerText : String()', function(t) {
                                    if (!t || !webView.visible)
                                        return;
                                    const low = String(t).toLowerCase();
                                    if (low.indexOf('connection to the server timed out') >= 0 || low.indexOf('connect to the server') >= 0)
                                        dialog.sonyBlocked();
                                })
                            }
                        }", webView, "webView");
                        Chiaki.setWebEngineHints(web.profile);
                        web.url = Chiaki.psnLoginUrl();
                        web.anchors.fill = webView;
                    } catch (error) {
                        console.error('Create webengine view failed with error:' + error);
                        extBrowserButton.clicked();
                    }
                }
            }
        }
        // AnyPlay: вхід через звичайний браузер — простий покроковий екран
        ColumnLayout {
            id: linkgrid
            visible: false
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 36
            }
            width: Math.min(parent.width - 60, 680)
            spacing: 14

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 22; font.bold: true
                text: qsTr("Вхід у PSN через твій браузер")
            }
            Label {
                id: extReason
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text !== ""
                color: "#ffd23f"; font.pixelSize: 14
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 16
                text: qsTr("1. У браузері відкрилась сторінка Sony — увійди у свій акаунт PSN.\n"
                         + "2. Після входу з'явиться порожня сторінка зі словом «redirect» — так і має бути.\n"
                         + "3. Скопіюй адресу цієї сторінки (клацни адресний рядок, потім %1) і повернись сюди — програма підхопить її сама.")
                      .arg(Qt.platform.os === "osx" ? "Cmd+C" : "Ctrl+C")
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.7; font.pixelSize: 13
                text: qsTr("🔒 Пароль ти вводиш лише на сайті Sony — програма його не бачить.")
            }

            TextField {
                id: openurl
                text: psnurl
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                visible: false
                Layout.preferredWidth: 400
            }

            RowLayout {
                spacing: 10
                C.Button {
                    id: copyUrl
                    text: qsTr("Відкрити сторінку Sony ще раз")
                    onClicked: {
                        psnurl = Chiaki.openPsnLink();
                    }
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    KeyNavigation.up: copyUrl
                    KeyNavigation.down: url
                }
            }

            Label {
                Layout.topMargin: 6
                opacity: 0.8; font.pixelSize: 14
                text: qsTr("Не підхопилось само? Встав скопійовану адресу сюди:")
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                TextField {
                    id: url
                    Layout.fillWidth: true
                    placeholderText: qsTr("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…")
                    echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                    KeyNavigation.up: copyUrl
                    KeyNavigation.down: url
                    KeyNavigation.right: pasteUrl
                    onTextChanged: if (Chiaki.checkPsnRedirectURL(text.trim())) dialog.accepted()
                }
                C.Button {
                    id: pasteUrl
                    text: qsTr("Вставити")
                    onClicked: url.paste()
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    KeyNavigation.left: url
                    KeyNavigation.up: copyUrl
                    KeyNavigation.down: pasteUrl
                }
            }
        }

        Item {
            Dialog {
                id: logDialog
                parent: Overlay.overlay
                x: Math.round((root.width - width) / 2)
                y: Math.round((root.height - height) / 2)
                title: qsTr("Завершуємо вхід у PSN")
                modal: true
                closePolicy: Popup.NoAutoClose
                standardButtons: Dialog.Cancel
                Material.roundedScale: Material.MediumScale
                onOpened: logArea.forceActiveFocus(Qt.TabFocusReason)
                onClosed: root.showMainView();

                Flickable {
                    id: logFlick
                    implicitWidth: 600
                    implicitHeight: 400
                    clip: true
                    contentWidth: logArea.contentWidth
                    contentHeight: logArea.contentHeight
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        id: logScrollbar
                        policy: ScrollBar.AlwaysOn
                        visible: logFlick.contentHeight > logFlick.implicitHeight
                    }

                    Label {
                        id: logArea
                        width: logFlick.width
                        wrapMode: TextEdit.Wrap
                        Keys.onReturnPressed: if (logDialog.standardButtons == Dialog.Close) logDialog.close()
                        Keys.onEscapePressed: logDialog.close()
                        Keys.onPressed: (event) => {
                            switch (event.key) {
                            case Qt.Key_Up:
                                if(logScrollbar.position > 0.001)
                                    logFlick.flick(0, 500);
                                event.accepted = true;
                                break;
                            case Qt.Key_Down:
                                if(logScrollbar.position < 1.0 - logScrollbar.size - 0.001)
                                    logFlick.flick(0, -500);
                                event.accepted = true;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}