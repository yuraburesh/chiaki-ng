// AnyPlay 113: екран «Зображення» — усе про картинку в одному місці. Один і той самий на головному вікні (вкладка
// «Зображення») і в меню паузи (пункт «Зображення», inGame: true). Розділи:
//   Якість    — рівень потоку з приставки (роздільність, кадри, бітрейт) з прикладами-плитками, оцінка комп'ютера,
//               позначки «не потягне» біля важкого, «Авто», перевірка інтернету (поза грою); у грі під плитками —
//               рядок «Зараз у грі» (кадри, швидкість, втрати, обробка; до 118 це була окрема вкладка «Трансляція зараз»)
//   Обробка   — що робить комп'ютер з кожним кадром (проста, стандартна, висока якість, ШІ-чіткість, посилена);
//               позначки, що цей комп'ютер не потягне чи вже не потягнув; «Спробувати ще раз». 118: одразу після «Якості»
//   Кольори   — яскравість, контраст, насиченість, теплота (колишня «Картинка»); діють одразу
//   Екран і звук — як картинка лягає на екран (як є, наблизити, розтягнути), у грі ще індикатор кадрів у кутку й мікрофон
// Навігація з клавіатури й геймпада: ↑↓ по рядках, ←→ по вкладках і плитках якості, Enter обирає, ← з першої колонки
// повертає на пункт меню ліворуч (navLeft). Плитки якості — оригінальна сцена AnyPlay (без кадрів з ігор), відрендерена
// в чотири картинки: м'яка (540p), чіткіша (720p, 1080p) і з дрібними деталями (ШІ-чіткість); див. gui/res/anyplay-quality.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

