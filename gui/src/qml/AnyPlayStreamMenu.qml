// AnyPlay: меню під час гри, у стилі паузи GTA. Одне й те саме для клієнта й адміна.
// Ліворуч пункти великими літерами, праворуч вміст обраного пункту; угорі скільки лишилось, унизу зв'язок.
// Пункти: повернутись у гру, продовжити бронювання, клавіші, якість, керування приставкою, головне вікно, вийти з гри.
// Адмін: без «Продовжити бронювання», зате з пунктом «Розширені налаштування» (усе, що було в стандартному меню трансляції:
// вигляд картинки на екрані, обробка картинки, мікрофон, налаштування екрана, дані трансляції) і з вибором,
// чи переводити приставку в режим спокою, коли виходить з гри.
// Гість (cloud.guest): без «Продовжити бронювання», угорі замість часу броні — гостьовий доступ.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: panel
    property string page: "back"     // back | extend | keys | quality | picture | console | home | advanced | exit
    readonly property bool admin: Chiaki.cloud.admin === true
    readonly property bool guest: !admin && Chiaki.cloud.guest === true
    readonly property bool canExtend: !admin && !guest   // продовжувати бронювання може лише клієнт зі своєю бронню
    property string openPage: ""     // з якої сторінки відкрити меню (нагадування про кінець гри відкриває «Продовжити гру»)
    property int tick: 0
    // меню відкривається клавішею ` (під Esc); Ctrl+O / Cmd+O теж працює, але не показуємо: Ctrl у GTA — «присісти»
    readonly property string menuKey: Chiaki.controllers.length
        ? qsTr("клавіша ` (під Esc) або %1 на геймпаді").arg(Chiaki.settings.stringForStreamMenuShortcut())
        : qsTr("клавіша ` (під Esc)")
    signal resume()   // закрити меню й повернутись у гру
    signal exit()     // завершити трансляцію
    // з чого почати фокус, коли меню відкрилось (з нагадування про кінець гри — одразу «Продовжити гру»)
    readonly property Item firstItem: openPage === "extend" && canExtend ? extendBtn : resumeBtn
    AnyPlayStyle { id: ap }

    readonly property var items: [resumeBtn, extendBtn, keysBtn, qualityBtn, pictureBtn, consoleBtn, homeBtn, walletBtn, supportBtn, advBtn, exitBtn]
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
                     : (page === "keys" ? keysLoader.item : (page === "advanced" ? advFirst : (page === "picture" ? picturePanel.firstControl : null)))));
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
            page = openPage !== "" && (openPage !== "extend" || canExtend) ? openPage : "back";
        else
            page = "back";
    }
    Keys.onEscapePressed: panel.resume()

    Timer { interval: 1000; repeat: true; running: panel.visible; onTriggered: panel.tick++ }

    function leftText() {
        tick;
        if (panel.admin) {   // адмін грає без броні: показуємо, чий зараз час на приставці
            const a = Chiaki.cloud.adminInfo || ({});
            if (a.current)
                return qsTr("Режим адміна. Зараз час броні: %1, до %2").arg(a.current.user).arg(Chiaki.cloud.formatTime(a.current.end));
            const n = a.next || [];
            return n.length ? qsTr("Режим адміна. Наступна бронь: %1 о %2").arg(n[0].user).arg(Chiaki.cloud.formatTime(n[0].start)) : qsTr("Режим адміна");
        }
        const sec = Math.floor(Chiaki.cloud.endTs - Date.now() / 1000 - Chiaki.cloud.clockSkew);
        if (!(Chiaki.cloud.endTs > 0) || sec <= 0)
            return panel.guest ? qsTr("Гостьовий доступ") : "";
        const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), x = sec % 60;
        const left = (h ? h + ":" : "") + String(m).padStart(h ? 2 : 1, "0") + ":" + String(x).padStart(2, "0");
        if (panel.guest)   // гість грає до початку найближчої чужої гри; якщо броней попереду немає, кінця не показуємо
            return sec > 11 * 3600 ? qsTr("Гостьовий доступ: приставка вільна")
                                   : qsTr("Гостьовий доступ до %1, лишилось %2").arg(Chiaki.cloud.formatTime(Chiaki.cloud.endTs)).arg(left);
        return qsTr("Лишилось %1, гра до %2").arg(left).arg(Chiaki.cloud.formatTime(Chiaki.cloud.endTs));
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
        if (panel.admin && Chiaki.session)
            Chiaki.stopSession(false);       // адміну закриття вікна показало б питання про режим спокою: закриваємо лише трансляцію
        else
            panel.exit();
    }
    // ── розширені налаштування (адмін): те, що було в стандартному меню трансляції ──
    readonly property var videoPresets: [
        { id: ChiakiWindow.VideoPreset.Default, name: qsTr("Стандартна") },
        { id: ChiakiWindow.VideoPreset.HighQuality, name: qsTr("Висока якість") },
        { id: ChiakiWindow.VideoPreset.HighQualitySpatial, name: qsTr("Висока якість і ШІ-чіткість") },
        { id: ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial, name: qsTr("Висока якість і посилена ШІ-чіткість") }
    ]
    function setVideoPreset(id) {
        Chiaki.window.videoPreset = id;
        Chiaki.settings.videoPreset = id;
    }
    function setVideoMode(mode) { Chiaki.window.videoMode = mode; }
    function zoomText(v) { return v <= -1 ? qsTr("без чорних смуг") : qsTr("%1 x").arg((v >= 0 ? v + 1 : v).toFixed(2).replace(".", ",")); }
    function num1(x) { return (isFinite(x) ? x : 0).toFixed(1).replace(".", ","); }
    function streamChips() {
        const s = Chiaki.session, w = Chiaki.window;
        if (!s) return [];
        const out = [];
        if (s.host && !Chiaki.settings.streamerMode)
            out.push({ text: (s.connected ? qsTr("підключено до %1") : qsTr("підключення до %1")).arg(s.host), kind: s.connected ? "ok" : "wait" });
        out.push({ text: qsTr("з приставки %1 кадр/с").arg(w.streamFps) });
        out.push({ text: qsTr("на екрані %1 кадр/с").arg(w.shownFps) });
        // перші секунди гри чесного виміру швидкості ще немає
        out.push({ text: s.measuredBitrateReady === false ? qsTr("швидкість: вимірюю…") : qsTr("%1 Мбіт/с").arg(num1(s.measuredBitrate)) });
        const loss = (isFinite(s.averagePacketLoss) ? s.averagePacketLoss : 0) * 100;
        out.push({ text: qsTr("втрати пакетів %1%").arg(num1(loss)), kind: loss > 2 ? "bad" : loss > 0.5 ? "wait" : "" });
        if (w.droppedFrames > 0)
            out.push({ text: qsTr("пропущено кадрів за секунду: %1").arg(w.droppedFrames), kind: "wait" });
        if (s.framesLost > 0)
            out.push({ text: qsTr("втрачено кадрів у мережі: %1").arg(s.framesLost) });
        return out;
    }

    // ── фон: ніч Vice City — гра ледь проглядає крізь темне скло, знизу світіння заходу сонця ──
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            // гра під меню лише ледь проглядає: інакше текст зливається з яскравою картинкою
            GradientStop { position: 0.0; color: "#f714091f" }
            GradientStop { position: 0.45; color: "#ee150a22" }
            GradientStop { position: 1.0; color: "#d8180b26" }
        }
    }
    Rectangle {   // світіння обрію: рожево-помаранчеве знизу
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.55
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#00ff4f8b" }
            GradientStop { position: 0.75; color: "#24ff4f8b" }
            GradientStop { position: 1.0; color: "#40ff8a3d" }
        }
    }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (wheel) => wheel.accepted = true }

    Item {
        id: zoom
        readonly property real k: Math.max(1, Math.min(2.2, Math.min(panel.width / 1600, panel.height / 1000)))
        readonly property bool low: height < 780          // 1280×720, 1366×768: щільніші пункти, щоб усе вмістилось без прокрутки
        width: panel.width / k
        height: panel.height / k
        scale: k
        transformOrigin: Item.TopLeft

        ColumnLayout {
            anchors { fill: parent; leftMargin: zoom.width < 900 ? 20 : 32; rightMargin: anchors.leftMargin; topMargin: zoom.low ? 16 : 28; bottomMargin: zoom.low ? 12 : 22 }
            spacing: 0

            // ── шапка ──
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                spacing: 20
                Column {
                    spacing: 6
                    Text {
                        text: qsTr("Пауза")
                        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: zoom.low ? 30 : 40
                        font.letterSpacing: 3; font.capitalization: Font.AllUppercase
                        color: ap.ink
                    }
                    Rectangle {   // смужка заходу сонця під заголовком
                        width: 64; height: 3; radius: 2
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                    }
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                // скільки лишилось: золота пігулка
                Rectangle {
                    visible: timeText.text !== ""
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: timeText.implicitWidth + 28
                    implicitHeight: timeText.implicitHeight + 14
                    radius: height / 2
                    color: ap.glass
                    border.width: 1; border.color: panel.admin ? ap.edge : "#66ffd27a"
                    Text {
                        id: timeText
                        anchors.centerIn: parent
                        text: panel.leftText()
                        color: panel.admin ? ap.mute : ap.gold
                        font.family: ap.display; font.weight: Font.Medium; font.pixelSize: zoom.low ? 14 : 16
                        font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: zoom.low ? 20 : 30
                Layout.bottomMargin: zoom.low ? 18 : 22
                spacing: zoom.width < 1000 ? 40 : 56

                // ── ліворуч: пункти меню ──
                ColumnLayout {
                    readonly property real w: Math.max(230, Math.min(320, zoom.width * 0.25))
                    Layout.fillWidth: false
                    Layout.preferredWidth: w
                    Layout.maximumWidth: w
                    Layout.alignment: Qt.AlignTop
                    spacing: zoom.low ? 3 : 6
                    PauseItem { id: resumeBtn; pageId: "back"; text: qsTr("Повернутись у гру"); KeyNavigation.down: extendBtn }
                    PauseItem { id: extendBtn; pageId: "extend"; visible: panel.canExtend; text: qsTr("Продовжити бронювання"); KeyNavigation.up: resumeBtn; KeyNavigation.down: keysBtn }
                    PauseItem { id: keysBtn; pageId: "keys"; text: qsTr("Клавіші"); KeyNavigation.up: extendBtn; KeyNavigation.down: qualityBtn }
                    PauseItem { id: qualityBtn; pageId: "quality"; text: qsTr("Якість"); KeyNavigation.up: keysBtn; KeyNavigation.down: pictureBtn }
                    PauseItem { id: pictureBtn; pageId: "picture"; text: qsTr("Картинка"); KeyNavigation.up: qualityBtn; KeyNavigation.down: consoleBtn }
                    PauseItem { id: consoleBtn; pageId: "console"; text: qsTr("Керування приставкою"); KeyNavigation.up: pictureBtn; KeyNavigation.down: homeBtn }
                    PauseItem { id: homeBtn; pageId: "home"; text: panel.admin ? qsTr("Панель адміна") : qsTr("Головне вікно AnyPlay"); KeyNavigation.up: consoleBtn; KeyNavigation.down: walletBtn }
                    // AnyPlay 110: баланс і підтримка, не виходячи з гри (відкривається головне вікно на потрібній вкладці)
                    PauseItem { id: walletBtn; pageId: "wallet"; visible: !panel.admin && Chiaki.cloud.hasWallet; text: qsTr("Баланс"); KeyNavigation.up: homeBtn; KeyNavigation.down: supportBtn }
                    PauseItem { id: supportBtn; pageId: "support"; visible: !panel.admin; text: Chiaki.cloud.supportUnread > 0 ? qsTr("Підтримка (%1)").arg(Chiaki.cloud.supportUnread) : qsTr("Підтримка"); KeyNavigation.up: walletBtn; KeyNavigation.down: advBtn }
                    PauseItem { id: advBtn; pageId: "advanced"; visible: panel.admin; text: qsTr("Розширені налаштування"); KeyNavigation.up: supportBtn; KeyNavigation.down: exitBtn }
                    PauseItem { id: exitBtn; pageId: "exit"; danger: true; text: qsTr("Вийти з гри"); KeyNavigation.up: advBtn }
                }

                // ── праворуч: вміст обраного пункту ──
                Item {
                    id: content
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // скляна панель під вмістом (об'єм: світліша смужка вгорі, тінь)
                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: -18; anchors.rightMargin: -18; anchors.topMargin: -16; anchors.bottomMargin: -10
                        radius: ap.cardRadius
                        color: "#5a0c0618"
                        border.width: 1; border.color: ap.cardEdge
                        Rectangle { x: 1; y: 1; width: parent.width - 2; height: 1; color: ap.cardTop }
                    }

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
                                MenuSlider {
                                    id: volume
                                    Layout.fillWidth: true
                                    from: 0; to: 128; stepSize: 1
                                    value: Chiaki.settings.audioVolume
                                    onMoved: Chiaki.settings.audioVolume = value
                                    KeyNavigation.left: resumeBtn
                                }
                                ApChip { text: ((volume.value / 128.0) * 100).toFixed(0) + "%" }
                            }
                            ApOpt {   // «віддача» для клавіатури: краї картинки темніють разом з вібрацією геймпада
                                Layout.fillWidth: true
                                Layout.maximumWidth: 620
                                text: qsTr("Віддача на екрані")
                                sub: Qt.platform.os === "osx"
                                    ? qsTr("Краї екрана темніють, коли в грі трясе, а трекпад ледь відчутно клацає. Лише для клавіатури й миші: геймпад вібрує сам.")
                                    : qsTr("Краї екрана темніють, коли в грі трясе. Лише для клавіатури й миші: геймпад вібрує сам.")
                                checked: Chiaki.settings.anyplayHapticScreen === true
                                onClicked: Chiaki.settings.anyplayHapticScreen = !checked
                                KeyNavigation.left: resumeBtn
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
                            ApText { role: "cap"; text: qsTr("Продовжити бронювання") }
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
                            ApText { role: "cap"; text: qsTr("Індикатор під час гри"); Layout.topMargin: 18; Layout.bottomMargin: 2 }
                            ApOpt {
                                Layout.maximumWidth: 620
                                text: qsTr("Показувати кадри за секунду і зв'язок")
                                sub: qsTr("Маленький рядок у кутку екрана: кадри за секунду, швидкість, втрати, якість")
                                checked: Chiaki.cloud.showStats
                                onClicked: Chiaki.cloud.showStats = !Chiaki.cloud.showStats
                                KeyNavigation.left: qualityBtn
                            }
                        }
                    }

                    // картинка: яскравість, контраст, насиченість, теплота (одразу, без перепідключення)
                    PageFlick {
                        visible: panel.page === "picture"
                        AnyPlayPicture {
                            id: picturePanel
                            width: content.width
                            navLeft: pictureBtn
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

                    // розширені налаштування (лише адмін): те, що було в стандартному меню трансляції
                    PageFlick {
                        visible: panel.page === "advanced" && panel.admin
                        ColumnLayout {
                            width: content.width
                            spacing: 0
                            GridLayout {
                                id: advGrid
                                readonly property bool two: content.width >= 720
                                Layout.fillWidth: true
                                Layout.maximumWidth: 900
                                columns: two ? 2 : 1
                                columnSpacing: 40
                                rowSpacing: 18
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.alignment: Qt.AlignTop
                                    spacing: 0
                                    ApText { role: "cap"; text: qsTr("Картинка на екрані"); Layout.bottomMargin: 4 }
                                    ApOpt {
                                        id: advFirst
                                        text: qsTr("Як є")
                                        sub: qsTr("уся картинка, з чорними смугами, якщо екран іншої форми")
                                        checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Normal
                                        onClicked: panel.setVideoMode(ChiakiWindow.VideoMode.Normal)
                                        KeyNavigation.left: advBtn
                                    }
                                    ApOpt {
                                        text: qsTr("Наблизити")
                                        sub: qsTr("збільшує картинку, краї можуть обрізатись")
                                        checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                                        onClicked: panel.setVideoMode(ChiakiWindow.VideoMode.Zoom)
                                        KeyNavigation.left: advBtn
                                    }
                                    RowLayout {   // наскільки наблизити (лише в режимі «Наблизити»)
                                        visible: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                                        Layout.fillWidth: true
                                        Layout.topMargin: 6
                                        Layout.bottomMargin: 6
                                        spacing: 12
                                        MenuSlider {
                                            id: zoomSlider
                                            Layout.fillWidth: true
                                            from: -1; to: 4; stepSize: 0.01
                                            value: Chiaki.window.ZoomFactor
                                            onMoved: {
                                                Chiaki.window.ZoomFactor = value;
                                                Chiaki.settings.sZoomFactor = value;
                                            }
                                        }
                                        ApChip { text: panel.zoomText(zoomSlider.value) }
                                    }
                                    ApOpt {
                                        text: qsTr("Розтягнути")
                                        sub: qsTr("на весь екран без смуг, пропорції можуть змінитись")
                                        checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Stretch
                                        onClicked: panel.setVideoMode(ChiakiWindow.VideoMode.Stretch)
                                        KeyNavigation.left: advBtn
                                    }
                                    ApText { role: "cap"; text: qsTr("Звук"); Layout.topMargin: 18; Layout.bottomMargin: 4 }
                                    ApOpt {
                                        enabled: !!Chiaki.session && Chiaki.session.connected
                                        text: qsTr("Мікрофон")
                                        sub: checked ? qsTr("увімкнено: тебе чути в грі й чаті приставки") : qsTr("вимкнено")
                                        checked: !!Chiaki.session && !Chiaki.session.muted
                                        onClicked: Chiaki.session.muted = !Chiaki.session.muted
                                        KeyNavigation.left: advBtn
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.alignment: Qt.AlignTop
                                    spacing: 0
                                    ApText { role: "cap"; text: qsTr("Обробка картинки"); Layout.bottomMargin: 4 }
                                    Repeater {
                                        model: panel.videoPresets
                                        ApOpt {
                                            required property var modelData
                                            text: modelData.name
                                            sub: modelData.info || ""
                                            checked: Chiaki.window.videoPreset == modelData.id
                                            onClicked: panel.setVideoPreset(modelData.id)
                                            KeyNavigation.left: advBtn
                                        }
                                    }
                                    ApText {
                                        Layout.fillWidth: true
                                        Layout.topMargin: 10
                                        role: "hint"
                                        text: qsTr("Кольори, яскравість і контраст: пункт «Картинка» ліворуч.")
                                    }
                                }
                            }
                            ApText { role: "cap"; text: qsTr("Трансляція зараз"); Layout.topMargin: 18; Layout.bottomMargin: 8 }
                            Flow {
                                Layout.fillWidth: true
                                Layout.maximumWidth: 900
                                spacing: 6
                                Repeater {
                                    model: panel.visible && panel.page === "advanced" ? panel.streamChips() : []
                                    ApChip {
                                        required property var modelData
                                        text: modelData.text
                                        kind: modelData.kind || ""
                                    }
                                }
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
                                text: {
                                    if (panel.admin) {   // адмін сам вирішує, що буде з приставкою після виходу
                                        const cur = (Chiaki.cloud.adminInfo || ({})).current;
                                        return qsTr("Трансляція закриється. Приставку можна лишити ввімкненою або перевести в режим спокою.")
                                            + (cur ? " " + qsTr("Зараз час броні: <b>%1</b>. Режим спокою перерве гру клієнта, тож краще лишити приставку ввімкненою.").arg(cur.user) : "");
                                    }
                                    if (panel.guest)
                                        return qsTr("Трансляція закриється. Повернутись можна з головного екрана кнопкою «Грати», поки приставка вільна.");
                                    return Chiaki.cloud.endTs > 0
                                        ? qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до <b>%1</b>.").arg(Chiaki.cloud.formatTime(Chiaki.cloud.endTs))
                                        : qsTr("Трансляція закриється, але час гри йде далі. Повернутись можна з головного екрана кнопкою «Грати» до кінця броні.");
                                }
                            }
                            Flow {
                                Layout.fillWidth: true
                                Layout.topMargin: 8
                                spacing: 10
                                ApButton {
                                    id: exitConfirm
                                    focusPolicy: Qt.StrongFocus
                                    text: qsTr("Вийти з гри")
                                    // адміну закриття вікна показало б стандартне питання про режим спокою: відповідь уже тут, двома кнопками
                                    onClicked: panel.admin && Chiaki.session ? Chiaki.stopSession(false) : panel.exit()
                                    KeyNavigation.left: exitBtn
                                    KeyNavigation.right: sleepBtn
                                }
                                ApButton {
                                    id: sleepBtn
                                    visible: panel.admin && !!Chiaki.session
                                    focusPolicy: Qt.StrongFocus
                                    ghost: true
                                    height: exitConfirm.height
                                    text: qsTr("Вийти й приспати приставку")
                                    onClicked: Chiaki.stopSession(true)
                                    KeyNavigation.left: exitConfirm
                                    KeyNavigation.right: stayBtn
                                }
                                ApButton {
                                    id: stayBtn
                                    focusPolicy: Qt.StrongFocus
                                    ghost: true
                                    height: exitConfirm.height
                                    text: qsTr("Залишитись")
                                    onClicked: panel.goMain()
                                    KeyNavigation.left: sleepBtn
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
                    text: !Chiaki.session ? ""
                        : Chiaki.session.measuredBitrateReady === false ? qsTr("Зв'язок: вимірюю…")   // перші секунди гри чесного виміру ще немає
                        : qsTr("Зв'язок %1 Мбіт/с, втрати %2%").arg(Chiaki.session.measuredBitrate.toFixed(1).replace(".", ","))
                            .arg(((isFinite(Chiaki.session.averagePacketLoss) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1).replace(".", ","))
                }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                FootText { text: qsTr("Закрити меню: Esc або `") }
            }
        }
    }

    // повзунок у стилі меню: тонка лінія й кругла ручка
    component MenuSlider: Slider {
        id: ms
        background: Rectangle {
            x: ms.leftPadding
            y: ms.topPadding + ms.availableHeight / 2 - height / 2
            width: ms.availableWidth
            height: 2
            color: "#40ffffff"
            Rectangle { width: ms.visualPosition * parent.width; height: parent.height; color: ap.ink }
        }
        handle: Rectangle {
            x: ms.leftPadding + ms.visualPosition * (ms.availableWidth - width)
            y: ms.topPadding + ms.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7
            color: ap.ink
            border.width: ms.visualFocus ? 2 : 0
            border.color: ap.cyan
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
        active: (panel.page === "home" || panel.page === "wallet" || panel.page === "support") && panel.visible
        sourceComponent: AnyPlayHome {
            overGame: true
            onBackToGame: { panel.page = "back"; panel.resume(); }
            onBackToMenu: panel.page = "back"
        }
        onLoaded: { if (panel.page !== "home") item.view = panel.page; item.forceActiveFocus(); }
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

    // пункт ліворуч: великі літери на склі. Обраний — у градієнті заходу сонця зі світінням; наведення — зсув праворуч
    // і підсвітка; натиск — стискання; фокус з клавіатури чи геймпада — блакитна рамка
    component PauseItem: Item {
        id: pi
        property string pageId
        property string text
        property bool danger: false
        readonly property bool current: panel.page === pageId
        readonly property bool hov: piMouse.containsMouse
        Layout.fillWidth: true
        implicitHeight: piText.implicitHeight + (zoom.low ? 16 : 22)
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
        Item {
            id: piBody
            anchors.fill: parent
            x: 0
            transform: Translate { x: pi.hov && !pi.current ? 6 : 0; Behavior on x { NumberAnimation { duration: ap.tHover; easing.type: Easing.OutCubic } } }
            scale: piMouse.pressed ? ap.pressScale : 1
            Behavior on scale { NumberAnimation { duration: ap.tPress } }
            // тінь під обраним
            Rectangle {
                visible: pi.current
                x: 0; y: 4; width: parent.width; height: parent.height
                radius: ap.radius
                color: pi.danger ? "#40ff4f4f" : "#55ff4f8b"
                opacity: 0.6
            }
            // скло (наведення) або градієнт (обраний)
            Rectangle {
                anchors.fill: parent
                radius: ap.radius
                color: pi.hov ? ap.glassHi : "transparent"
                border.width: pi.hov && !pi.current ? 1 : 0
                border.color: ap.edge
                Behavior on color { ColorAnimation { duration: ap.tHover } }
            }
            Rectangle {
                anchors.fill: parent
                radius: ap.radius
                visible: pi.current
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: pi.danger ? "#e0d94a5a" : ap.accentA }
                    GradientStop { position: 1.0; color: pi.danger ? "#c0b0303f" : ap.accentB }
                }
                Rectangle { x: 6; y: 1; width: parent.width - 12; height: 1; color: "#59ffffff" }   // відблиск зверху
            }
            Text {
                id: piText
                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                text: pi.text
                elide: Text.ElideRight
                font.family: ap.display; font.weight: pi.current ? Font.DemiBold : Font.Medium; font.pixelSize: zoom.low ? 17 : 19
                font.letterSpacing: 1.8; font.capitalization: Font.AllUppercase
                color: pi.current ? ap.inkAccent : pi.danger ? ap.bad : ap.ink
                opacity: pi.current || pi.hov || pi.activeFocus ? 1 : 0.72
                Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            }
            Text {   // стрілка праворуч у обраного: туди йде вміст
                visible: pi.current && pi.pageId !== "back"
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                text: "›"
                color: ap.inkAccent
                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: zoom.low ? 18 : 22
            }
            Rectangle {   // фокус з клавіатури чи геймпада
                anchors.fill: parent
                anchors.margins: -3
                radius: ap.radius + 3
                visible: pi.activeFocus
                color: "transparent"
                border.width: 2; border.color: ap.cyan
            }
        }
        MouseArea {
            id: piMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { pi.forceActiveFocus(); if (pi.pageId === "back") panel.resume(); else panel.page = pi.pageId; }
        }
    }
}
