import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property var callback: null
    property bool login
    property bool submitting: false
    property bool closing: false
    property var psnurl: ""
    title: qsTr("Вхід у PSN")
    buttonVisible: false
    buttonText: qsTr("Отримати ID акаунта")
    buttonEnabled: !submitting && url.text.trim()
    onAccepted: {
        submitting = true;
        Chiaki.handlePsnLoginRedirect(url.text.trim());
    }
    StackView.onActivated: {
        if(login)
        {
            nativeLoginForm.visible = true;
            nativeLoginForm.forceActiveFocus(Qt.TabFocusReason);
            if(Qt.platform.os == "linux")
                extBrowserButton.clicked();
        }
        else
        {
            accountForm.visible = true
            usernameField.forceActiveFocus(Qt.TabFocusReason)
            usernameField.readOnly = false;
            Qt.inputMethod.show();
        }
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
            id: nativeLoginForm
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
            visible: false
            ToolBar {
                id: psnLoginToolbar
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
                            nativeLoginForm.visible = false;
                            psnLoginToolbar.visible = false;
                            nativeErrorGrid.visible = false;
                            webView.visible = false;
                            loginForm.visible = true;
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
                    top: psnLoginToolbar.bottom
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
                    top: psnLoginToolbar.bottom
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                    leftMargin: 10
                    rightMargin: 10
                }
                Component.onCompleted: {
                    try {
                        web = Qt.createQmlObject("
                        import QtWebEngine
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
                            }

                            onContextMenuRequested: (request) => request.accepted = true;
                            onNavigationRequested: (request) => {
                                if (Chiaki.checkPsnRedirectURL(request.url)) {
                                    Chiaki.handlePsnLoginRedirect(request.url)
                                    request.reject();
                                }
                                else
                                    request.accept();
                            }
                            onCertificateError: console.error(error.description);
                        }", webView, "webView");
                        Chiaki.setWebEngineHints(web.profile);
                        webView.web.url = Chiaki.psnLoginUrl();
                        web.anchors.fill = webView;
                    } catch (error) {
                        console.error('Create webengine view failed with error:' + error);
                        extBrowserButton.clicked();
                    }
                }
            }
        }
        GridLayout {
            id: loginForm
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 50
            }
            visible: false
            columns: 2
            rowSpacing: 10
            columnSpacing: 20

            Label {
                id: errorHeader
                visible: false
                text: "Не вдалося отримати ID акаунта PSN"
            }

            Label {
                id: errorLabel
                visible: false
            }

            Label {
                text: qsTr("Відкрити браузер (адресу скопійовано)")
                visible: psnurl
            }

            TextField {
                id: openurl
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                text: psnurl
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
                    KeyNavigation.priority: KeyNavigation.BeforeItem
                    onClicked: url.paste()
                    KeyNavigation.left: url
                    KeyNavigation.up: {
                        if(psnurl)
                            copyUrl
                        else
                            pasteUrl
                    }
                    KeyNavigation.down: pasteUrl
                    lastInFocusChain: true
                }
            }
        }

        ColumnLayout {
            id: accountForm
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: parent.height / 10
            }
            visible: false

            Label {
                id: formLabel
                Layout.alignment: Qt.AlignCenter
                Layout.bottomMargin: 50
                text: qsTr("Для цього в налаштуваннях приватності PSN має бути дозволено знаходити вас у пошуку")
            }

            C.TextField {
                id: usernameField
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                Layout.preferredWidth: 400
                Layout.alignment: Qt.AlignCenter
                firstInFocusChain: true
                placeholderText: qsTr("Ім'я користувача")
                onAccepted: submitButton.clicked()
            }

            C.Button {
                id: submitButton
                Layout.preferredWidth: 400
                Layout.alignment: Qt.AlignCenter
                lastInFocusChain: true
                text: qsTr("Надіслати")
                onClicked: {
                    const username = usernameField.text.trim();
                    if (!username.length || !enabled)
                        return;
                    const request = new XMLHttpRequest();
                    request.onreadystatechange = function() {
                        if (request.readyState === XMLHttpRequest.DONE) {
                            const response = JSON.parse(request.response);
                            const accountId = response["encoded_id"];
                            if (accountId) {
                                dialog.callback(accountId);
                                dialog.close();
                            } else {
                                enabled = true;
                                formLabel.text = qsTr("Помилка: %1!").arg(response["error"]);
                            }
                        }
                    }
                    request.open("GET", "https://psn.flipscreen.games/search.php?username=%1".arg(encodeURIComponent(username)));
                    request.send();
                    enabled = false;
                }
            }
        }

        Connections {
            target: Chiaki

            function onPsnLoginAccountIdDone(accountId) {
                dialog.callback(accountId);
                submitting = false;
                dialog.close();
            }

            function onPsnLoginAccountIdError(error) {
                if(nativeLoginForm.visible)
                {
                    webView.visible = false;
                    nativeErrorLabel.text = error;
                    nativeErrorLabel.visible = true;
                    nativeErrorGrid.visible = true;
                }
                else
                {
                    errorHeader.visible = true;
                    errorLabel.text = error;
                    errorLabel.visible = true;
                    submitting = false;
                }
            }
        }
    }
}
