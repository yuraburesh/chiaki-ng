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
            qsTr("Дані входу застаріли: оновіть віддалене підключення PSN")
        else
            qsTr("Налаштувати автоматичне віддалене підключення PSN")
    }
    buttonText: qsTr("Налаштувати")
    buttonEnabled: url.text.trim()
    buttonVisible: false
    onAccepted: {
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
            if (Chiaki.checkPsnRedirectURL(t) && url.text.trim() !== t) {
                url.text = t;
                if (dialog.buttonEnabled)
                    dialog.accepted();
            }
        }
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
                height: 80

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    Button {
                        id: reloadButton
                        Layout.fillHeight: true
                        Layout.preferredWidth: 350
                        flat: true
                        text: "перезавантажити + очистити cookie"
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
                        }
                        onClicked: reloadTimer.start()
                        Material.roundedScale: Material.SmallScale
                        focusPolicy: Qt.NoFocus
                    }
                    ProgressBar {
                        id: browserProgresss
                        Layout.fillHeight: true
                        Layout.preferredWidth: 300
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
                            source: "qrc:/icons/r1.svg"
                        }
                        focusPolicy: Qt.NoFocus
                        text: "Відкрити у звичайному браузері"
                        onClicked: {
                            nativeTokenForm.visible = false;
                            psnTokenToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            linkgrid.visible = true;
                            dialog.buttonVisible = true;
                            psnurl = Chiaki.openPsnLink();
                            if(psnurl)
                            {
                                openurl.selectAll();
                                openurl.copy();
                            }
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
                        import QtWebEngine
                        import QtQuick.Controls
                        import org.streetpea.chiaking
                        WebEngineView {
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
        GridLayout {
            id: linkgrid
            visible: false
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 50
            }
            columns: 2
            rowSpacing: 10
            columnSpacing: 20

            Label {
                text: qsTr("Відкрити браузер (адресу скопійовано)")
                visible: psnurl
            }

            TextField {
                id: openurl
                text: psnurl
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                visible: false
                Layout.preferredWidth: 400
            }

            C.Button {
                id: copyUrl
                text: qsTr("Натисніть, щоб скопіювати адресу ще раз")
                onClicked: {
                    openurl.selectAll()
                    openurl.copy()
                }
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.up: copyUrl
                KeyNavigation.down: url
                visible: psnurl
            }

            Label {
                text: qsTr("Адреса переадресації з браузера")
            }

            TextField {
                id: url
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.preferredWidth: 400
                KeyNavigation.priority: {
                    if(readOnly)
                        KeyNavigation.BeforeItem
                    else
                        KeyNavigation.AfterItem
                }
                KeyNavigation.up: {
                    if(psnurl)
                        copyUrl
                    else
                        url
                }
                KeyNavigation.down: url
                KeyNavigation.right: pasteUrl
                C.Button {
                    id: pasteUrl
                    text: qsTr("Натисніть, щоб вставити адресу")
                    anchors {
                        left: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: 10
                    }
                    onClicked: url.paste()
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    KeyNavigation.left: url
                    KeyNavigation.up: {
                        if(psnurl)
                            copyUrl
                        else
                            pasteUrl
                    }
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
                title: qsTr("Створити токен автоматичного віддаленого підключення PSN")
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