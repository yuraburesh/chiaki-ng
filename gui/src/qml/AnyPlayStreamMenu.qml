// AnyPlay: меню під час гри для клієнта, у стилі паузи GTA.
// Ліворуч пункти великими літерами, праворуч вміст обраного пункту; угорі скільки лишилось, унизу зв'язок.
// Пункти: повернутись у гру, продовжити гру, клавіші, якість, керування приставкою, вийти з гри.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: panel
    property string page: "back"     // back | extend | keys | quality | console | exit
    property string openPage: ""     // з якої сторінки відкрити меню (нагадування про кінець гри відкриває «Продовжити гру»)
    property int tick: 0
    // меню відкривається клавішею ` (під Esc); Ctrl+O / Cmd+O теж працює, але не показуємо: Ctrl у GTA — «присісти»
    readonly property string menuKey: Chiaki.controllers.length
        ? qsTr("клавіша ` (під Esc) або %1 на геймпаді").arg(Chiaki.settings.stringForStreamMenuShortcut())
        : qsTr("клавіша ` (під Esc)")
    signal resume()   // закрити меню й повернутись у гру
    signal exit()     // завершити трансляцію
    // з чого почати фокус, коли меню відкрилось (з нагадування про кінець гри — одразу «Продовжити гру»)
    readonly property Item firstItem: openPage === "extend" ? extendBtn : resumeBtn
    AnyPlayStyle { id: ap }

    readonly property var items: [resumeBtn, extendBtn, keysBtn, qualityBtn, consoleBtn, exitBtn]
    function itemFor(p) {
        for (let i = 0; i < items.length; i++)
            if (items[i].pageId === p)
                return items[i];
        return resumeBtn;
    }
    function focusFirst() { itemFor(page).forceActiveFocus(Qt.TabFocusReason); }
    function goMain() { page = "back"; resumeBtn.forceActiveFocus(); }
    // перейти з лівого стовпця у вміст праворуч (Enter або →)
    function enterContent() {
        const target = page === "exit" ? exitConfirm : (page === "quality" ? qualityList.firstOpt : (page === "extend" ? extendPanel.firstOption
                     : (page === "keys" ? keysLoader.item : null)));
        if (target && target.visible && target.enabled)
            target.forceActiveFocus(Qt.TabFocusReason);
        else {
            const next = itemFor(page).nextItemInFocusChain(true);
            if (next && next !== itemFor(page))
                next.forceActiveFocus(Qt.TabFocusReason);
        }
    }
    onVisibleChanged: {
        if (visible)
            page = openPage !== "" ? openPage : "back";
        else
            page = "back";
    }
    Keys.onEscapePressed: panel.resume()

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
    property int layoutRev: 0
    // чи є клавіші режимів (пішки, транспорт, літак) — для підказки про Fn на MacBook
    readonly property bool hasModes: {
        layoutRev;
        const profiles = Chiaki.settings.anyplayProfiles();
        for (let i = 0; i < profiles.length; i++)
            if (profiles[i].id === "global")
                for (let j = 0; j < profiles[i].bindings.length; j++)
                    if (profiles[i].bindings[j].id.indexOf("mode_") === 0)
                        return true;
        return false;
    }
    function keyRows() {
        layoutRev;
        const labels = { pause: qsTr("OPTIONS: пауза й меню в самій грі"), ps: qsTr("кнопка PS: меню приставки"), map: qsTr("тачпад: карта") };
        let rows = [{ name: qsTr("меню AnyPlay"), key: "`" }];
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
                    rows.push({ name: qsTr("сісти в транспорт чи вийти"), key: key });
            }
        }
        return rows.concat(modes);
    }

    // Ті самі рівні якості, що й на головному екрані
    readonly property var levelNames: [qsTr("Економна"), qsTr("Оптимальна"), qsTr("Максимальна"), qsTr("Ультра")]
    readonly property var qualities: [
        { level: -1, name: qsTr("Авто"), info: qsTr("сама підбирає, зараз: %1").arg(levelNames[Chiaki.cloud.qualityLevel] || "") },
        { level: 0, name: levelNames[0], info: qsTr("540p, 30 кадр/с") },
        { level: 1, name: levelNames[1], info: qsTr("720p, 60 кадр/с") },
        { level: 2, name: levelNames[2], info: qsTr("1080p, 60 кадр/с") },
        { level: 3, name: levelNames[3], info: qsTr("1080p, 60 кадр/с і ШІ-чіткість на великому екрані") }
    ]
    function qualityOn(q) { return q.level < 0 ? Chiaki.cloud.autoQuality : (!Chiaki.cloud.autoQuality && Chiaki.cloud.qualityLevel === q.level); }
    function setQuality(q) {
        if (q.level < 0) { Chiaki.cloud.autoQuality = true; goMain(); return; }   // «Авто» лишає поточний рівень і далі стежить сама
        const same = Chiaki.cloud.qualityLevel === q.level;
        Chiaki.cloud.autoQuality = false;
        if (same) { goMain(); return; }
        // «Максимальна» і «Ультра» відрізняються лише обробкою на ноутбуці: міняємо одразу, без перепідключення
        if (Chiaki.cloud.qualityLevel >= 2 && q.level >= 2) { Chiaki.cloud.setQualityLevel(q.level); goMain(); return; }
        Chiaki.cloud.setQualityLevel(q.level);
        Chiaki.cloud.reconnectOnce = true;   // головний екран сам натисне «Грати» з новою якістю
        panel.page = "back";
        panel.exit();
    }

    // ── фон: гра видно праворуч, ліворуч темніше ──
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            // гра під меню лише ледь проглядає: інакше текст зливається з яскравою картинкою
            GradientStop { position: 0.0; color: "#f70d0a16" }
            GradientStop { position: 0.5; color: "#f00d0a16" }
            GradientStop { position: 1.0; color: "#e00d0a16" }
        }
    }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (wheel) => wheel.accepted = true }

    Item {
        id: zoom
        readonly property real k: Math.max(1, Math.min(2.2, Math.min(panel.width / 1600, panel.height / 1000)))
        width: panel.width / k
        height: panel.height / k
        scale: k
        transformOrigin: Item.TopLeft

        ColumnLayout {
            anchors { fill: parent; leftMargin: zoom.width < 900 ? 20 : 32; rightMargin: anchors.leftMargin; topMargin: zoom.height < 640 ? 16 : 28; bottomMargin: zoom.height < 640 ? 12 : 22 }
            spacing: 0

            // ── шапка ──
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                spacing: 20
                Text {
                    text: qsTr("Пауза AnyPlay")
                    font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: zoom.height < 640 ? 24 : 30
                    font.letterSpacing: 2; font.capitalization: Font.AllUppercase
                    color: ap.ink
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                ApText { role: "eyebrow"; text: panel.leftText() }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: zoom.height < 640 ? 12 : 22
                Layout.bottomMargin: 12
                spacing: zoom.width < 1000 ? 32 : 56

                // ── ліворуч: пункти меню ──
                ColumnLayout {
                    readonly property real w: Math.max(220, Math.min(300, zoom.width * 0.26))
                    Layout.fillWidth: false
                    Layout.preferredWidth: w
                    Layout.maximumWidth: w
                    Layout.alignment: Qt.AlignTop
                    spacing: 0
                    PauseItem { id: resumeBtn; pageId: "back"; text: qsTr("Повернутись у гру"); KeyNavigation.down: extendBtn }
                    PauseItem { id: extendBtn; pageId: "extend"; text: qsTr("Продовжити гру"); KeyNavigation.up: resumeBtn; KeyNavigation.down: keysBtn }
                    PauseItem { id: keysBtn; pageId: "keys"; text: qsTr("Клавіші"); KeyNavigation.up: extendBtn; KeyNavigation.down: qualityBtn }
                    PauseItem { id: qualityBtn; pageId: "quality"; text: qsTr("Якість"); KeyNavigation.up: keysBtn; KeyNavigation.down: consoleBtn }
                    PauseItem { id: consoleBtn; pageId: "console"; text: qsTr("Керування приставкою"); KeyNavigation.up: qualityBtn; KeyNavigation.down: homeBtn }
                    PauseItem { id: homeBtn; pageId: "home"; text: qsTr("Головне вікно AnyPlay"); KeyNavigation.up: consoleBtn; KeyNavigation.down: exitBtn }
                    PauseItem { id: exitBtn; pageId: "exit"; danger: true; text: qsTr("Вийти з гри"); KeyNavigation.up: homeBtn }
                }

                // ── праворуч: вміст обраного пункту ──
                Item {
                    id: content
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // повернутись у гру: гра не на паузі, гучність, головні клавіші
                    PageFlick {
                        visible: panel.page === "back"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; text: qsTr("Гра на паузі не стоїть") }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                role: "lead"
                                text: qsTr("Поки відкрите це меню, гра на приставці йде далі. Повернись пунктом ліворуч або клавішею Esc. Меню AnyPlay: %1.").arg(panel.menuKey)
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.maximumWidth: 620
                                Layout.topMargin: 4
                                spacing: 14
                                ApText { role: "cap"; text: qsTr("Гучність") }
                                Slider {
                                    id: volume
                                    Layout.fillWidth: true
                                    from: 0; to: 128; stepSize: 1
                                    value: Chiaki.settings.audioVolume
                                    onMoved: Chiaki.settings.audioVolume = value
                                    KeyNavigation.left: resumeBtn
                                    background: Rectangle {
                                        x: volume.leftPadding
                                        y: volume.topPadding + volume.availableHeight / 2 - height / 2
                                        width: volume.availableWidth
                                        height: 2
                                        color: "#40ffffff"
                                        Rectangle { width: volume.visualPosition * parent.width; height: parent.height; color: ap.ink }
                                    }
                                    handle: Rectangle {
                                        x: volume.leftPadding + volume.visualPosition * (volume.availableWidth - width)
                                        y: volume.topPadding + volume.availableHeight / 2 - height / 2
                                        width: 14; height: 14; radius: 7
                                        color: ap.ink
                                        border.width: volume.visualFocus ? 2 : 0
                                        border.color: ap.cyan
                                    }
                                }
                                ApChip { text: ((volume.value / 128.0) * 100).toFixed(0) + "%" }
                            }
                            ApText { role: "cap"; text: qsTr("Головні клавіші"); Layout.topMargin: 10 }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                Repeater {
                                    model: panel.visible && panel.page === "back" ? panel.keyRows() : []
                                    Row {
                                        required property var modelData
                                        spacing: 6
                                        height: 24
                                        rightPadding: 10
                                        ApChip { anchors.verticalCenter: parent.verticalCenter; key: true; text: modelData.key }
                                        ApText { anchors.verticalCenter: parent.verticalCenter; role: "small"; color: ap.mute; wrapMode: Text.NoWrap; text: modelData.name }
                                    }
                                }
                            }
                            ApText {
                                visible: Qt.platform.os === "osx" && panel.hasModes
                                Layout.fillWidth: true
                                role: "small"
                                text: qsTr("На MacBook клавіші F1, F2, F3 натискай разом з Fn: Fn + F1.")
                            }
                        }
                    }

                    // продовжити гру
                    PageFlick {
                        visible: panel.page === "extend"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; text: qsTr("Продовжити гру") }
                            ExtendPanel {
                                id: extendPanel
                                Layout.fillWidth: true
                                Layout.maximumWidth: 720
                                compact: true
                                visible: panel.visible && panel.page === "extend"
                            }
                        }
                    }

                    // клавіші: екран керування з геймпадом (компактний варіант для гри)
                    // (фокус лишається на пунктах ліворуч; у клавіші — клацом, Enter чи →; Esc там закриває меню, як і всюди)
                    Loader {
                        id: keysLoader
                        anchors.fill: parent
                        // вміст — рівно по краях інших сторінок, смуга прокрутки — праворуч за ним, з відступом
                        anchors.leftMargin: -14
                        anchors.rightMargin: -14
                        active: panel.visible && panel.page === "keys"
                        visible: active
                        sourceComponent: Component {
                            AnyPlayControls {
                                inGame: true
                                sideInset: 14
                                onCloseRequested: panel.resume()
                            }
                        }
                    }

                    // якість картинки: змінюється з перепідключенням на кілька секунд
                    PageFlick {
                        visible: panel.page === "quality"
                        ColumnLayout {
                            id: qualityList
                            readonly property Item firstOpt: qualityRepeater.count > 0 ? qualityRepeater.itemAt(0) : null
                            width: content.width
                            spacing: 0
                            ApText { role: "cap"; text: qsTr("Якість картинки"); Layout.bottomMargin: 6 }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                Layout.bottomMargin: 8
                                role: "hint"
                                text: qsTr("«Авто» сама знижує якість, коли зв'язок слабшає, щоб гра не відставала. Якщо обереш рівень сам, гра перепідключиться за кілька секунд, прогрес у грі не зникає.")
                            }
                            Repeater {
                                id: qualityRepeater
                                model: panel.qualities
                                ApOpt {
                                    required property var modelData
                                    Layout.maximumWidth: 620
                                    text: modelData.name
                                    sub: modelData.info
                                    checked: panel.qualityOn(modelData)
                                    onClicked: panel.setQuality(modelData)
                                    KeyNavigation.left: qualityBtn
                                }
                            }
                        }
                    }

                    // керування самою приставкою
                    PageFlick {
                        visible: panel.page === "console"
                        ColumnLayout {
                            width: content.width
                            spacing: 6
                            ApText { role: "cap"; text: qsTr("Керування приставкою") }
                            AnyPlayGuide {
                                Layout.fillWidth: true
                                columns: content.width >= 900 ? 2 : 1
                                columnSpacing: 40
                                compact: true
                                menuKey: panel.menuKey
                            }
                        }
                    }

                    // вийти з гри
                    PageFlick {
                        visible: panel.page === "exit"
                        ColumnLayout {
                            width: content.width
                            spacing: 12
                            ApText { role: "cap"; color: ap.bad; text: qsTr("Вийти з гри") }
                            ApText {
                                Layout.fillWidth: true; Layout.maximumWidth: 620
                                role: "lead"; rich: true
                                text: Chiaki.cloud.endTs > 0
                                    ? qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до <b>%1</b>.").arg(Chiaki.cloud.formatTime(Chiaki.cloud.endTs))
                                    : qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до кінця броні.")
                            }
                            Flow {
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                spacing: 10
                                ApButton {
                                    id: exitConfirm
                                    focusPolicy: Qt.StrongFocus
                                    text: qsTr("Вийти з гри")
                                    onClicked: panel.exit()
                                    KeyNavigation.left: exitBtn
                                    KeyNavigation.right: stayBtn
                                }
                                ApButton {
                                    id: stayBtn
                                    focusPolicy: Qt.StrongFocus
                                    ghost: true
                                    height: exitConfirm.height
                                    text: qsTr("Залишитись")
                                    onClicked: panel.goMain()
                                    KeyNavigation.left: exitConfirm
                                }
                            }
                        }
                    }
                }
            }

            // ── підвал: зв'язок і як закрити меню ──
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 10
                spacing: 20
                FootText {
                    text: Chiaki.session ? qsTr("Зв'язок %1 Мбіт/с, втрати %2%").arg(Chiaki.session.measuredBitrate.toFixed(1).replace(".", ","))
                        .arg(((isFinite(Chiaki.session.averagePacketLoss) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1).replace(".", ",")) : ""
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                FootText { text: qsTr("Закрити меню: Esc або `") }
            }
        }
    }

    component FootText: Text {
        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 12
        font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
        color: ap.faint
    }

    // сторінка праворуч: прокручується, якщо вікно низьке
    // ── головне вікно AnyPlay поверх гри: бронювання, баланс, PSN, не виходячи з гри (трансляція йде далі) ──
    Loader {
        id: homeOver
        anchors.fill: parent
        z: 50
        active: panel.page === "home" && panel.visible
        sourceComponent: AnyPlayHome {
            overGame: true
            onBackToGame: { panel.page = "back"; panel.resume(); }
            onBackToMenu: panel.page = "back"
        }
        onLoaded: item.forceActiveFocus()
    }

    component PageFlick: Flickable {
        id: pf
        default property alias body: pfInner.data
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: pfInner.childrenRect.height + 8
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
            policy: pf.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
        }
        Item { id: pfInner; width: pf.width; height: childrenRect.height }
    }

    // пункт ліворуч: великі літери, обраний — з підсвіткою і відступом
    component PauseItem: Item {
        id: pi
        property string pageId
        property string text
        property bool danger: false
        readonly property bool current: panel.page === pageId
        Layout.fillWidth: true
        implicitHeight: piText.implicitHeight + (zoom.height < 640 ? 18 : 26)
        activeFocusOnTab: true
        onActiveFocusChanged: if (activeFocus) panel.page = pageId
        function activate() {
            if (pageId === "back") panel.resume();
            else { panel.page = pageId; panel.enterContent(); }
        }
        Keys.onReturnPressed: activate()
        Keys.onEnterPressed: activate()
        Keys.onSpacePressed: activate()
        Keys.onRightPressed: if (pageId !== "back") activate()
        Rectangle {
            anchors.fill: parent
            visible: pi.current
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#1fffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
            }
        }
        Rectangle {   // фокус з клавіатури чи геймпада
            visible: pi.activeFocus
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 2
            color: ap.cyan
        }
        Text {
            id: piText
            anchors { left: parent.left; leftMargin: pi.current ? 12 : 4; right: parent.right; verticalCenter: parent.verticalCenter }
            text: pi.text
            elide: Text.ElideRight
            font.family: ap.display; font.weight: Font.Medium; font.pixelSize: zoom.height < 640 ? 15 : 17
            font.letterSpacing: 1.8; font.capitalization: Font.AllUppercase
            color: pi.danger ? ap.bad : ap.ink
            opacity: pi.current || piMouse.containsMouse || pi.activeFocus ? 1 : 0.6
            Behavior on anchors.leftMargin { NumberAnimation { duration: 120 } }
        }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: ap.hair }
        MouseArea {
            id: piMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { pi.forceActiveFocus(); if (pi.pageId === "back") panel.resume(); else panel.page = pi.pageId; }
        }
    }
}