FocusScope {
    id: img
    property bool inGame: false              // у меню паузи: щільніше, «Екран і звук», рядок «Зараз у грі»
    property bool compact: inGame            // менші плитки й відступи
    property Item navLeft: null              // пункт меню ліворуч (←)
    property string section: "quality"       // quality | render | colors | screen
    property real maxW: 1180
    readonly property Item firstControl: img // з меню паузи: фокус сюди, далі ↓ по вмісту
    // рівень обрали (меню паузи робить перепідключення саме); from — рівень до вибору; level -1 — «Авто», -2 — нічого не змінилось
    signal qualityPicked(int level, int from)
    // AnyPlay 115: звідки брати дані. Типово — справжні; у перегляді меню для адміна (demo) — заглушки меню паузи,
    // тож вибір тут нічого не змінює на цьому комп'ютері
    property bool demo: false
    property var cloud: Chiaki.cloud
    property var win: Chiaki.window
    property var sess: Chiaki.session
    property bool kbd: true                  // останнім керували з клавіатури чи геймпада (рамка фокусу лише тоді)
    AnyPlayStyle { id: ap }

    implicitHeight: col.implicitHeight
    readonly property real w: Math.min(width, maxW)
    readonly property bool admin: img.cloud.admin === true
    readonly property bool live: !!img.sess && img.sess.connected
    readonly property string tier: img.cloud.pcTier || "ok"
    readonly property int capFrom: img.cloud.renderCappedFrom !== undefined ? img.cloud.renderCappedFrom : -1
    readonly property int preset: img.win.videoPreset

    // ── дані ──
    readonly property var levelNames: [qsTr("Економна"), qsTr("Оптимальна"), qsTr("Максимальна"), qsTr("Ультра")]
    readonly property var levels: [
        { level: 0, name: levelNames[0], res: qsTr("540p, 30 кадр/с"), net: qsTr("інтернет від 6 Мбіт/с"), netShort: qsTr("від 6 Мбіт/с"), sub: qsTr("Для слабкого чи мобільного інтернету. Картинка м'яка, зате без затримок.") },
        { level: 1, name: levelNames[1], res: qsTr("720p, 60 кадр/с"), net: qsTr("інтернет від 15 Мбіт/с"), netShort: qsTr("від 15 Мбіт/с"), sub: qsTr("Підходить більшості: плавно і чітко на ноутбуці.") },
        { level: 2, name: levelNames[2], res: qsTr("1080p, 60 кадр/с"), net: qsTr("від 30 Мбіт/с, краще кабель"), netShort: qsTr("від 30 Мбіт/с"), sub: qsTr("Повна чіткість приставки. Потрібен стабільний швидкий інтернет.") },
        { level: 3, name: levelNames[3], res: qsTr("1080p, 60 кадр/с"), net: qsTr("від 30 Мбіт/с, краще кабель"), netShort: qsTr("від 30 Мбіт/с"), sub: qsTr("Те саме відео, що «Максимальна», плюс ШІ-чіткість: відеокарта домальовує дрібні деталі на великому екрані.") }
    ]
    readonly property var renders: [
        { id: ChiakiWindow.VideoPreset.Fast, name: qsTr("Проста"), sub: qsTr("Найлегша для комп'ютера, без згладжування. Для дуже слабкого ноутбука. Типова для «Економної»."), need: 0 },
        { id: ChiakiWindow.VideoPreset.Default, name: qsTr("Стандартна"), sub: qsTr("Легке згладжування, майже не навантажує. Типова для «Оптимальної»."), need: 1 },
        { id: ChiakiWindow.VideoPreset.HighQuality, name: qsTr("Висока якість"), sub: qsTr("Краще масштабування й плавні переходи кольору. Типова для «Максимальної»."), need: 2 },
        { id: ChiakiWindow.VideoPreset.HighQualitySpatial, name: qsTr("ШІ-чіткість"), sub: qsTr("Нейромережа домальовує дрібні деталі, коли екран більший за 1080p. Рахує відеокарта: на тонкому ноутбуці може дати менше кадрів. Типова для «Ультра»."), need: 3 },
        { id: ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial, name: qsTr("Посилена ШІ-чіткість"), sub: qsTr("Удвічі важча нейромережа. Лише для потужної відеокарти."), need: 4 }
    ]
    // 118: обробка одразу після якості (вона йде за рівнем), кольори далі; «Трансляцію зараз» замінив рядок під плитками
    readonly property var sections: [{ id: "quality", text: qsTr("Якість") }, { id: "render", text: qsTr("Обробка") },
                                     { id: "colors", text: qsTr("Кольори") }, { id: "screen", text: inGame ? qsTr("Екран і звук") : qsTr("Екран") }]
    function levelName() { return levelNames[img.cloud.qualityLevel] || levelNames[1]; }
    function levelOn(l) { return !img.cloud.autoQuality && img.cloud.qualityLevel === l; }
    function pickLevel(l) {
        const from = img.cloud.qualityLevel;   // до 115 меню паузи брало рівень уже після зміни (див. AnyPlayStreamMenu.qualityPicked)
        if (l < 0) { img.cloud.autoQuality = true; img.qualityPicked(-1, from); return; }
        const same = !img.cloud.autoQuality && from === l;
        img.cloud.autoQuality = false;
        if (!same)
            img.cloud.setQualityLevel(l);
        img.qualityPicked(same ? -2 : l, from);   // -2: нічого не змінилось; з «Авто» на той самий рівень — l == from, без перепідключення
    }
    // позначка біля рівня: чи потягне цей комп'ютер (рівень 3 — ШІ-чіткість, 2 — висока якість)
    function levelMark(l) {
        if (l === 3) {
            if (capFrom === ChiakiWindow.VideoPreset.HighQualitySpatial || capFrom === ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial)
                return { text: qsTr("не потягнув"), kind: "bad" };
            if (tier === "weak") return { text: qsTr("цей комп'ютер не потягне"), kind: "bad" };
            if (tier === "ok") return { text: qsTr("може не встигати"), kind: "wait" };
            return { text: qsTr("радимо"), kind: "ok" };
        }
        if (l === 2) {
            if (capFrom === ChiakiWindow.VideoPreset.HighQuality) return { text: qsTr("не потягнув"), kind: "bad" };
            if (tier === "weak") return { text: qsTr("може не встигати"), kind: "wait" };
        }
        return null;
    }
    function renderMark(r) {
        if (capFrom === r.id) return { text: qsTr("не потягнув під час гри"), kind: "bad" };
        if (!img.cloud.pcCanRender(r.id)) return { text: tier === "weak" ? qsTr("не потягне") : qsTr("може не встигати"), kind: tier === "weak" ? "bad" : "wait" };
        if (r.need >= 3 && tier === "strong") return { text: qsTr("потягне"), kind: "ok" };
        return null;
    }
    function tierName() { return tier === "strong" ? qsTr("потужний") : tier === "weak" ? qsTr("слабкий") : qsTr("середній"); }
    function tierKind() { return tier === "strong" ? "ok" : tier === "weak" ? "bad" : "wait"; }
    function tierText() {
        if (tier === "strong") return qsTr("Потягне «Ультра» з ШІ-чіткістю на 60 кадр/с.");
        if (tier === "weak") return qsTr("Радимо «Оптимальну»: важкі обробки цей комп'ютер не потягне.");
        return qsTr("«Максимальна» йде на 60 кадр/с, ШІ-чіткість («Ультра») може давати менше кадрів.");
    }
    function capText() {
        return qsTr("Під час гри цей комп'ютер не встиг з обробкою «%1», тож тримаємо «%2» (до тижня, потім перевіримо знову). Якість потоку від цього не змінюється.")
            .arg(img.cloud.renderLabel(img.capFrom)).arg(img.cloud.renderLabel(Math.max(0, Math.min(3, img.cloud.renderCap))));
    }
    function num1(x) { return (isFinite(x) ? x : 0).toFixed(1).replace(".", ","); }
    function zoomText(v) { return v <= -1 ? qsTr("без чорних смуг") : qsTr("%1 x").arg((v >= 0 ? v + 1 : v).toFixed(2).replace(".", ",")); }
    function valueText(v) { return v === 0 ? qsTr("типово") : (v > 0 ? "+" : "") + v; }
    // 118: рядок «Зараз у грі» під плитками якості (замість вкладки «Трансляція зараз»): що з картинкою просто зараз.
    // Тихий, коли все добре; золотом лише те, що не так (на екрані помітно менше кадрів, ніж приходить, втрати, спрощено)
    function nowText() {
        const s = img.sess, win = img.win;
        if (!s) return "";
        const warn = (t) => "<font color=\"" + ap.gold + "\">" + t + "</font>";
        const parts = [];
        const stream = win.streamFps || 0, shown = win.shownFps || 0;
        if (stream >= 20 && shown > 0 && shown < stream * 0.8)
            parts.push(warn(qsTr("на екрані %1 з %2 кадр/с").arg(shown).arg(stream)));
        else
            parts.push(qsTr("%1 кадр/с").arg(shown > 0 ? Math.min(shown, stream || shown) : stream));
        parts.push(s.measuredBitrateReady === false ? qsTr("швидкість вимірюю") : qsTr("%1 Мбіт/с").arg(num1(s.measuredBitrate)));
        const loss = (isFinite(s.averagePacketLoss) ? s.averagePacketLoss : 0) * 100;
        parts.push(loss > 0.5 ? warn(qsTr("втрати %1%").arg(num1(loss))) : qsTr("втрати %1%").arg(num1(loss)));
        const r = qsTr("обробка %1").arg(img.cloud.renderLabel(img.preset));
        parts.push(img.cloud.renderCapped ? warn(r + qsTr(", спрощено")) : r);
        return parts.join(", ");
    }

    // ── навігація з клавіатури й геймпада: ↑↓ по елементах поточного розділу, ←→ по вкладках і плитках ──
    function tabItems() {
        const out = [];
        for (let i = 0; i < tabs.children.length; i++) {
            const c = tabs.children[i];
            if (c.modelData !== undefined && c.visible)
                out.push(c);
        }
        return out;
    }
    function tabItem(id) {
        const t = tabItems();
        for (let i = 0; i < t.length; i++)
            if (t[i].modelData.id === id)
                return t[i];
        return t.length ? t[0] : null;
    }
    function focusables() {
        const out = [];
        function walk(it) {
            if (!it || !it.visible || it.enabled === false || it === tabs) return;
            if (it.activeFocusOnTab && it !== img) out.push(it);
            const ch = it.children;
            for (let i = 0; i < ch.length; i++) walk(ch[i]);
        }
        walk(body);
        return out;
    }
    function focusedIn(list, cur) {
        for (let i = 0; i < list.length; i++)
            if (list[i] === cur || list[i].activeFocus)
                return i;
        return -1;
    }
    function isTab(it) { return it && it.parent === tabs; }
    function current() { return Window.activeFocusItem; }
    function focusTab() { const t = tabItem(section); if (t) t.forceActiveFocus(Qt.TabFocusReason); }
    function moveSection(d) {
        let i = 0;
        for (let k = 0; k < sections.length; k++) if (sections[k].id === section) i = k;
        i = Math.max(0, Math.min(sections.length - 1, i + d));
        if (sections[i].id !== section) { section = sections[i].id; focusTab(); return true; }
        return false;
    }
    function moveRow(d) {
        const cur = current();
        if (isTab(cur)) {
            if (d > 0) { const f = focusables(); if (f.length) f[0].forceActiveFocus(Qt.TabFocusReason); }
            return;
        }
        const f = focusables();
        const i = focusedIn(f, cur);
        if (i < 0) { if (f.length) f[0].forceActiveFocus(Qt.TabFocusReason); return; }
        // плитки якості стоять у ряд: ↓ з плитки йде під увесь ряд, ↑ на плитку — на весь ряд
        let j = i + d;
        if (d > 0) while (j < f.length && f[j].isLevelCard && f[i].isLevelCard) j++;
        if (d < 0) while (j > 0 && f[j].isLevelCard && f[j - 1].isLevelCard && !f[i].isLevelCard) j--;
        if (j < 0) { focusTab(); return; }
        if (j >= f.length) return;
        f[j].forceActiveFocus(Qt.TabFocusReason);
    }
    function moveCol(d) {
        const cur = current();
        if (isTab(cur)) {
            if (moveSection(d)) return true;
            if (d < 0 && navLeft) { navLeft.forceActiveFocus(Qt.TabFocusReason); return true; }   // з першої вкладки ← — на пункт ліворуч
            return false;
        }
        const f = focusables();
        const i = focusedIn(f, cur);
        if (i >= 0 && f[i].isLevelCard) {
            const j = i + d;
            if (j >= 0 && j < f.length && f[j].isLevelCard) { f[j].forceActiveFocus(Qt.TabFocusReason); return true; }
        }
        if (d < 0 && navLeft) { navLeft.forceActiveFocus(Qt.TabFocusReason); return true; }
        return false;
    }
    Keys.onUpPressed: (e) => { kbd = true; moveRow(-1); e.accepted = true; }
    Keys.onDownPressed: (e) => { kbd = true; moveRow(1); e.accepted = true; }
    Keys.onLeftPressed: (e) => { kbd = true; e.accepted = moveCol(-1); }
    Keys.onRightPressed: (e) => { kbd = true; e.accepted = moveCol(1); }
    Keys.onReturnPressed: (e) => { if (current() === img) { focusTab(); e.accepted = true; } }
    onActiveFocusChanged: if (activeFocus && Window.activeFocusItem === img) focusTab()
    onSectionChanged: { hoverLevel = -1; hoverTile = null; }
    onVisibleChanged: if (!visible) { hoverLevel = -1; hoverTile = null; }

    // ── плитка-приклад: оригінальна сцена (нічна дорога, пальми, авто), детальність за рівнем ──
    property int hoverLevel: -1
    property Item hoverTile: null
    // приклад для рівня: оригінальна сцена AnyPlay (нічна дорога, пальми, авто), заздалегідь відрендерена в чотири
    // картинки 640×360: 540p і 720p — справді зменшені й розтягнуті назад (м'якші), 1080p — повна, ШІ-чіткість —
    // з підсиленням дрібних деталей. Звичайні картинки, без шарів і шейдерів: нічого не навантажують.
    component Scene: Image {
        property int detail: 2            // 0 — 540p, 1 — 720p, 2 — 1080p, 3 — 1080p і ШІ-чіткість
        source: "qrc:/anyplay-quality/q" + Math.max(0, Math.min(3, detail)) + ".jpg"
        sourceSize: Qt.size(640, 360)
        fillMode: Image.PreserveAspectCrop
        smooth: true
        asynchronous: true
    }

    // ── вміст ──
    ColumnLayout {
        id: col
        width: img.w
        spacing: 0

        Item {
            id: body
            Layout.fillWidth: true
            implicitHeight: bodyCol.implicitHeight
            ColumnLayout {
                id: bodyCol
                width: parent.width
                spacing: 0

                // вкладки розділів
                ApTabs {
                    id: tabs
                    Layout.bottomMargin: img.compact ? 10 : 16
                    model: img.sections
                    current: img.section
                    compact: img.compact
                    onActivated: (id) => { img.section = id; img.focusTab(); }
                    onClickedTab: img.kbd = false
                }

                // ═════ ЯКІСТЬ ═════
                // широке вікно (поза грою): ліворуч плитки, праворуч комп'ютер, індикатор, пояснення, перевірка інтернету
                GridLayout {
                    id: qGrid
                    readonly property bool wide: !img.inGame && img.w >= 1300
                    visible: img.section === "quality"
                    Layout.fillWidth: true
                    columns: wide ? 2 : 1
                    columnSpacing: 28
                    rowSpacing: 0
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: qGrid.wide ? 3 : 1
                        Layout.alignment: Qt.AlignTop
                        spacing: 0
                        ApText {
                            Layout.fillWidth: true; Layout.maximumWidth: 760
                            Layout.bottomMargin: img.compact ? 8 : 12
                            role: "hint"
                            text: img.inGame
                                ? qsTr("Інший рівень перепідключить гру на кілька секунд, прогрес у грі не зникає.")
                                : qsTr("Якість потоку з приставки: роздільність і кадри. Що вища, то більше потрібно інтернету; обробку на комп'ютері підбираємо під рівень. Наведи на плитку, щоб побачити приклад більшим.")
                        }
                        ApOpt {   // «Авто»
                            id: autoOpt
                            Layout.fillWidth: true
                            text: qsTr("Авто (радимо)")
                            sub: qsTr("Сама знижує якість, коли зв'язок слабшає, і повертає, коли все добре. Зараз: %1.").arg(img.levelName())
                            checked: img.cloud.autoQuality
                            onClicked: img.pickLevel(-1)
                        }
                        GridLayout {   // плитки рівнів
                            id: grid
                            readonly property int cols: (qGrid.wide ? img.w * 0.6 : img.w) >= (img.compact ? 600 : 860) ? 4 : 2
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            columns: cols
                            columnSpacing: 12
                            rowSpacing: 12
                            Repeater {
                                model: img.levels
                                LevelCard {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.alignment: Qt.AlignTop
                                    data_: modelData
                                }
                            }
                        }
                        // 118: стан поточної гри одним рядком (лише в грі, замість вкладки «Трансляція зараз»)
                        RowLayout {
                            id: nowRow
                            visible: img.inGame && img.live
                            Layout.fillWidth: true
                            Layout.topMargin: img.compact ? 10 : 16
                            spacing: 8
                            ApText { role: "cap"; text: qsTr("Зараз у грі") }
                            ApText {
                                Layout.fillWidth: true
                                role: "small"; color: ap.mute
                                rich: true
                                elide: Text.ElideRight
                                text: nowRow.visible && img.visible ? img.nowText() : ""
                            }
                        }
                        // комп'ютер (у вузькому вікні й у грі — одним рядком під плитками)
                        RowLayout {
                            visible: !qGrid.wide
                            Layout.fillWidth: true
                            Layout.topMargin: nowRow.visible ? 6 : (img.compact ? 10 : 16)
                            spacing: 8
                            ApText { role: "cap"; text: qsTr("Твій комп'ютер") }
                            ApChip { text: img.cloud.pcInfo || qsTr("невідомо") }
                            ApChip { text: img.tierName(); kind: img.tierKind() }
                            ApText { Layout.fillWidth: true; role: "small"; color: ap.mute; text: img.tierText(); wrapMode: Text.WordWrap }
                        }
                        RowLayout {
                            visible: !qGrid.wide && img.cloud.renderCapped
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            spacing: 10
                            ApText {
                                Layout.fillWidth: true
                                role: "small"; color: ap.gold
                                wrapMode: Text.WordWrap
                                text: img.capText()
                            }
                            ApButton { small: true; ghost: true; focusPolicy: Qt.StrongFocus; text: qsTr("Спробувати ще раз"); onClicked: img.cloud.clearRenderCap() }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: qGrid.wide ? 2 : 1
                        Layout.maximumWidth: qGrid.wide ? 520 : 760
                        Layout.alignment: Qt.AlignTop
                        spacing: 0
                        ApCard {   // комп'ютер (широке вікно)
                            visible: qGrid.wide
                            title: qsTr("Твій комп'ютер")
                            spacing: 8
                            Flow {
                                Layout.fillWidth: true
                                spacing: 6
                                ApChip { text: img.cloud.pcInfo || qsTr("невідомо") }
                                ApChip { text: img.tierName(); kind: img.tierKind() }
                            }
                            ApText { Layout.fillWidth: true; role: "small"; color: ap.mute; text: img.tierText() }
                            ApText { visible: img.cloud.renderCapped; Layout.fillWidth: true; role: "small"; color: ap.gold; text: img.capText() }
                            ApButton { visible: img.cloud.renderCapped; small: true; ghost: true; focusPolicy: Qt.StrongFocus; text: qsTr("Спробувати ще раз"); onClicked: img.cloud.clearRenderCap() }
                        }
                        ApOpt {   // у грі цей перемикач на вкладці «Екран і звук»
                            visible: !img.inGame
                            Layout.fillWidth: true
                            Layout.topMargin: img.compact ? 8 : 14
                            radio: false
                            text: qsTr("Показувати кадри за секунду і зв'язок під час гри")
                            sub: qsTr("Маленький рядок у кутку екрана: кадри за секунду, швидкість, втрати, якість")
                            checked: img.cloud.showStats
                            onClicked: img.cloud.showStats = !img.cloud.showStats
                            ApSwitch { activeFocusOnTab: false; checked: img.cloud.showStats; onToggled: img.cloud.showStats = !img.cloud.showStats }
                        }
                        // як це працює (згорнуто)
                        ApRow {
                            id: howRow
                            property bool open: false
                            Layout.fillWidth: true
                            clickable: true
                            hairline: false
                            title: qsTr("Як це працює: якість, обробка, ШІ-чіткість")
                            subtitle: open ? "" : qsTr("і чому «Ультра» може давати менше кадрів")
                            onClicked: open = !open
                            ApText { role: "small"; color: ap.mute; text: howRow.open ? "▴" : "▾" }
                        }
                        ApText {
                            visible: howRow.open
                            Layout.fillWidth: true
                            Layout.bottomMargin: 8
                            role: "small"; rich: true
                            wrapMode: Text.WordWrap
                            text: qsTr("<b>Якість</b> — це відео, яке приставка шле через інтернет: роздільність (540p, 720p, 1080p) і кадри за секунду. Що вища, то більше потрібно швидкості й стабільності зв'язку. Вище 1080p і 60 кадр/с дистанційна гра PS5 не дає.<br>"
                                       + "<b>Обробка</b> — що комп'ютер робить з кожним кадром перед показом: масштабує під екран, згладжує, вирівнює кольори. Її рахує відеокарта вже після того, як відео прийшло.<br>"
                                       + "<b>ШІ-чіткість</b> — нейромережа, яка домальовує дрібні деталі при масштабуванні 1080p на великий екран (наприклад, Retina). Це найважча частина обробки.<br>"
                                       + "<b>Чому «Ультра» може давати менше кадрів.</b> Відео в «Ультра» те саме, що в «Максимальній», а різниця лише в ШІ-чіткості. На ноутбуці без вентилятора чи окремої відеокарти (MacBook Air, особливо на Retina-екрані) нейромережа може не встигати за 60 кадрами, тож на екрані їх 40–50, а ще ноутбук гріється. Тоді AnyPlay за перші 20 с гри сам спрощує обробку, каже про це в чорній смузі й запам'ятовує для цього комп'ютера на тиждень. Кадри, що загубились чи затримались в інтернеті, до цього не рахуються. Хочеш 60 кадр/с без ризику — обирай «Максимальну».")
                        }
                        // перевірка інтернету (поза грою)
                        SpeedCard {
                            visible: !img.inGame && !!Chiaki.speedTest
                            Layout.fillWidth: true
                            Layout.topMargin: 16
                        }
                    }
                }

                // ═════ КОЛЬОРИ ═════
                ColumnLayout {
                    visible: img.section === "colors"
                    Layout.fillWidth: true
                    spacing: 0
                    readonly property var items: [
                        { key: "picBrightness", name: qsTr("Яскравість"), lo: qsTr("темніше"), hi: qsTr("світліше"),
                          hint: qsTr("Світлішають або темнішають середні тони. Біле лишається білим: небо й сонце від цього не пересвічуються.") },
                        { key: "picContrast", name: qsTr("Контраст"), lo: qsTr("м'якше"), hi: qsTr("різкіше"),
                          hint: qsTr("Більше — глибші тіні й яскравіші світлі місця. Якщо сонце сліпить, зменш контраст.") },
                        { key: "picSaturation", name: qsTr("Насиченість"), lo: qsTr("блідіше"), hi: qsTr("соковитіше"), hint: "" },
                        { key: "picWarmth", name: qsTr("Теплота"), lo: qsTr("холодніше"), hi: qsTr("тепліше"), hint: "" }
                    ]
                    ApText {
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.bottomMargin: 10
                        role: "hint"
                        text: qsTr("Змінюється одразу, гра не перепідключається. Нуль на кожному повзунку — типові значення AnyPlay (трохи глибші середні тони й соковитіші кольори, ближче до телевізора від приставки напряму). Запам'ятовується на цьому комп'ютері.")
                    }
                    Repeater {
                        model: parent.items
                        ColumnLayout {
                            id: row
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.maximumWidth: 760
                            Layout.bottomMargin: img.compact ? 8 : 14
                            spacing: 2
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                ApText { role: "title"; text: row.modelData.name; Layout.fillWidth: true }
                                ApChip { text: img.valueText(Math.round(sl.value)) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                ApText { role: "small"; color: ap.mute; text: row.modelData.lo; Layout.preferredWidth: 72 }
                                PicSlider {
                                    id: sl
                                    Layout.fillWidth: true
                                    from: -100; to: 100; stepSize: 5
                                    value: img.win[row.modelData.key]
                                    onMoved: img.win[row.modelData.key] = Math.round(value)
                                }
                                ApText { role: "small"; color: ap.mute; text: row.modelData.hi; Layout.preferredWidth: 72; horizontalAlignment: Text.AlignRight }
                            }
                            ApText { visible: row.modelData.hint !== "" && !img.compact; Layout.fillWidth: true; role: "hint"; text: row.modelData.hint }
                        }
                    }
                    ApButton {
                        Layout.topMargin: 4
                        small: true; ghost: true
                        focusPolicy: Qt.StrongFocus
                        enabled: !img.win.picIsDefault
                        text: qsTr("Як було типово")
                        onClicked: img.win.resetPicture()
                    }
                    ApText {
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.topMargin: 14
                        role: "hint"
                        text: qsTr("Якщо небо чи сонце в грі зливаються в біле, це вже прийшло таким з приставки. Допомагає повзунок «Яскравість» у налаштуваннях самої гри (меню гри, «Зображення»): зменш його на кілька поділок.")
                    }
                }

                // ═════ ОБРОБКА ═════
                ColumnLayout {
                    visible: img.section === "render"
                    Layout.fillWidth: true
                    spacing: 0
                    ApText {
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.bottomMargin: 8
                        role: "hint"
                        text: qsTr("Що комп'ютер робить з кожним кадром перед показом. Діє одразу, без перепідключення. Коли обираєш якість, обробка стає типовою для неї; простіша за типову лишається, важчу перевіряємо під час гри і спрощуємо, якщо комп'ютер не встигає.")
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 6
                        spacing: 8
                        ApText { role: "cap"; text: qsTr("Зараз") }
                        ApChip { text: img.cloud.renderLabel(img.preset); kind: img.cloud.renderCapped ? "wait" : "ok" }
                        ApChip { visible: img.cloud.renderCapped; text: qsTr("спрощено: комп'ютер не встигав"); kind: "wait" }
                        ApButton { visible: img.cloud.renderCapped; small: true; ghost: true; focusPolicy: Qt.StrongFocus; text: qsTr("Спробувати ще раз"); onClicked: img.cloud.clearRenderCap() }
                        Item { Layout.fillWidth: true }
                    }
                    Repeater {
                        model: img.renders
                        ApOpt {
                            id: ro
                            required property var modelData
                            readonly property var mark: img.renderMark(modelData)
                            Layout.fillWidth: true
                            Layout.maximumWidth: 760
                            text: modelData.name
                            sub: modelData.sub
                            checked: img.preset === modelData.id
                            onClicked: img.cloud.setRenderPreset(modelData.id)
                            ApChip { visible: !!ro.mark; text: ro.mark ? ro.mark.text : ""; kind: ro.mark ? ro.mark.kind : "" }
                        }
                    }
                    ApOpt {
                        visible: img.preset === ChiakiWindow.VideoPreset.Custom
                        Layout.fillWidth: true
                        Layout.maximumWidth: 760
                        text: qsTr("Своя")
                        sub: qsTr("Налаштування обробки, задані вручну в стандартних налаштуваннях програми.")
                        checked: true
                    }
                    ApText {
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.topMargin: 10
                        role: "small"; color: ap.mute
                        wrapMode: Text.WordWrap
                        text: qsTr("ШІ-чіткість працює лише коли вікно більше за відео (наприклад, екран Retina з 1080p). На екрані 1080p вона нічого не домальовує, а відеокарту навантажує.")
                    }
                }

                // ═════ ЕКРАН І ЗВУК ═════
                ColumnLayout {
                    visible: img.section === "screen"
                    Layout.fillWidth: true
                    spacing: 0
                    ApText { role: "cap"; text: qsTr("Картинка на екрані"); Layout.bottomMargin: 4 }
                    ApOpt {
                        Layout.maximumWidth: 760
                        text: qsTr("Як є")
                        sub: qsTr("уся картинка, з чорними смугами, якщо екран іншої форми")
                        checked: img.win.videoMode == ChiakiWindow.VideoMode.Normal
                        onClicked: img.win.videoMode = ChiakiWindow.VideoMode.Normal
                    }
                    ApOpt {
                        Layout.maximumWidth: 760
                        text: qsTr("Наблизити")
                        sub: qsTr("збільшує картинку, краї можуть обрізатись")
                        checked: img.win.videoMode == ChiakiWindow.VideoMode.Zoom
                        onClicked: img.win.videoMode = ChiakiWindow.VideoMode.Zoom
                    }
                    RowLayout {   // наскільки наблизити (лише в режимі «Наблизити»)
                        visible: img.win.videoMode == ChiakiWindow.VideoMode.Zoom
                        Layout.fillWidth: true
                        Layout.maximumWidth: 760
                        Layout.topMargin: 6
                        Layout.bottomMargin: 6
                        spacing: 12
                        PicSlider {
                            id: zoomSlider
                            Layout.fillWidth: true
                            from: -1; to: 4; stepSize: 0.01
                            // у справжнього вікна властивість ZoomFactor (з великої), у заглушки перегляду — zoomFactor
                            value: img.win.ZoomFactor !== undefined ? img.win.ZoomFactor : (img.win.zoomFactor || 0)
                            mid: false
                            onMoved: {
                                if (img.demo) { img.win.zoomFactor = value; return; }
                                img.win.ZoomFactor = value;
                                Chiaki.settings.sZoomFactor = value;
                            }
                        }
                        ApChip { text: img.zoomText(zoomSlider.value) }
                    }
                    ApOpt {
                        Layout.maximumWidth: 760
                        text: qsTr("Розтягнути")
                        sub: qsTr("на весь екран без смуг, пропорції можуть змінитись")
                        checked: img.win.videoMode == ChiakiWindow.VideoMode.Stretch
                        onClicked: img.win.videoMode = ChiakiWindow.VideoMode.Stretch
                    }
                    ApOpt {   // 118: індикатор у кутку (до 118 — у вкладці «Трансляція зараз»)
                        visible: img.inGame
                        Layout.fillWidth: true
                        Layout.maximumWidth: 760
                        Layout.topMargin: 10
                        radio: false
                        text: qsTr("Показувати кадри за секунду і зв'язок у кутку екрана")
                        sub: qsTr("Маленький рядок під час гри: кадри за секунду, швидкість, втрати, якість")
                        checked: img.cloud.showStats
                        onClicked: img.cloud.showStats = !img.cloud.showStats
                        ApSwitch { activeFocusOnTab: false; checked: img.cloud.showStats; onToggled: img.cloud.showStats = !img.cloud.showStats }
                    }
                    ApText { visible: img.inGame; role: "cap"; text: qsTr("Звук"); Layout.topMargin: 18; Layout.bottomMargin: 4 }
                    ApOpt {
                        visible: img.inGame
                        enabled: img.live
                        Layout.maximumWidth: 760
                        radio: false
                        text: qsTr("Мікрофон")
                        sub: checked ? qsTr("увімкнено: тебе чути в грі й чаті приставки") : qsTr("вимкнено")
                        checked: !!img.sess && !img.sess.muted
                        onClicked: if (img.sess) img.sess.muted = !img.sess.muted
                        ApSwitch { activeFocusOnTab: false; checked: !!img.sess && !img.sess.muted; onToggled: if (img.sess) img.sess.muted = !img.sess.muted }
                    }
                    ApText {
                        visible: !img.inGame
                        Layout.fillWidth: true; Layout.maximumWidth: 760
                        Layout.topMargin: 10
                        role: "hint"
                        text: qsTr("Мікрофон і гучність — у меню AnyPlay під час гри.")
                    }
                }
            }
        }
    }

    // ── більший приклад під наведенням на плитку ──
    Item {
        id: big
        visible: img.hoverLevel >= 0 && img.hoverTile !== null
        z: 20
        readonly property real bw: Math.min(440, img.w - 20)
        readonly property real bh: bw * 9 / 16 + 42
        width: bw; height: bh
        x: {
            if (!img.hoverTile) return 0;
            const p = img.hoverTile.mapToItem(img, 0, 0);
            return Math.max(0, Math.min(img.w - bw, p.x + img.hoverTile.width / 2 - bw / 2));
        }
        y: {
            if (!img.hoverTile) return 0;
            const p = img.hoverTile.mapToItem(img, 0, 0);
            const below = p.y + img.hoverTile.height + 8;
            return below + bh <= img.height ? below : Math.max(0, p.y - bh - 8);
        }
        Rectangle { anchors.fill: parent; anchors.topMargin: 6; anchors.bottomMargin: -6; radius: ap.cardRadius + 2; color: ap.shadow; opacity: 0.6 }
        Rectangle {
            anchors.fill: parent
            radius: ap.cardRadius
            color: "#f21c1430"
            border.width: 1; border.color: ap.edgeHi
            Scene { x: 8; y: 8; width: parent.width - 16; height: width * 9 / 16; detail: Math.max(0, img.hoverLevel) }
            ApText {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 12; rightMargin: 12; bottomMargin: 8 }
                role: "small"; color: ap.mute
                elide: Text.ElideRight
                text: img.hoverLevel >= 0 ? qsTr("%1: %2. Приклад, не кадр з гри.").arg(img.levels[img.hoverLevel].name).arg(img.levels[img.hoverLevel].res) : ""
            }
        }
    }

    // ── плитка рівня якості: приклад, назва, умови, позначка для цього комп'ютера ──
    component LevelCard: Item {
        id: lc
        property var data_
        readonly property bool isLevelCard: true
        readonly property bool on: img.levelOn(data_.level)
        readonly property var mark: img.levelMark(data_.level)
        readonly property bool hot: lcMouse.containsMouse
        property bool byMouse: false             // фокус після клацу мишкою: без блакитної рамки
        readonly property bool ring: activeFocus && !byMouse && img.kbd
        onActiveFocusChanged: if (!activeFocus) byMouse = false
        implicitHeight: lcCol.implicitHeight + 20
        activeFocusOnTab: true
        Keys.onReturnPressed: img.pickLevel(data_.level)
        Keys.onEnterPressed: img.pickLevel(data_.level)
        Keys.onSpacePressed: img.pickLevel(data_.level)
        Rectangle {   // тінь
            anchors { fill: parent; topMargin: 6; bottomMargin: -4; leftMargin: 3; rightMargin: 3 }
            radius: ap.cardRadius + 2
            color: ap.shadow
            opacity: lc.on ? 0.6 : 0.35
        }
        Rectangle {
            id: lcFace
            anchors.fill: parent
            radius: ap.cardRadius
            color: lc.on ? "#2e1a3a" : ap.card
            border.width: lc.ring ? 2 : 1
            border.color: lc.ring ? ap.cyan : (lc.on ? ap.accent : (lc.hot ? ap.edgeHi : ap.cardEdge))
            Rectangle {   // підсвітка під наведенням: згасанням, без анімації кольору
                anchors.fill: parent
                anchors.margins: 1
                radius: parent.radius - 1
                color: "#14ffffff"
                opacity: lc.hot && !lc.on ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            }
            transform: Translate { y: lc.hot && !lcMouse.pressed ? -ap.lift : 0; Behavior on y { NumberAnimation { duration: ap.tHover } } }
            scale: lcMouse.pressed ? ap.pressScale : 1
            Behavior on scale { NumberAnimation { duration: ap.tPress } }
            Rectangle { x: 1; y: 1; width: parent.width - 2; height: 1; color: ap.cardTop }
            ColumnLayout {
                id: lcCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                spacing: 6
                Item {   // приклад
                    id: tile
                    Layout.fillWidth: true
                    implicitHeight: width * 9 / 16
                    Scene { anchors.fill: parent; detail: lc.data_.level }
                    Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: "#33ffffff" }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        onEntered: { img.hoverLevel = lc.data_.level; img.hoverTile = tile; }
                        onExited: if (img.hoverTile === tile) { img.hoverLevel = -1; img.hoverTile = null; }
                    }
                    Rectangle {   // позначка «обрано»
                        visible: lc.on
                        anchors { right: parent.right; top: parent.top; margins: 6 }
                        width: 22; height: 22; radius: 11
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                        Text { anchors.centerIn: parent; text: "✓"; color: ap.inkAccent; font.pixelSize: 13; font.bold: true }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: lc.data_.name
                    elide: Text.ElideRight
                    font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: img.compact ? 16 : 18
                    font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    color: lc.on ? ap.ink : ap.mute
                }
                ApText { Layout.topMargin: -4; role: "small"; color: ap.mute; text: lc.data_.res }
                ApText {
                    visible: !img.compact
                    Layout.fillWidth: true
                    role: "small"; color: ap.faint
                    wrapMode: Text.WordWrap
                    text: lc.data_.sub
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 4
                    ApChip { text: lc.width < 250 ? lc.data_.netShort : lc.data_.net }
                    ApChip { visible: !!lc.mark; text: lc.mark ? lc.mark.text : ""; kind: lc.mark ? lc.mark.kind : "" }
                }
            }
        }
        MouseArea {
            id: lcMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { lc.byMouse = true; lc.forceActiveFocus(); lc.byMouse = true; img.pickLevel(lc.data_.level); }
        }
    }

    // ── повзунок кольорів: тонка лінія від середини (типово) до ручки ──
    component PicSlider: Slider {
        id: ps
        property bool mid: true
        focusPolicy: Qt.StrongFocus
        background: Rectangle {
            x: ps.leftPadding
            y: ps.topPadding + ps.availableHeight / 2 - height / 2
            width: ps.availableWidth
            height: 2
            color: "#40ffffff"
            Rectangle {
                readonly property real m: ps.mid ? parent.width / 2 : 0
                readonly property real pos: ps.visualPosition * parent.width
                x: Math.min(m, pos); width: Math.abs(pos - m); height: parent.height
                color: ap.ink
            }
            Rectangle { visible: ps.mid; x: parent.width / 2 - 1; y: -4; width: 2; height: 10; color: "#80ffffff" }
        }
        handle: Rectangle {
            x: ps.leftPadding + ps.visualPosition * (ps.availableWidth - width)
            y: ps.topPadding + ps.availableHeight / 2 - height / 2
            width: 14; height: 14; radius: 7
            color: ap.ink
            border.width: ps.visualFocus ? 2 : 0
            border.color: ap.cyan
        }
    }

    // ── перевірка інтернету (головне вікно): як було на вкладці «Якість» ──
    component SpeedCard: ApCard {
        id: speedCol
        readonly property var sp: Chiaki.speedTest || null
        readonly property bool done: !!sp && sp.stage === "done" && sp.downMbps >= 0
        readonly property int rec: done ? sp.recommendedLevel : -1
        readonly property int applyLevel: rec === 2 && img.cloud.qualityLevel === 3 ? 3 : rec   // «Ультра» лишаємо, якщо вже стоїть
        spacing: 10
        function fmt(x) { return x >= 100 ? Math.round(x).toString() : x.toFixed(1).replace(".", ","); }
        ApText { role: "cap"; text: qsTr("Перевірити інтернет") }
        ApText {
            Layout.fillWidth: true
            role: "small"
            text: qsTr("Необов'язково. Перевіряє інтернет цього комп'ютера: швидкість і затримку. Гра ще залежить від того, Wi-Fi чи кабель: з кабелем стабільніше.")
        }
        ApButton {
            ghost: true
            focusPolicy: Qt.StrongFocus
            text: speedCol.sp && speedCol.sp.running ? qsTr("Зупинити") : (speedCol.done ? qsTr("Перевірити ще раз") : qsTr("Перевірити інтернет"))
            onClicked: speedCol.sp.running ? speedCol.sp.cancel() : speedCol.sp.start(true)
        }
        Rectangle {
            visible: !!speedCol.sp && speedCol.sp.running
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            color: ap.hair
            Rectangle { height: parent.height; width: parent.width * (speedCol.sp ? speedCol.sp.progress : 0); color: ap.ink }
        }
        ApText {
            visible: !!speedCol.sp && speedCol.sp.running
            role: "small"
            text: !speedCol.sp ? "" : speedCol.sp.stage === "ping" ? qsTr("Міряємо затримку…")
                : speedCol.sp.stage === "down" ? qsTr("Міряємо швидкість завантаження…") : qsTr("Міряємо віддачу…")
        }
        ApText { visible: !!speedCol.sp && speedCol.sp.error !== ""; Layout.fillWidth: true; color: ap.bad; text: speedCol.sp ? speedCol.sp.error : "" }
        Flow {
            visible: speedCol.done
            Layout.fillWidth: true
            spacing: 6
            ApChip { text: speedCol.done ? qsTr("швидкість %1 Мбіт/с").arg(speedCol.fmt(speedCol.sp.downMbps)) : "" }
            ApChip {
                text: speedCol.done && speedCol.sp.pingMs >= 0 ? qsTr("затримка %1 мс").arg(Math.round(speedCol.sp.pingMs)) : qsTr("затримка невідома")
                kind: speedCol.done && speedCol.sp.pingMs >= 0 ? (speedCol.sp.pingMs <= 40 ? "ok" : (speedCol.sp.pingMs > 80 ? "wait" : "")) : ""
            }
            ApChip { visible: speedCol.done && speedCol.sp.upMbps >= 0; text: speedCol.done ? qsTr("віддача %1 Мбіт/с").arg(speedCol.fmt(speedCol.sp.upMbps)) : "" }
            ApChip { kind: "ok"; text: speedCol.done ? qsTr("підійде: %1").arg(speedCol.rec === 2 ? qsTr("Максимальна або Ультра") : speedCol.rec === 1 ? qsTr("Оптимальна") : qsTr("Економна")) : "" }
        }
        ApText { visible: speedCol.done; role: "small"; color: ap.faint; text: qsTr("Затримка до 40 мс добре, понад 80 мс гра може відставати.") }
        ApButton {
            visible: speedCol.done
            Layout.topMargin: 6
            readonly property bool same: !img.cloud.autoQuality && img.cloud.qualityLevel === speedCol.applyLevel
            enabled: speedCol.rec >= 0 && !same
            focusPolicy: Qt.StrongFocus
            text: same ? qsTr("Застосовано") : qsTr("Застосувати: %1").arg(img.levelNames[Math.max(0, speedCol.applyLevel)])
            onClicked: img.pickLevel(speedCol.applyLevel)
        }
        ApText {
            visible: speedCol.done && img.cloud.autoQuality
            Layout.fillWidth: true
            role: "small"
            text: qsTr("Зараз увімкнено «Авто». Якщо застосуєш пораду, якість стане сталою.")
        }
    }
}
