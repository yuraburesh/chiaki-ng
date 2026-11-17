import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Window

import org.streetpea.chiaking

import "controls" as C

Item {
    id: view

    readonly property var hostWindow: view.Window.window
    property bool sessionError: false
    property bool sessionLoading: true
    property list<Item> restoreFocusItems
    readonly property bool useSeparateMenuWindow: Chiaki.window.runtimeRendererBackend === 1
    // AnyPlay: клієнтам показуємо своє просте меню гри — воно трохи вище
    readonly property bool anyplayClientMenu: Chiaki.cloud.loggedIn && !Chiaki.cloud.admin
    readonly property int streamMenuHeight: anyplayClientMenu ? 300 : 200
    readonly property bool streamStatsVisible: Chiaki.settings.showStreamStats && Chiaki.session && !(menuController.open || menuController.closing) && !sessionLoading && !sessionError && !(Chiaki.settings.audioVideoDisabled & 0x02)
    property int separateMenuX: 0
    property int separateMenuY: 0
    property int separateMenuWidth: 0
    property int separateStatsX: 0
    property int separateStatsY: 0
    property int separateStatsWidth: 0
    property int separateStatsHeight: 0
    property int separateDialogX: 0
    property int separateDialogY: 0
    property bool sessionStopDialogActive: false
    property bool sessionPinDialogActive: false

    function grabInput(item) {
        Chiaki.window.grabInput();
        restoreFocusItems.push(hostWindow ? hostWindow.activeFocusItem : null);
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function releaseInput() {
        Chiaki.window.releaseInput();
        let item = restoreFocusItems.pop();
        if (item && item.visible)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function updateSeparateMenuGeometry() {
        if (!hostWindow)
            return;
        const topLeft = view.mapToGlobal(0, 0);
        if (useSeparateMenuWindow) {
            separateMenuX = Math.round(topLeft.x);
            separateMenuY = Math.round(topLeft.y + view.height - streamMenuHeight);
            separateMenuWidth = Math.round(view.width);
            separateStatsX = Math.round(topLeft.x);
            separateStatsY = Math.round(topLeft.y);
            separateStatsWidth = Math.round(view.width);
            separateStatsHeight = Math.round(view.height);
        }
    }

    function updateSeparateDialogGeometry(width, height) {
        if (!useSeparateMenuWindow || !hostWindow)
            return;
        separateDialogX = Math.round(hostWindow.x + (hostWindow.width - width) / 2);
        separateDialogY = Math.round(hostWindow.y + (hostWindow.height - height) / 2);
    }

    function updateOverlayInteractionActive() {
        Chiaki.window.setOverlayInteractionActive(
            menuController.open ||
            menuController.closing ||
            sessionStopDialogActive ||
            separateSessionStopWindow.visible ||
            sessionPinDialogActive ||
            separateSessionPinWindow.visible
        );
    }

    StackView.onActivating: {
        Chiaki.window.keepVideo = true;
        sessionError = false;
        errorTitleLabel.text = "";
        errorTextLabel.text = "";
        sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
    }
    StackView.onDeactivated: Chiaki.window.keepVideo = false

    Component.onCompleted: {
        updateSeparateMenuGeometry();
        updateOverlayInteractionActive();
        Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onStreamStatsVisibleChanged: {
        if (Chiaki.window)
            Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onWidthChanged: updateSeparateMenuGeometry()
    onHeightChanged: updateSeparateMenuGeometry()
    onUseSeparateMenuWindowChanged: updateSeparateMenuGeometry()

    Connections {
        target: view.hostWindow
        function onXChanged() { view.updateSeparateMenuGeometry() }
        function onYChanged() { view.updateSeparateMenuGeometry() }
        function onWidthChanged() { view.updateSeparateMenuGeometry() }
        function onHeightChanged() { view.updateSeparateMenuGeometry() }
        function onVisibilityChanged() { view.updateSeparateMenuGeometry() }
    }

    QtObject {
        id: menuController
        property bool closing: false
        property bool open: false

        property real lastToggleTime: 0
        function toggle() {
            var now = Date.now();
            if (now - lastToggleTime < 200)
                return;
            lastToggleTime = now;
            if (open)
                close();
            else {
                if (useSeparateMenuWindow) {
                    view.updateSeparateMenuGeometry();
                    view.grabInput(null);
                }
                open = true;
            }
            view.updateOverlayInteractionActive();
        }

        function close() {
            if (!open || closing)
                return;
            closing = true;
            open = false;
            view.releaseInput();
            view.updateOverlayInteractionActive();
        }
    }

    Rectangle {
        id: loadingView
        anchors.fill: parent
        color: "black"
        opacity: sessionError || sessionLoading || (Chiaki.settings.audioVideoDisabled & 0x02) ? 1.0 : 0.0
        visible: opacity

        Behavior on opacity { NumberAnimation { duration: 250 } }

        Item {
            anchors {
                top: parent.verticalCenter
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }

            BusyIndicator {
                id: spinner
                anchors.centerIn: parent
                width: 70
                height: width
                visible: sessionLoading
                running: sessionLoading
            }

            Label {
                anchors {
                    top: spinner.bottom
                    horizontalCenter: spinner.horizontalCenter
                    topMargin: 30
                }
                text: {
                    if(Chiaki.settings.dpadTouchEnabled)
                    {
                        if(Chiaki.settings.audioVideoDisabled == 0x01)
                            qsTr("Звук вимкнено в налаштуваннях\n") + qsTr("Натисніть %1, щоб відкрити меню").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O")) + "\n" + qsTr("Натисніть %1, щоб перемкнути хрестовину / тачпад").arg(Chiaki.settings.stringForDpadShortcut())
                        else
                            qsTr("Натисніть %1, щоб відкрити меню").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O")) + "\n" + qsTr("Натисніть %1, щоб перемкнути хрестовину / тачпад").arg(Chiaki.settings.stringForDpadShortcut())
                    }
                    else
                    {
                        if(Chiaki.settings.audioVideoDisabled == 0x01)
                            qsTr("Звук вимкнено в налаштуваннях\n") + qsTr("Натисніть %1, щоб відкрити меню").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O"))
                        else
                            qsTr("Натисніть %1, щоб відкрити меню").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O"))
                    }
                }
                visible: sessionLoading
            }

            Label {
                id: audioVideoDisabledTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("Звук і відео вимкнено") : qsTr("Відео вимкнено")
                font.pixelSize: 24
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: audioVideoDisabledTextLabel
                anchors {
                    top: audioVideoDisabledTitleLabel.bottom
                    horizontalCenter: audioVideoDisabledTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("Звук і відео вимкнено в налаштуваннях.\nЩоб увімкнути, у вкладці «Загальні» встановіть «Звук/відео» → «Звук і відео увімкнено».") : qsTr("Відео вимкнено в налаштуваннях.\nЩоб увімкнути, у вкладці «Загальні» встановіть «Звук/відео» → «Звук і відео увімкнено».")
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: errorTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                font.pixelSize: 24
                visible: text
                onVisibleChanged: if (visible) view.grabInput(errorTitleLabel)
                Keys.onReturnPressed: root.showMainView()
                Keys.onEscapePressed: root.showMainView()
            }

            Label {
                id: errorTextLabel
                anchors {
                    top: errorTitleLabel.bottom
                    horizontalCenter: errorTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                visible: text
            }
        }
    }

    ColumnLayout {
        id: cantDisplayMessage
        anchors.centerIn: parent
        opacity: Chiaki.window.hasVideo && Chiaki.session && Chiaki.session.cantDisplay ? 1.0 : 0.0
        visible: opacity
        spacing: 30

        Behavior on opacity { NumberAnimation { duration: 250 } }

        onVisibleChanged: {
            if (visible) {
                menuController.close();
                view.grabInput(goToHomeButton);
            } else {
                view.releaseInput();
            }
        }

        Label {
            Layout.alignment: Qt.AlignCenter
            text: qsTr("На екрані вміст, який не можна показати через Remote Play.")
        }

        Button {
            id: goToHomeButton
            Layout.alignment: Qt.AlignCenter
            Layout.preferredHeight: 60
            text: qsTr("На головний екран")
            Material.background: activeFocus ? parent.Material.accent : undefined
            Material.roundedScale: Material.SmallScale
            onClicked: Chiaki.sessionGoHome()
            Keys.onReturnPressed: clicked()
            Keys.onEscapePressed: clicked()
        }
    }

    RoundButton {
        anchors {
            right: parent.right
            top: parent.top
            margins: 40
        }
        icon.source: "qrc:/icons/discover-off-24px.svg"
        icon.width: 50
        icon.height: 50
        padding: 20
        checked: true
        opacity: networkIndicatorTimer.running ? 0.7 : 0.0
        visible: opacity
        Material.background: Material.accent

        Behavior on opacity { NumberAnimation { duration: 400 } }

        Timer {
            id: networkIndicatorTimer
            running: Chiaki.session?.averagePacketLoss > (Chiaki.settings.wifiDroppedNotif * 0.01)
            interval: 400
        }
    }

    Component {
        id: streamStatsContent
        Item {
            id: streamStatsContentRoot
            anchors.fill: parent
            ColumnLayout {
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    rightMargin: 5
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: "Мбіт/с"
                    font.pixelSize: 18
                    visible: Chiaki.session ? true : false

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.session.measuredBitrate.toFixed(1) : ""
                        color: Material.accent
                        font.bold: true
                        font.pixelSize: 28
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("середня глибина черги")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.queueDepthAverage.toFixed(1) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("вік кадру в черзі")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? qsTr("%1 мс").arg((Chiaki.window.pendingFrameAge * 1000.0).toFixed(0)) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    id: statsPacketLossLabel
                    text: qsTr("втрати пакетів")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? "%1<font size=\"1\">%</font>".arg((((Chiaki.session && isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
                        font.bold: true
                        color: "#ef9a9a"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("пропущені кадри")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        id: statsDroppedFramesLabel
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.droppedFrames : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("втрачені кадри")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? ((Chiaki.session && isFinite(Chiaki.session.framesLost)) ? Chiaki.session.framesLost : 0) : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }
            }
        }
    }

    // ── AnyPlay: нагадування в кінці гри ──
    Rectangle {
        id: anyplayEndBanner
        property int tick: 0
        readonly property int secsLeft: { tick; return Chiaki.cloud.endTs - Math.floor(Date.now() / 1000) - Chiaki.cloud.clockSkew; }
        visible: Chiaki.cloud.loggedIn && !Chiaki.cloud.admin && Chiaki.cloud.state === "play" && Chiaki.cloud.endTs > 0
                 && secsLeft > 0 && secsLeft <= 10 * 60 && !(menuController.open || menuController.closing)
        z: 50
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 16 }
        width: endBannerText.implicitWidth + 36
        height: endBannerText.implicitHeight + 18
        radius: 14
        color: "#d90b0618"
        border.color: "#ff2e9a"
        Timer { interval: 1000; repeat: true; running: Chiaki.cloud.state === "play"; onTriggered: anyplayEndBanner.tick++ }
        Label {
            id: endBannerText
            anchors.centerIn: parent
            font.pixelSize: 16; font.bold: true; color: "white"
            text: qsTr("⏳ Лишилось %1 хв · %2 → «⏱ Продовжити»")
                .arg(Math.ceil(anyplayEndBanner.secsLeft / 60))
                .arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O"))
        }
    }

    Component {
        id: menuContentComponent

        Item {
            id: menuContent
            readonly property bool clientMenu: view.anyplayClientMenu
            property Item initialFocusItem: clientMenu ? clientPanel.firstItem : closeButton
            property bool extOpen: false   // AnyPlay: панель продовження гри
            anchors.fill: parent

            Canvas {
                visible: !menuContent.clientMenu
                anchors.fill: parent
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    let ctx = getContext("2d");
                    let gradient = ctx.createLinearGradient(0, 0, 0, height);
                    gradient.addColorStop(0.0, Qt.rgba(0.0, 0.0, 0.0, 0.0));
                    gradient.addColorStop(0.7, Qt.rgba(0.5, 0.5, 0.5, 0.7));
                    gradient.addColorStop(1.0, Qt.rgba(0.5, 0.5, 0.5, 0.9));
                    ctx.fillStyle = gradient;
                    ctx.fillRect(0, 0, width, height);
                }
            }

            // ── AnyPlay: просте меню гри для клієнта ──
            AnyPlayStreamMenu {
                id: clientPanel
                visible: menuContent.clientMenu
                anchors { fill: parent; leftMargin: 24; rightMargin: 24; topMargin: 8; bottomMargin: 18 }
                onResume: menuController.close()
                onExit: {
                    if (Chiaki.session)
                        Chiaki.window.close();
                    else
                        root.showMainView();
                }
            }

            // ── AnyPlay: продовжити гру, не виходячи з неї ──
            RowLayout {
                visible: menuContent.extOpen && !menuContent.clientMenu
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: 30
                    rightMargin: 30
                    bottomMargin: 24
                }
                spacing: 20
                ToolButton {
                    id: extBackButton
                    text: "←"
                    font.pixelSize: 40
                    padding: 10
                    down: activeFocus
                    onClicked: { menuContent.extOpen = false; closeButton.forceActiveFocus(); }
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: clicked()
                }
                ExtendPanel {
                    id: streamExtend
                    Layout.fillWidth: true
                    compact: true
                    visible: menuContent.extOpen && !menuContent.clientMenu
                }
            }

            RowLayout {
                visible: !menuContent.extOpen && !menuContent.clientMenu
                anchors {
                    left: parent.left
                    bottom: parent.bottom
                    leftMargin: 30
                    bottomMargin: 40
                }
                spacing: 0

                ToolButton {
                    id: extendButton
                    visible: Chiaki.cloud.loggedIn && !Chiaki.cloud.admin && Chiaki.cloud.state === "play"
                    Layout.rightMargin: 16
                    text: qsTr("⏱ Продовжити")
                    padding: 14
                    font.pixelSize: 20
                    font.bold: true
                    down: activeFocus
                    onClicked: { menuContent.extOpen = true; extBackButton.forceActiveFocus(); }
                    KeyNavigation.right: closeButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: menuController.close()
                    background: Rectangle {
                        radius: 14
                        border.color: extendButton.activeFocus ? "#22e4ff" : "transparent"
                        border.width: 2
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#ff9a3c" }
                            GradientStop { position: 0.5; color: "#ff2e9a" }
                            GradientStop { position: 1.0; color: "#7b2cff" }
                        }
                    }
                }

                ToolButton {
                    id: closeButton
                    Layout.rightMargin: 20
                    text: "×"
                    padding: 10
                    font.pixelSize: 50
                    down: activeFocus
                    onClicked: {
                        if (Chiaki.session)
                            Chiaki.window.close();
                        else
                            root.showMainView();
                    }
                    KeyNavigation.right: volumeSlider
                    KeyNavigation.left: extendButton.visible ? extendButton : null
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: menuController.close()
                }

            ToolSeparator {
                Layout.leftMargin: -10
                Layout.rightMargin: 10
            }

            Slider {
                id: volumeSlider
                Layout.rightMargin: 20
                orientation: Qt.Vertical
                from: 0
                to: 128
                Layout.preferredHeight: 100
                padding: 10
                stepSize: 1
                value: Chiaki.settings.audioVolume
                onMoved: Chiaki.settings.audioVolume = value
                KeyNavigation.left: closeButton
                KeyNavigation.right: muteButton
                Keys.onEscapePressed: menuController.close()
                Label {
                    anchors {
                        top: parent.bottom
                        horizontalCenter: parent.horizontalCenter
                        leftMargin: 10
                    }
                    text: {
                        ((parent.value / 128.0) * 100).toFixed(0) + qsTr("% гучність")
                    }
                }
            }

            ToolSeparator {
                Layout.leftMargin: -10
                Layout.rightMargin: -10
            }

            ToolButton {
                id: muteButton
                Layout.rightMargin: 20
                text: qsTr("Мікрофон")
                padding: 10
                checkable: true
                enabled: Chiaki.session && Chiaki.session.connected
                checked: Chiaki.session && !Chiaki.session.muted
                onToggled: Chiaki.session.muted = !Chiaki.session.muted
                KeyNavigation.left: volumeSlider
                KeyNavigation.right: zoomButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: zoomButton
                text: qsTr("Наблизити")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                onToggled: Chiaki.window.videoMode = Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom ? ChiakiWindow.VideoMode.Normal : ChiakiWindow.VideoMode.Zoom
                KeyNavigation.left: muteButton
                KeyNavigation.right: {
                    if(Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom)
                        zoomFactor
                    else
                        stretchButton
                }
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            Slider {
                id: zoomFactor
                orientation: Qt.Vertical
                from: -1
                to: 4
                Layout.preferredHeight: 100
                stepSize: 0.01
                visible: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                value: Chiaki.window.ZoomFactor
                onMoved: {
                    Chiaki.window.ZoomFactor = value
                    Chiaki.settings.sZoomFactor = value
                }
                Label {
                    anchors {
                        top: parent.bottom
                        horizontalCenter: parent.horizontalCenter
                        leftMargin: 10
                    }
                    text: {
                        if(parent.value === -1)
                            qsTr("Без чорних смуг")
                        else if(parent.value >= 0)
                            qsTr((parent.value + 1).toFixed(2)) + qsTr(" x")
                        else
                            qsTr(parent.value.toFixed(2)) + qsTr(" x")
                    }

                }
            }

            ToolSeparator {
                Layout.leftMargin: -10
                Layout.rightMargin: -10
            }

            ToolButton {
                id: stretchButton
                Layout.rightMargin: 50
                text: qsTr("Розтягнути")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Stretch
                onToggled: Chiaki.window.videoMode = Chiaki.window.videoMode == ChiakiWindow.VideoMode.Stretch ? ChiakiWindow.VideoMode.Normal : ChiakiWindow.VideoMode.Stretch
                KeyNavigation.left: {
                    if(Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom)
                        zoomFactor
                    else
                        zoomButton
                }
                KeyNavigation.right: defaultButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: defaultButton
                text: qsTr("За замовчуванням")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Default
                onToggled: {
                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Default
                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.Default
                }
                KeyNavigation.left: stretchButton
                KeyNavigation.right: highQualityButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolSeparator {
                Layout.leftMargin: -10
                Layout.rightMargin: -10
            }

            ToolButton {
                id: highQualityButton
                text: qsTr("Висока якість")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQuality
                onToggled: {
                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQuality
                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQuality
                }
                KeyNavigation.left: defaultButton
                KeyNavigation.right: highQualitySpatialButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: highQualitySpatialButton
                text: qsTr("HQ + Spatial")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQualitySpatial
                onToggled: {
                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualitySpatial
                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQualitySpatial
                }
                KeyNavigation.left: highQualityButton
                KeyNavigation.right: highQualityAdvancedSpatialButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: highQualityAdvancedSpatialButton
                text: qsTr("HQ + Adv Spatial")
                padding: 10
                checkable: true
                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                onToggled: {
                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                }
                KeyNavigation.left: highQualitySpatialButton
                KeyNavigation.right: customButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolSeparator {
                Layout.leftMargin: -10
                Layout.rightMargin: -10
            }

            ToolButton {
                id: customButton
                text: qsTr("Власний")
                Layout.rightMargin: 40
                padding: 10
                checkable: true
                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                onToggled: {
                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Custom
                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.Custom
                }
                KeyNavigation.left: highQualityAdvancedSpatialButton
                KeyNavigation.right: displaySettingsButton
                Keys.onReturnPressed: toggled()
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: displaySettingsButton
                text: qsTr("Екран")
                padding: 10
                checkable: false
                icon.source: "qrc:/icons/settings-20px.svg";
                onClicked: root.openDisplaySettings()
                KeyNavigation.left: customButton
                KeyNavigation.right: {
                    if(Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom)
                        placeboSettingsButton;
                    else
                        displaySettingsButton;
                }
                Keys.onReturnPressed: {
                    menuController.close();
                    clicked();
                }
                Keys.onEscapePressed: menuController.close()
            }

            ToolButton {
                id: placeboSettingsButton
                text: qsTr("Placebo")
                icon.source: "qrc:/icons/settings-20px.svg";
                padding: 10
                checkable: false
                onClicked: root.openPlaceboSettings()
                KeyNavigation.left: displaySettingsButton
                visible: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                Keys.onReturnPressed: {
                    menuController.close();
                    clicked();
                }
                Keys.onEscapePressed: menuController.close()
            }
            }

            Label {
                anchors {
                    right: consoleNameLabel.right
                    bottom: consoleNameLabel.top
                    bottomMargin: 5

                }
                text: "Мбіт/с"
                font.pixelSize: 18
                visible: Chiaki.session && !menuContent.clientMenu

                Label {
                    anchors {
                        right: parent.left
                        baseline: parent.baseline
                        rightMargin: 5
                    }
                        text: visible && Chiaki.session ? Chiaki.session.measuredBitrate.toFixed(1) : ""
                    color: Material.accent
                    font.bold: true
                    font.pixelSize: 28
                }
            }

            Label {
                id: consoleNameLabel
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    rightMargin: 30
                }
                visible: !menuContent.clientMenu
                text: {
                    if (!Chiaki.session)
                        return "";
                    if (Chiaki.session.connected)
                        return qsTr("Підключено до <b>%1</b>").arg(Chiaki.settings.streamerMode ? "hidden" : Chiaki.session.host);
                    return qsTr("Підключення до <b>%1</b>").arg(Chiaki.settings.streamerMode ? "hidden" : Chiaki.session.host);
                }

                RowLayout {
                    anchors {
                        right: parent.right
                        top: parent.bottom
                        topMargin: 12
                    }

                    Label {
                        text: qsTr("втрати пакетів")
                        font.pixelSize: 15
                        opacity: parent.visible && Chiaki.session ? 1.0 : 0.0
                        visible: opacity

                        Behavior on opacity { NumberAnimation { duration: 250 } }

                        Label {
                            anchors {
                                right: parent.left
                                baseline: parent.baseline
                                rightMargin: 5
                            }
                            text: visible ? "%1<font size=\"1\">%</font>".arg((((Chiaki.session && isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
                            color: "#ef9a9a" // Material.Red
                            font.bold: true
                            font.pixelSize: 18
                        }
                    }

                    Label {
                        Layout.leftMargin: droppedFramesLabel.width + 6
                        text: qsTr("пропущені кадри")
                        font.pixelSize: 15
                        opacity: parent.visible && Chiaki.window.droppedFrames ? 1.0 : 0.0
                        visible: opacity

                        Behavior on opacity { NumberAnimation { duration: 250 } }

                        Label {
                            id: droppedFramesLabel
                            anchors {
                                right: parent.left
                                baseline: parent.baseline
                                rightMargin: 5
                            }
                            text: visible ? Chiaki.window.droppedFrames : ""
                            color: "#ef9a9a" // Material.Red
                            font.bold: true
                            font.pixelSize: 18
                        }
                    }
                }
            }
        }
    }

    Item {
        id: menuView
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: streamMenuHeight
        y: menuController.open ? parent.height - height : parent.height
        visible: !useSeparateMenuWindow && (menuController.open || menuController.closing)
        enabled: !useSeparateMenuWindow && menuController.open
        onVisibleChanged: {
            if (visible)
                view.grabInput(inlineMenuContent.item ? inlineMenuContent.item.initialFocusItem : null);
        }

        Behavior on y {
            NumberAnimation {
                id: inlineMenuAnimation
                duration: 250
                onRunningChanged: {
                    if (!running && !menuController.open) {
                        menuController.closing = false;
                        view.updateOverlayInteractionActive();
                    }
                }
            }
        }

        Loader {
            id: inlineMenuContent
            anchors.fill: parent
            active: !useSeparateMenuWindow
            sourceComponent: menuContentComponent
        }
    }

    StreamMenuWindow {
        id: separateMenuWindow
        transientParent: view.hostWindow
        x: separateMenuX
        y: menuController.open ? separateMenuY : separateMenuY + streamMenuHeight
        width: separateMenuWidth > 0 ? separateMenuWidth : view.width
        height: streamMenuHeight
        open: useSeparateMenuWindow && menuController.open
        closing: useSeparateMenuWindow && menuController.closing
        clientMenu: view.anyplayClientMenu
        onCloseRequested: menuController.close()
        onDisplaySettingsRequested: {
            menuController.close();
            root.openDisplaySettings();
        }
        onPlaceboSettingsRequested: {
            menuController.close();
            root.openPlaceboSettings();
        }
        onMainViewRequested: root.showMainView()
        onCloseAnimationFinished: {
            if (view.hostWindow)
                view.hostWindow.requestActivate();
            menuController.closing = false;
            view.updateOverlayInteractionActive();
        }
    }

    Popup {
        id: sessionStopDialog
        property int closeAction: 0
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        modal: true
        padding: 30
        onAboutToShow: {
            closeAction = 0;
            sessionStopDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionStopDialogActive = false;
            view.updateOverlayInteractionActive();
            if (closeAction)
                Chiaki.stopSession(closeAction == 1);
        }

        ColumnLayout {
            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Завершити сеанс")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Перевести консоль у режим спокою?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: sleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Режим спокою")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: noButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onVisibleChanged: if (visible) view.grabInput(sleepButton)
                    onClicked: {
                        sessionStopDialog.closeAction = 1;
                        sessionStopDialog.close();
                    }
                }

                Button {
                    id: noButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Ні")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: sleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onClicked: {
                        sessionStopDialog.closeAction = 2;
                        sessionStopDialog.close();
                    }
                }
            }
        }
    }

    Window {
        id: separateSessionStopWindow
        property int closeAction: 0
        readonly property int dialogWidth: 700
        readonly property int dialogHeight: 260
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                closeAction = 0;
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separateSleepButton);
            } else {
                view.releaseInput();
                if (closeAction)
                    Chiaki.stopSession(closeAction === 1);
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors.centerIn: parent

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Завершити сеанс")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Перевести консоль у режим спокою?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: separateSleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Режим спокою")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: separateNoButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 1;
                        separateSessionStopWindow.visible = false;
                    }
                }

                Button {
                    id: separateNoButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Ні")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: separateSleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 2;
                        separateSessionStopWindow.visible = false;
                    }
                }
            }
        }
    }

    Dialog {
        id: sessionPinDialog
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        title: qsTr("PIN-код входу на консоль")
        modal: true
        closePolicy: Popup.NoAutoClose
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAboutToShow: {
            standardButton(Dialog.Ok).enabled = Qt.binding(function() {
                return pinField.acceptableInput;
            });
            view.grabInput(pinField);
            sessionPinDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionPinDialogActive = false;
            view.updateOverlayInteractionActive();
        }
        onAccepted: Chiaki.enterPin(pinField.text)
        onRejected: Chiaki.stopSession(false)
        Material.roundedScale: Material.MediumScale

        TextField {
            id: pinField
            echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
            implicitWidth: 200
            validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
            Keys.onReturnPressed: {
                if(sessionPinDialog.standardButton(Dialog.Ok).enabled)
                    sessionPinDialog.standardButton(Dialog.Ok).clicked()
            }
        }
    }

    Window {
        id: separateSessionPinWindow
        readonly property int dialogWidth: 360
        readonly property int dialogHeight: 220
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                separatePinField.text = "";
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separatePinField);
            } else {
                view.releaseInput();
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 24
            }

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("PIN-код входу на консоль")
                font.bold: true
                font.pixelSize: 24
            }

            TextField {
                id: separatePinField
                Layout.topMargin: 20
                Layout.fillWidth: true
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
                Keys.onReturnPressed: if (acceptableInput) separatePinOkButton.clicked()
                Keys.onEscapePressed: separateSessionPinWindow.visible = false
            }

            RowLayout {
                Layout.topMargin: 20
                Layout.alignment: Qt.AlignRight
                spacing: 16

                Button {
                    text: qsTr("Скасувати")
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        separateSessionPinWindow.visible = false;
                        Chiaki.stopSession(false);
                    }
                }

                Button {
                    id: separatePinOkButton
                    text: qsTr("OK")
                    enabled: separatePinField.acceptableInput
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        const pin = separatePinField.text;
                        separateSessionPinWindow.visible = false;
                        Chiaki.enterPin(pin);
                    }
                }
            }
        }
    }

    Timer {
        id: closeTimer
        interval: 2000
        onTriggered: root.showMainView()
    }

    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session) {
                if (errorTitleLabel.text)
                    closeTimer.start();
                else
                    root.showMainView();
            } else {
                sessionError = false;
                errorTitleLabel.text = "";
                errorTextLabel.text = "";
                sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
            }
        }

        function onSessionError(title, text) {
            sessionError = true;
            sessionLoading = false;
            errorTitleLabel.text = title;
            errorTextLabel.text = text;
            closeTimer.start();
        }

        function onSessionPinDialogRequested() {
            if (sessionPinDialog.opened || separateSessionPinWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionPinWindow.visible = true;
            else
                sessionPinDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }

        function onSessionStopDialogRequested() {
            if (sessionStopDialog.opened || separateSessionStopWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionStopWindow.visible = true;
            else
                sessionStopDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }
    }

    Connections {
        target: Chiaki.window

        function onLoadingTransitionCompleteChanged() {
            if (Chiaki.window.loadingTransitionComplete) {
                sessionLoading = false;
                Chiaki.window.noteLoadingTransitionComplete();
                Chiaki.window.requestOverlayUpdate();
            } else if (Chiaki.session) {
                sessionLoading = !(Chiaki.settings.audioVideoDisabled & 0x02);
            }
        }

        function onMenuRequested() {
            if (sessionPinDialog.opened || sessionStopDialog.opened || separateSessionPinWindow.visible || separateSessionStopWindow.visible)
                return;
            menuController.toggle();
            Chiaki.window.requestOverlayUpdate();
        }
    }
    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session)
                menuController.close();
        }
    }
    Connections {
        target: Chiaki.session

        function onConnectedChanged() {
            if (Chiaki.settings.audioVideoDisabled & 0x02)
                sessionLoading = false;
            // AnyPlay: підказка новачку — де меню, клавіші й вихід
            if (Chiaki.session && Chiaki.session.connected && view.anyplayClientMenu)
                anyplayStartHint.show();
        }

        // AnyPlay: show the control mode (on foot / vehicle / aircraft) for a moment when it changes
        function onControlProfileChanged() {
            anyplayProfileLabel.opacity = 1;
            anyplayProfileTimer.interval = anyplayProfileLabel.text.length > 14 ? 3200 : 1600;
            anyplayProfileTimer.restart();
        }
    }

    Rectangle {
        id: anyplayStartHint
        z: 100
        function show() { opacity = 1; anyplayStartHintTimer.restart(); }
        anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 30 }
        width: anyplayStartHintText.implicitWidth + 40
        height: anyplayStartHintText.implicitHeight + 20
        radius: 14
        color: "#d90b0618"
        border.color: "#22e4ff"
        opacity: 0
        visible: opacity > 0 && !(menuController.open || menuController.closing)
        Behavior on opacity { NumberAnimation { duration: 400 } }
        Label {
            id: anyplayStartHintText
            anchors.centerIn: parent
            font.pixelSize: 16; font.bold: true; color: "white"
            text: qsTr("Меню гри — %1: там клавіші, продовження і вихід").arg(Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O")
        }
        Timer { id: anyplayStartHintTimer; interval: 12000; onTriggered: anyplayStartHint.opacity = 0 }
    }

    Label {
        id: anyplayProfileLabel
        z: 100
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: 28
        }
        text: Chiaki.session ? Chiaki.session.controlProfile : ""
        font.pixelSize: 26
        font.bold: true
        color: "white"
        style: Text.Outline
        styleColor: "black"
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 300 } }

        Timer {
            id: anyplayProfileTimer
            interval: 1600
            onTriggered: anyplayProfileLabel.opacity = 0
        }
    }

}
