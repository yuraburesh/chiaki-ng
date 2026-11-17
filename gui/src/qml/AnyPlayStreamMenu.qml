// AnyPlay: просте меню гри для клієнта (відкривається під час трансляції).
// Три сторінки: головна (повернутись / продовжити / клавіші / гучність / вийти), продовження гри, клавіші.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Rectangle {
    id: panel
    property string page: "main"   // main | extend | keys
    property int tick: 0
    readonly property string menuKey: Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : (Qt.platform.os === "osx" ? "Cmd+O" : "Ctrl+O")
    signal resume()   // закрити меню й повернутись у гру
    signal exit()     // завершити трансляцію
    readonly property Item firstItem: resumeBtn

    function focusFirst() { (page === "main" ? resumeBtn : backBtn).forceActiveFocus(Qt.TabFocusReason); }
    function goMain() { page = "main"; resumeBtn.forceActiveFocus(); }
    onVisibleChanged: if (!visible) page = "main"

    radius: 22
    color: "#f5120a24"
    border.color: "#55ffffff"

    Timer { interval: 1000; repeat: true; running: panel.visible; onTriggered: panel.tick++ }

    function leftText() {
        tick;
        const sec = Chiaki.cloud.endTs - Math.floor(Date.now() / 1000) - Chiaki.cloud.clockSkew;
        if (!(Chiaki.cloud.endTs > 0) || sec <= 0)
            return "";
        const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), x = sec % 60;
        return qsTr("Лишилось %1, гра до %2").arg((h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0")).arg(Chiaki.cloud.formatTime(Chiaki.cloud.endTs));
    }
    // головні клавіші: беремо справжні призначення (з урахуванням змін клієнта)
    function keyRows() {
        const labels = { pause: qsTr("кнопка OPTIONS — пауза й меню в самій грі"), ps: qsTr("кнопка PS — головне меню приставки"), map: qsTr("тачпад — карта"),
                         select: qsTr("✕ — вибрати / підтвердити"), back: qsTr("○ — назад / закрити") };
        let rows = [{ name: qsTr("це меню: клавіші, продовження, вихід"), key: menuKey }];
        const profiles = Chiaki.settings.anyplayProfiles();
        let modes = [];
        for (let i = 0; i < profiles.length; i++) {
            const p = profiles[i];
            for (let j = 0; j < p.bindings.length; j++) {
                const b = p.bindings[j];
                let key = b.keyName;
                if (Qt.platform.os === "osx" && b.key === "Home")
                    key = "Fn + ←";
                if (p.id === "global" && labels[b.id])
                    rows.push({ name: labels[b.id], key: key });
                else if (p.id === "global" && b.id.indexOf("mode_") === 0)
                    modes.push({ name: b.name, key: key });
                else if (p.id === "foot" && b.id === "vehicle")
                    rows.push({ name: qsTr("сісти в транспорт / вийти з нього"), key: key });
            }
        }
        rows.push({ name: qsTr("навігація в меню приставки"), key: "↑ ↓ ← →" });
        return rows.concat(modes);
    }

    // Ті самі три рівні якості, що й на головному екрані
    readonly property var qualities: [
        { id: "eco", name: qsTr("Економна"), info: qsTr("540p, 30 кадр/с"), res: 2, fps: 30, bitrate: 0 },
        { id: "opt", name: qsTr("Оптимальна"), info: qsTr("720p, 60 кадр/с"), res: 3, fps: 60, bitrate: 0 },
        { id: "max", name: qsTr("Максимальна"), info: qsTr("1080p, 60 кадр/с, найчіткіша"), res: 4, fps: 60, bitrate: 25000 }
    ]
    function qualityNow() {
        const r = Chiaki.settings.resolutionRemotePS5, f = Chiaki.settings.fpsRemotePS5;
        return r <= 2 ? "eco" : r >= 4 ? "max" : (f >= 60 ? "opt" : "eco");
    }
    function setQuality(q) {
        if (qualityNow() === q.id) { goMain(); return; }
        Chiaki.settings.resolutionRemotePS5 = q.res; Chiaki.settings.fpsRemotePS5 = q.fps; Chiaki.settings.bitrateRemotePS5 = q.bitrate;
        Chiaki.settings.resolutionLocalPS5 = q.res;  Chiaki.settings.fpsLocalPS5 = q.fps;  Chiaki.settings.bitrateLocalPS5 = q.bitrate;
        Chiaki.cloud.reconnectOnce = true;   // головний екран сам натисне «Грати» з новою якістю
        panel.page = "main";
        panel.exit();
    }

    ColumnLayout {
        anchors { fill: parent; leftMargin: 22; rightMargin: 22; topMargin: 14; bottomMargin: 14 }
        spacing: 10

        // ── шапка: назва сторінки, скільки лишилось, зв'язок ──
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            MenuBtn {
                id: backBtn
                visible: panel.page !== "main"
                Layout.preferredHeight: 40
                font.pixelSize: 15
                text: qsTr("← Назад")
                onClicked: panel.goMain()
                Keys.onEscapePressed: panel.goMain()
            }
            Label {
                text: panel.page === "extend" ? qsTr("ПРОДОВЖИТИ ГРУ") : panel.page === "keys" ? qsTr("КЛАВІШІ")
                    : panel.page === "console" ? qsTr("КЕРУВАННЯ ПРИСТАВКОЮ")
                    : panel.page === "quality" ? qsTr("ЯКІСТЬ КАРТИНКИ") : qsTr("МЕНЮ ГРИ")
                color: "#22e4ff"; font.pixelSize: 15; font.bold: true; font.letterSpacing: 3
            }
            Label {
                text: panel.leftText()
                color: "#ffd23f"; font.pixelSize: 17; font.bold: true
            }
            Item { Layout.fillWidth: true }
            Label {
                visible: !!Chiaki.session
                color: "#bfaed8"; font.pixelSize: 13
                text: Chiaki.session ? qsTr("Зв'язок: %1 Мбіт/с, втрати %2%").arg(Chiaki.session.measuredBitrate.toFixed(1))
                    .arg((((isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
            }
        }

        // ── головна сторінка ──
        RowLayout {
            visible: panel.page === "main"
            Layout.fillWidth: true
            spacing: 12
            MenuBtn {
                id: resumeBtn
                primary: true
                iconName: "play"
                text: qsTr("Повернутись у гру")
                onClicked: panel.resume()
                KeyNavigation.right: extendBtn
            }
            MenuBtn {
                id: extendBtn
                iconName: "clock"
                text: qsTr("Продовжити гру")
                onClicked: { panel.page = "extend"; backBtn.forceActiveFocus(); }
                KeyNavigation.left: resumeBtn
                KeyNavigation.right: keysBtn
            }
            MenuBtn {
                id: keysBtn
                iconName: "keyboard"
                text: qsTr("Клавіші")
                onClicked: { panel.page = "keys"; backBtn.forceActiveFocus(); }
                KeyNavigation.left: extendBtn
                KeyNavigation.right: qualityBtn
            }
            MenuBtn {
                id: qualityBtn
                iconName: "quality"
                text: qsTr("Якість")
                onClicked: { panel.page = "quality"; backBtn.forceActiveFocus(); }
                KeyNavigation.left: keysBtn
                KeyNavigation.right: volume
            }
            ColumnLayout {
                Layout.leftMargin: 10
                spacing: 0
                Label { text: qsTr("Гучність: %1%").arg(((volume.value / 128.0) * 100).toFixed(0)); color: "white"; font.pixelSize: 14 }
                Slider {
                    id: volume
                    Layout.preferredWidth: 190
                    from: 0; to: 128; stepSize: 1
                    value: Chiaki.settings.audioVolume
                    onMoved: Chiaki.settings.audioVolume = value
                    KeyNavigation.left: qualityBtn
                    KeyNavigation.right: exitBtn
                    Keys.onEscapePressed: panel.resume()
                }
            }
            Item { Layout.fillWidth: true }
            MenuBtn {
                id: exitBtn
                danger: true
                iconName: "exit"
                text: qsTr("Вийти з гри")
                onClicked: panel.exit()
                KeyNavigation.left: volume
            }
        }
        Label {
            visible: panel.page === "main"
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            color: "#d8cdea"; font.pixelSize: 14
            text: qsTr("Закрити це меню — Esc або %1.  «Вийти з гри» закриває трансляцію: повернутись можна будь-коли до кінця броні (час броні при цьому йде).  Як відкрити меню приставки, закрити гру чи запустити іншу: кнопка «Клавіші».").arg(panel.menuKey)
        }
        Flow {   // найпотрібніші клавіші одразу на головній сторінці
            visible: panel.page === "main"
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: panel.visible && panel.page === "main" ? panel.keyRows().slice(1, 6) : []
                KeyChip { required property var modelData; keyText: modelData.key; name: modelData.name }
            }
        }

        // ── продовження гри ──
        ExtendPanel {
            visible: panel.visible && panel.page === "extend"
            Layout.fillWidth: true
            compact: true
        }

        // ── якість картинки: змінюється з перепідключенням на кілька секунд ──
        Label {
            visible: panel.page === "quality"
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            color: "#d8cdea"; font.pixelSize: 14
            text: qsTr("Якщо картинка смикається чи сиплеться, обери нижчу якість. Гра перепідключиться сама за кілька секунд, прогрес у грі не зникає.")
        }
        RowLayout {
            visible: panel.page === "quality"
            Layout.fillWidth: true
            spacing: 10
            Repeater {
                model: panel.qualities
                MenuBtn {
                    required property var modelData
                    readonly property bool on: panel.qualityNow() === modelData.id
                    Layout.fillWidth: true
                    Layout.preferredHeight: 62
                    primary: on
                    text: (on ? "✓ " : "") + modelData.name + "\n" + modelData.info
                    font.pixelSize: 14
                    onClicked: panel.setQuality(modelData)
                }
            }
        }

        // ── клавіші ──
        Label {
            visible: panel.page === "keys" && Chiaki.controllers.length > 0
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            color: "#ffd23f"; font.pixelSize: 14; font.bold: true
            text: qsTr("Підключено геймпад: грай ним, як на приставці. Клавіатура й мишка теж працюють: програма сама перемикається на те, чим ти щойно натиснув.")
        }
        Flow {
            visible: panel.page === "keys"
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: panel.visible && panel.page === "keys" ? panel.keyRows() : []
                KeyChip { required property var modelData; keyText: modelData.key; name: modelData.name }
            }
        }
        Label {
            visible: panel.page === "keys"
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            color: "#d8cdea"; font.pixelSize: 14
            text: qsTr("Рух — W A S D, камера — мишка, стрільба — ліва кнопка миші. Усі клавіші та їх зміна: головний екран програми → «Клавіші».")
        }
        MenuBtn {
            visible: panel.page === "keys"
            Layout.preferredHeight: 46
            font.pixelSize: 15
            iconName: "gamepad"
            text: qsTr("Керування приставкою: меню PS, закрити гру, запустити іншу  →")
            onClicked: { panel.page = "console"; backBtn.forceActiveFocus(); }
        }

        // ── керування самою приставкою ──
        Flickable {   // якщо вікно вузьке й текст не влазить — прокручується колесом миші
            visible: panel.page === "console"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: consoleGuide.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }
            AnyPlayGuide {
                id: consoleGuide
                width: parent.width
                compact: true
                menuKey: panel.menuKey
            }
        }
        Item { visible: panel.page !== "console"; Layout.fillHeight: true }
    }

    component KeyChip: Rectangle {
        property string keyText
        property string name
        radius: 10; color: "#1f1240"; border.color: "#22ffffff"
        implicitWidth: chipRow.implicitWidth + 20; implicitHeight: 34
        RowLayout {
            id: chipRow
            anchors.centerIn: parent
            spacing: 8
            Rectangle {
                radius: 6; color: "#3a1a6e"; border.color: "#22e4ff"
                implicitWidth: cap.implicitWidth + 14; implicitHeight: 24
                Label { id: cap; anchors.centerIn: parent; text: keyText; color: "white"; font.pixelSize: 13; font.bold: true }
            }
            Label { text: name; color: "white"; font.pixelSize: 13 }
        }
    }

    component MenuBtn: Button {
        id: mb
        property bool primary: false
        property bool danger: false
        property string iconName: ""
        Layout.preferredHeight: 58
        font.pixelSize: 17
        font.bold: true
        leftPadding: 22; rightPadding: 22
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        Keys.onEscapePressed: panel.resume()
        contentItem: Item {
            implicitWidth: mbRow.implicitWidth
            implicitHeight: mbRow.implicitHeight
            Row {
                id: mbRow
                anchors.centerIn: parent
                spacing: 10
                Image {
                    visible: mb.iconName !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    width: mb.primary ? 0 : 24; height: 24
                    source: mb.iconName !== "" && !mb.primary ? "qrc:/icons/ap-" + mb.iconName + ".svg" : ""
                    sourceSize: Qt.size(48, 48)
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (mb.primary && mb.iconName === "play" ? "▶  " : "") + mb.text; font: mb.font; color: "white"
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
        background: Rectangle {
            radius: 16
            color: mb.danger ? (mb.hovered ? "#66ff4d6d" : "#33ff4d6d") : (mb.hovered ? "#44ffffff" : "#26ffffff")
            border.color: mb.activeFocus ? "#22e4ff" : (mb.danger ? "#ff4d6d" : "#33ffffff")
            border.width: mb.activeFocus ? 2 : 1
            gradient: mb.primary ? mbGradient : null
            Gradient {
                id: mbGradient
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#ff9a3c" }
                GradientStop { position: 0.5; color: "#ff2e9a" }
                GradientStop { position: 1.0; color: "#7b2cff" }
            }
        }
    }
}
