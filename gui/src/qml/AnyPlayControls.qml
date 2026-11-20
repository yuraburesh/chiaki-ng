// AnyPlay: екран клавіш. Ліворуч угорі розкладка під гру і режими, посередині фото геймпада з підписами
// й лініями до кнопок, нижче інші дії. Клацни на клавішу, щоб змінити її. Поза грою екран живий:
// клавіші й миша одразу світять кнопки на геймпаді — тим самим рушієм, що й у грі (що бачиш, те й отримає приставка).
// inGame: true — у меню під час гри: щільніше, без великого заголовка; живий показ лише з клавіатури й миші.
import QtQuick
import QtQuick.Controls
import org.streetpea.chiaking

Item {
    id: root
    property bool inGame: false
    // поля зліва й справа: вміст стоїть усередині, смуга прокрутки — у правому полі, біля краю
    // (вкладка головного екрана дає поля сторінки, щоб усе стояло рівно під верхньою смугою)
    property real sideInset: 6
    signal closeRequested()
    signal pickerRequested()   // «Показати вибір перед грою» поза грою: показати «У що граєш?» одразу

    AnyPlayStyle { id: ap }

    // ── сталі з прототипу ──
    readonly property var sideL: ["L2", "L1", "TOUCHPAD", "SHARE", "DPAD_UP", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_DOWN", "L3", "LS"]
    readonly property var sideR: ["R2", "R1", "OPTIONS", "PYRAMID", "MOON", "BOX", "CROSS", "R3", "RS", "PS"]
    readonly property var padName: ({ TOUCHPAD: "▭", L1: "L1", L2: "L2", R1: "R1", R2: "R2", SHARE: "⋮", OPTIONS: "≡", DPAD_UP: "↑", DPAD_DOWN: "↓",
                                      DPAD_LEFT: "←", DPAD_RIGHT: "→", PYRAMID: "△", MOON: "○", CROSS: "✕", BOX: "□", L3: "L3", R3: "R3", LS: "L", RS: "R", PS: "PS" })
    readonly property var padLong: ({ TOUCHPAD: "Тачпад", L1: "L1", L2: "L2", R1: "R1", R2: "R2", SHARE: "Кнопка Create", OPTIONS: "Кнопка Options",
                                      DPAD_UP: "Хрестовина вгору", DPAD_DOWN: "Хрестовина вниз", DPAD_LEFT: "Хрестовина вліво", DPAD_RIGHT: "Хрестовина вправо",
                                      PYRAMID: "Трикутник", MOON: "Коло", CROSS: "Хрестик", BOX: "Квадрат", L3: "Лівий стік", R3: "Правий стік", PS: "Кнопка PS" })
    readonly property var ownOf: ({ LS: "L3", RS: "R3" })
    readonly property real padW: 1084       // одиниці малюнка геймпада (як viewBox прототипу: 0 -16 1084 733)
    readonly property real padH: 733
    readonly property real padTop: 16

    // ── дані: розкладка, режим, очікування клавіші ──
    readonly property var gpd: Chiaki.settings.anyplayPadData()
    property var occ: null
    property var layouts: Chiaki.settings.anyplayLayouts()
    property var cfg: ({ layout: "", start: "foot", profiles: [] })
    property string mode: "foot"
    // чутливість миші своя пішки і в транспорті (авіація — як транспорт); вкладка «Меню» показує пішки
    readonly property bool vehicleSens: mode === "vehicle" || mode === "air"
    readonly property real sensNow: vehicleSens ? Chiaki.settings.anyplayVehicleSensitivity : Chiaki.settings.anyplayMouseSensitivity
    function setSens(v) { if (vehicleSens) Chiaki.settings.anyplayVehicleSensitivity = v; else Chiaki.settings.anyplayMouseSensitivity = v; }
    property var waiting: null              // {p, id, name}: чекаємо нову клавішу для цієї дії
    readonly property var view: buildView(cfg, mode)
    readonly property alias wireData: wires.wd    // лінії (для перевірки)

    // ── живий показ: що натиснуто ──
    readonly property bool live: visible && (inGame || !Chiaki.session)   // у меню гри теж: клавіші підсвічують кнопки геймпада
    property var engine: ({ buttons: [], lx: 0, ly: 0, rx: 0, ry: 0, profile: "" })
    property string clickBtn: ""            // кнопка, яку тиснуть мишею просто на малюнку
    property var rsv: [0, 0]                // правий стік від руху миші (для показу)
    property var held: ({})                 // утримувані клавіші і кнопки миші
    property string lastKey: ""
    property real wheelAt: 0
    readonly property var onMap: computeOn(engine, clickBtn, rsv, pad)
    property var logLines: [qsTr("Просто тисни клавіші, кнопки миші, крути колесо над геймпадом і рухай мишею: джойстик покаже, що отримає приставка.")]

    // ── допоміжне ──
    function clean(n) { return String(n || "").replace(/\s*\((?:утримувати\s*)?[LR][123]\)|\s*\([✕○□△]\)|\s*\(тачпад\)|\s*\(утримувати\)/g, ""); }
    function kname(k) { return k ? Chiaki.settings.anyplayDisplayName(k) : qsTr("немає"); }
    function stripIcon(n) { return String(n || "").replace(/^\S+\s/, ""); }
    function profOf(c, id) { for (let i = 0; i < c.profiles.length; i++) if (c.profiles[i].id === id) return c.profiles[i]; return null; }
    function prof(id) { return profOf(cfg, id); }
    function tagged(p) { return p ? p.bindings.map((b) => Object.assign({ p: p.id }, b)) : []; }
    function ownList(c, m) { return m === "global" ? [] : tagged(profOf(c, m)); }
    function globalList(c) { return tagged(profOf(c, "global")); }
    function plain(b) { const d = b["do"] || ""; return b.btn && b.btn.length === 1 && !b.when && (d === "" || d === "tap" || d === "turbo" || d === "toggle"); }
    function pnOf(b) { return (b.btn || []).map((x) => padName[x]).join("+"); }
    // у прицілі дія інша (колесо в GTA VI: △)
    function aimPn(b) { return b.aim && b.aim.btn ? b.aim.btn.map((x) => padName[x]).join("+") : (b.aim && b.aim.r ? qsTr("правий стік") : ""); }
    // де діє інший варіант: у прицілі (L2) чи поки відкрите колесо зброї (L1)
    function aimWhere(b) { return b.aim && b.aim.when === "L1" ? qsTr("у колесі зброї") : qsTr("у прицілі"); }
    function aimNow(b) { return !!(b.aim && b.aim.when) && (engine.buttons || []).indexOf(b.aim.when) >= 0; }
    function howOf(b) {
        const d = b["do"] || "", pn = pnOf(b);
        if (d === "macro") return b.hold ? qsTr("натисни або тримай") : qsTr("комбінація");
        if (d === "cycle") return aimPn(b) ? qsTr("по колу; у прицілі: %1").arg(aimPn(b)) : qsTr("по колу");
        if (b.when) return pn + qsTr(", у прицілі");
        if (b.profile && !b.btn) return qsTr("режим");
        return pn;
    }
    // головна дія кнопки геймпада в цьому режимі: спершу з режиму, потім зі спільних клавіш
    function mainOf(c, m, btn) {
        const ok = (b) => plain(b) && b.btn[0] === btn && !b.x;
        const own = ownList(c, m);
        return own.find((b) => ok(b) && !b.profile) || own.find(ok) || globalList(c).find(ok) || null;
    }
    function rowName(c, m, btn, b) {
        const labels = (m !== "global" && profOf(c, m) && profOf(c, m).labels) || {};
        return (b.p === "global" && m !== "global" && labels[btn]) || clean(b.name);
    }
    function chipOf(b) { return { p: b.p, id: b.id, key: b.key, keyName: b.keyName, name: b.name }; }

    function buildView(c, m) {
        const v = { modes: [], title: "", hint: "", left: [], right: [], extra: [] };
        if (!c.profiles.length || !profOf(c, m))
            return v;
        const glob = globalList(c), own = ownList(c, m);
        const modeKey = (id) => { const b = glob.find((x) => x.profile === id && x["do"] === "none"); return b && b.key ? b.key : ""; };
        v.modes = c.profiles.filter((p) => p.id !== "global").map((p) => ({ id: p.id, name: stripIcon(p.name), key: modeKey(p.id) }));
        v.modes.push({ id: "global", name: qsTr("Меню"), key: "" });
        if (c.profiles.length > 2) {
            const foot = profOf(c, "foot"), ent = foot ? tagged(foot).find((x) => x.profile === "toggle") : null;
            const keys = ["foot", "vehicle", "air"].map(modeKey).filter((k) => k);
            v.hint = qsTr("Режим у грі перемикається сам: ")
                + (ent && ent.key ? qsTr("сів у транспорт або вийшов клавішею %1. ").arg(bold(kname(ent.key))) : "")
                + (keys.length ? qsTr("Якщо треба вручну: %1 (на MacBook: Fn + F1), або клацни вкладку тут.").arg(keys.map((k) => bold(kname(k))).join(", "))
                               : qsTr("Клацни вкладку, щоб побачити клавіші."));
            // колесо зброї: поки тримаєш його клавішу, сектор обирають ще й клавішами руху
            const wheel = foot ? tagged(foot).find((x) => x.btn && x.btn.length === 1 && x.btn[0] === "L1" && !x["do"]) : null;
            const up = foot ? tagged(foot).find((x) => x.aim && x.aim.when === "L1" && x.aim.r) : null;
            v.hintShort = "";
            if (wheel && wheel.key && up)
                v.hintShort = qsTr("Колесо зброї: тримай %1 і обирай сектор клавішами %2, коліщатком або мишею.")
                    .arg(bold(kname(wheel.key))).arg(["up", "left", "down", "right"].map((id) => { const b = tagged(foot).find((x) => x.id === id); return b && b.key ? bold(kname(b.key)) : ""; }).filter((k) => k).join(" "));
            if (wheel && wheel.key && up)
                v.hint += qsTr("<br>Колесо зброї: тримай %1 і обирай сектор клавішами %2, коліщатком або мишею. Цифра зброї: натисни, щоб одразу взяти, або тримай, щоб колесо лишилось відкритим.")
                    .arg(bold(kname(wheel.key))).arg(["up", "left", "down", "right"].map((id) => { const b = tagged(foot).find((x) => x.id === id); return b && b.key ? bold(kname(b.key)) : ""; }).filter((k) => k).join(" "));
        } else {
            v.hint = qsTr("Для цієї розкладки один набір клавіш на все.");
        }
        v.title = m === "global" ? qsTr("Меню") : stripIcon(profOf(c, m).name);
        const labels = (m !== "global" && profOf(c, m).labels) || {};
        const shown = {};
        const active = own.concat(glob);
        const rowFor = (btn) => {
            const r = { btn: btn, pad: padName[btn], name: "", chips: [], fixed: "" };
            if (btn === "LS") {
                const mv = active.filter((b) => b.l && b.l.length === 2);
                mv.forEach((b) => shown[b.p + "/" + b.id] = true);
                if (mv.length) { r.name = labels.LS || qsTr("Рух"); r.chips = mv.map(chipOf); }
            } else if (btn === "RS") {
                r.name = labels.RS || qsTr("Камера"); r.fixed = qsTr("Миша");
            } else {
                const b = mainOf(c, m, btn);
                if (b) { shown[b.p + "/" + b.id] = true; r.name = rowName(c, m, btn, b); r.chips = [chipOf(b)]; }
            }
            return r;
        };
        v.left = sideL.map(rowFor);
        v.right = sideR.map(rowFor);
        const ex = (m === "global" ? glob : own).filter((b) => !shown[b.p + "/" + b.id]);
        const groups = [];
        for (const b of ex) {
            const g = groups.find((x) => x[0].name === b.name && howOf(x[0]) === howOf(b) && !b.steps);
            if (g) g.push(b); else groups.push([b]);
        }
        v.extra = groups.map((g) => {
            let h = howOf(g[0]);
            if (h && h === pnOf(g[0])) h = qsTr("на джойстику: ") + h;
            return { name: clean(g[0].name), how: h, chips: g.map(chipOf) };
        });
        return v;
    }
    function bold(t) { return "<font color=\"#ffffff\"><b>" + String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</b></font>"; }

    function computeOn(e, click, r, g) {
        const o = {};
        for (const b of e.buttons || []) o[b] = true;
        for (const b of g.buttons || []) o[b] = true;
        if (click) o[click] = true;
        if (e.lx || e.ly || g.lx || g.ly) o.LS = true;
        if (r[0] || r[1] || e.rx || e.ry || g.rx || g.ry) o.RS = true;
        return o;
    }
    function clamp1(x) { return Math.max(-1, Math.min(1, x)); }
    readonly property var lsVec: [clamp1((engine.lx || 0) + (pad.lx || 0)), clamp1((engine.ly || 0) + (pad.ly || 0))]
    readonly property var rsVec: [clamp1((engine.rx || 0) + rsv[0] + (pad.rx || 0)), clamp1((engine.ry || 0) + rsv[1] + (pad.ry || 0))]

    // ── справжній геймпад (поза грою): його кнопки, курки й стіки світяться так само, як від клавіш ──
    property var pad: ({ buttons: [], lx: 0, ly: 0, rx: 0, ry: 0 })
    readonly property var pads: live ? Chiaki.controllers : []
    readonly property string padStatus: Chiaki.controllers.length
        ? qsTr("Геймпад: %1 підключено").arg(String(Chiaki.controllers[0].name || qsTr("геймпад")).replace(/\s*\(.*$/, "").slice(0, 40))
        : qsTr("Геймпад: підключи і натисни будь-яку кнопку")
    function readPads() {
        const o = { buttons: [], lx: 0, ly: 0, rx: 0, ry: 0 };
        const big = (a, b) => Math.abs(b) > Math.abs(a) ? b : a;
        for (let i = 0; i < pads.length; i++) {
            const st = pads[i] ? pads[i].padState : null;
            if (!st || !st.buttons)
                continue;
            for (const b of st.buttons)
                if (o.buttons.indexOf(b) < 0) o.buttons.push(b);
            o.lx = big(o.lx, st.lx || 0); o.ly = big(o.ly, st.ly || 0);
            o.rx = big(o.rx, st.rx || 0); o.ry = big(o.ry, st.ry || 0);
        }
        const was = pad.buttons || [];
        for (const b of o.buttons) {
            if (was.indexOf(b) >= 0 || !padName[b])
                continue;
            const a = mainOf(cfg, mode, b);
            log(qsTr("Геймпад %1").arg(padName[b]) + (a ? " → " + rowName(cfg, mode, b, a) : qsTr(": у цьому режимі нічого")));
        }
        pad = o;
    }
    onPadsChanged: readPads()
    Repeater {
        model: root.pads
        Item {
            required property var modelData
            Connections { target: modelData; function onPadStateChanged() { root.readPads(); } }
        }
    }

    // ── дії ──
    function reload() {
        cfg = Chiaki.settings.anyplayControls();
        layouts = Chiaki.settings.anyplayLayouts();
        if (!prof(mode))
            mode = cfg.start || "foot";
    }
    function layoutIndex() { for (let i = 0; i < layouts.length; i++) if (layouts[i].id === cfg.layout) return i; return 0; }
    function setLayout(id) {
        cancelWait();
        Chiaki.settings.setAnyplayLayout(id);
        cfg = Chiaki.settings.anyplayControls();
        mode = cfg.start || "foot";
        releaseAll();
        if (live)
            Chiaki.settings.anyplayPreviewSetProfile(mode);
    }
    function setMode(id) {
        cancelWait();
        if (!prof(id) || id === mode)
            return;
        mode = id;
        releaseAll();
        if (live)
            Chiaki.settings.anyplayPreviewSetProfile(id);
    }
    function toast(t) { toastText = t; toastTimer.restart(); }
    property string toastText: ""
    function log(t) { logLines = [t].concat(logLines).slice(0, 3); }

    function startWait(chip) {
        if (waiting && waiting.p === chip.p && waiting.id === chip.id) { cancelWait(); return; }
        releaseAll();
        waiting = { p: chip.p, id: chip.id, name: chip.name };
        root.forceActiveFocus();
    }
    function cancelWait() { waiting = null; }
    function assign(key) {
        if (!waiting)
            return;
        const w = waiting;
        waiting = null;
        if (key === "`") { toast(qsTr("Клавіша ` відкриває меню AnyPlay")); return; }
        const r = Chiaki.settings.anyplayRebind(w.p, w.id, key);
        if (!r.ok) {
            if (r.reason === "menu") toast(qsTr("Клавіша ` відкриває меню AnyPlay"));
            return;
        }
        if (r.reason === "same")
            return;
        const cl = r.cleared || [];
        if (cl.length === 1)
            toast(qsTr("%1 була на дії «%2». Та дія тепер без клавіші.").arg(kname(key)).arg(clean(cl[0].name)));
        else if (cl.length > 1)
            toast(qsTr("%1 була на діях %2. Ці дії тепер без клавіші.").arg(kname(key)).arg(cl.map((x) => "«" + clean(x.name) + "»").filter((x, i, a) => a.indexOf(x) === i).join(", ")));
        else
            toast(key ? qsTr("«%1» тепер на %2").arg(clean(w.name)).arg(kname(key)) : qsTr("З дії «%1» клавішу прибрано").arg(clean(w.name)));
        cfg = Chiaki.settings.anyplayControls();
    }
    function resetKeys() {
        cancelWait();
        Chiaki.settings.resetAnyplayKeys();
        cfg = Chiaki.settings.anyplayControls();
        releaseAll();
        toast(qsTr("Повернуто стандартні клавіші для «%1»").arg(layouts[layoutIndex()] ? layouts[layoutIndex()].name : ""));
    }
    function askBeforeGame() {
        cancelWait();
        Chiaki.settings.anyplayAskGame = true;
        if (inGame)
            toast(qsTr("Перед наступною грою програма спитає, у що граєш"));
        else
            pickerRequested();   // головний екран одразу покаже «У що граєш?»
    }

    // ── живий показ ──
    function releaseAll() {
        held = ({});
        clickBtn = "";
        Chiaki.settings.anyplayPreviewRelease();
    }
    function findActive(k) {
        const lk = String(k).toLowerCase(), m = (b) => String(b.key || "").toLowerCase() === lk;
        return ownList(cfg, mode).find(m) || globalList(cfg).find(m) || null;
    }
    function previewKey(k, down) {
        if (!k)
            return;
        if (k === "`") { if (down) log(qsTr("`: відкриває меню AnyPlay (у грі)")); return; }
        const lab = kname(k);
        if (!down) {
            if (held[k]) { const h = Object.assign({}, held); delete h[k]; held = h; Chiaki.settings.anyplayPreviewInput(k, false); }
            return;
        }
        if (held[k])
            return;
        const b = findActive(k);
        if (!b) { log(qsTr("%1: нічого не призначено").arg(lab)); return; }
        lastKey = lab;
        const nm = clean(b.name), pn = pnOf(b), d = b["do"] || "";
        if (b.when && (engine.buttons || []).indexOf(b.when) < 0)
            log(qsTr("%1: «%2» працює лише в прицілі").arg(lab).arg(nm));
        else if (aimNow(b)) log(lab + " → " + aimPn(b) + qsTr(", поки тримаєш (%1): ").arg(aimWhere(b)) + nm);
        else if (d === "cycle") log(lab + " → " + nm + qsTr(" (по колу)"));
        else if (d === "macro") log(lab + " → " + nm + qsTr(" (комбінація)"));
        else if (b.l && b.l.length === 2) log(lab + " → " + qsTr("лівий стік: ") + nm);
        else if (b.btn) log(lab + " → " + pn + qsTr(", поки тримаєш: ") + nm);
        const h = Object.assign({}, held); h[k] = true; held = h;
        Chiaki.settings.anyplayPreviewInput(k, true);
    }
    // коротке натискання: поділка коліщатка (і Caps Lock на Mac, де відпускання не приходить)
    function previewTap(k) {
        const b = findActive(k);
        if (!b)
            return false;
        const lab = kname(k), nm = clean(b.name), d = b["do"] || "";
        lastKey = lab;
        if (b.when && (engine.buttons || []).indexOf(b.when) < 0) log(qsTr("%1: «%2» працює лише в прицілі").arg(lab).arg(nm));
        else if (aimNow(b)) log(lab + " → " + aimPn(b) + qsTr(" коротко (%1): ").arg(aimWhere(b)) + nm);
        else if (d === "cycle") log(lab + " → " + nm + qsTr(" (по колу)"));
        else if (d === "macro") log(lab + " → " + nm + qsTr(" (комбінація)"));
        else log(lab + " → " + pnOf(b) + qsTr(" коротко: ") + nm);
        Chiaki.settings.anyplayPreviewTap(k);
        return true;
    }
    function mouseName(button) { return button === Qt.LeftButton ? "MouseLeft" : button === Qt.RightButton ? "MouseRight" : button === Qt.MiddleButton ? "MouseMiddle" : ""; }
    function keyName(e) { return Chiaki.settings.anyplayKeyName(e.key, e.modifiers, e.text, e.nativeScanCode || 0); }
    function wheelKey(w) { const dy = w.angleDelta.y || w.pixelDelta.y; return dy > 0 ? "WheelUp" : dy < 0 ? "WheelDown" : ""; }

    Connections {
        target: Chiaki.settings
        function onAnyplayPreviewChanged() {
            if (!root.live)
                return;
            const st = Chiaki.settings.anyplayPreviewState();
            root.engine = st;
            // режим перемкнула клавіша (F, F1–F3): вкладка йде слідом
            if (st.profile && st.profile !== root.mode && root.prof(st.profile)) {
                root.mode = st.profile;
                root.log(qsTr("режим: %1").arg(st.profile === "global" ? qsTr("Меню") : root.stripIcon(root.prof(st.profile).name)) + (root.lastKey ? qsTr(" (клавіша %1)").arg(root.lastKey) : ""));
            }
        }
    }
    onLiveChanged: {
        Chiaki.settings.anyplayPadPreview(live);   // поки екран живий, геймпад не ходить по меню, а світить кнопки
        if (live && Chiaki.controllers.length)
            log(qsTr("Підключено геймпад. Натискай кнопки: на схемі засвітиться те саме"));
        releaseAll();
        engine = ({ buttons: [], lx: 0, ly: 0, rx: 0, ry: 0, profile: "" });
        rsv = [0, 0];
        if (live) {
            Chiaki.settings.anyplayPreviewSetProfile(mode);
            root.forceActiveFocus();
        }
    }
    Connections {
        target: Qt.application
        function onStateChanged() { if (Qt.application.state !== Qt.ApplicationActive) root.releaseAll(); }
    }
    Connections {
        target: Chiaki
        function onControllersChanged() {
            if (root.live)
                root.log(Chiaki.controllers.length ? qsTr("Підключено геймпад. Натискай кнопки: на схемі засвітиться те саме") : qsTr("Геймпад відключено"));
        }
    }
    Connections {
        target: Chiaki.settings
        function onAnyplayControlsChanged() { if (!root.waiting) root.reload(); }
    }
    // правий стік від руху миші плавно повертається до центру
    Timer {
        id: rsDecay
        interval: 16; repeat: true
        onTriggered: {
            const v = root.rsv.map((x) => Math.abs(x) < 0.02 ? 0 : x * 0.82);
            root.rsv = v;
            if (!v[0] && !v[1]) stop();
        }
    }
    Timer { id: toastTimer; interval: 3200; onTriggered: root.toastText = "" }

    Component.onCompleted: {
        // сітка зайнятості: які клітинки 4×4 одиниці зайняті якою кнопкою (щоб лінії не перетинали інші кнопки)
        const g = gpd.occ, w = Math.ceil(gpd.size[0] / g.g) + 1, h = Math.ceil(gpd.size[1] / g.g) + 1, a = new Uint8Array(w * h);
        for (const s of g.spans) a.fill(s[3], s[0] * w + s[1], s[0] * w + s[2] + 1);
        occ = { a: a, w: w, h: h, g: g.g, names: g.names };
        reload();
        mode = cfg.start || "foot";
        if (live) {
            Chiaki.settings.anyplayPreviewSetProfile(mode);
            if (!inGame)
                Chiaki.settings.anyplayPadPreview(true);   // у грі геймпад лишається грі
        }
        // фокус беремо, лише коли екран справді показаний (інакше прихована вкладка забрала б клавіші в інших);
        // у меню гри — ні: там фокус лишається на пунктах ліворуч, доки не клацнеш тут чи не натиснеш Enter / →
        if (visible && !inGame) root.forceActiveFocus();
    }
    onVisibleChanged: {
        fitTimer.restart();
        if (visible && inGame) Chiaki.settings.anyplayPreviewSetProfile(mode);
        if (visible && !inGame) root.forceActiveFocus();
        else if (!visible) cancelWait();
    }
    Component.onDestruction: {
        Chiaki.settings.anyplayPreviewRelease();
        if (!inGame)
            Chiaki.settings.anyplayPadPreview(false);   // геймпад знову ходить по меню програми
    }

    // ── клавіатура ──
    focus: true
    Keys.onPressed: (e) => {
        const k = keyName(e);
        if (waiting) {
            e.accepted = true;
            if (e.isAutoRepeat) return;
            if (e.key === Qt.Key_Escape) cancelWait();
            else if (e.key === Qt.Key_Backspace) assign("");
            else if (k) assign(k);
            return;
        }
        if (inGame && e.key === Qt.Key_Escape) { e.accepted = true; closeRequested(); return; }
        if (!live || !k)
            return;
        e.accepted = !!findActive(k) || k === "`";
        if (Qt.platform.os === "osx" && k === "CapsLock") { previewTap(k); return; }
        if (!e.isAutoRepeat)
            previewKey(k, true);
    }
    Keys.onReleased: (e) => {
        if (waiting || !live || e.isAutoRepeat)
            return;
        const k = keyName(e);
        if (Qt.platform.os === "osx" && k === "CapsLock") { previewTap(k); return; }
        if (held[k]) e.accepted = true;
        previewKey(k, false);
    }

    // рух миші нахиляє правий стік (камера) з тією самою чутливістю та інверсією, що й у грі
    HoverHandler {
        id: hover
        property point last: Qt.point(-1, -1)
        onPointChanged: {
            const p = point.position;
            if (last.x >= 0 && root.live) {
                const s = root.sensNow, inv = Chiaki.settings.anyplayInvertY ? -1 : 1;
                const dx = (p.x - last.x) / 25 * s, dy = (p.y - last.y) / 25 * s * inv;
                if (dx || dy) {
                    root.rsv = [Math.max(-1, Math.min(1, root.rsv[0] + dx)), Math.max(-1, Math.min(1, root.rsv[1] + dy))];
                    rsDecay.start();
                }
            }
            last = p;
        }
    }

    // ── усе на одній сторінці: якщо не вміщується, зменшуємо малюнок геймпада (прокрутка лишається тільки на крайній випадок) ──
    property real gpCap: 540
    // низьке вікно в меню гри (ноутбук 13"): щільніші рядки й без зайвого, щоб усе вмістилось без прокрутки
    readonly property bool tight: inGame && flick.height > 0 && flick.height < 800
    readonly property bool tighter: tight && flick.height < 670   // 1366×768 і менше
    // висота рядка підписів і «Інших дій»: якщо геймпад уже найменший, а сторінка ще не вміщується, рядки щільнішають
    readonly property real baseRow: tighter ? 23 : tight ? 26 : 31
    property real rowH: 31
    onBaseRowChanged: { rowH = baseRow; fitTimer.restart(); }
    function refit() {
        if (!visible || flick.height < 200)
            return;
        const over = page.height - flick.height, gh = gp.height;
        const floorH = page.narrow ? 150 : Math.max(150, Math.max(colL.height, colR.height) - 10);   // нижче за стовпці підписів зменшувати нема сенсу
        if (over > 1 && gh > floorH + 1)
            gpCap = Math.max(floorH, gh - over - 2) * padW / padH;
        else if (over > 1 && rowH > 17) {
            rowH = Math.max(17, rowH - Math.max(1, Math.ceil(over / 24)));
            fitTimer.restart();
        } else if (over < -40 && rowH < baseRow) {
            rowH = Math.min(baseRow, rowH + 1);
            fitTimer.restart();
        } else if (over < -24 && gpCap < 540)
            gpCap = Math.min(540, (gh - over - 12) * padW / padH);
    }
    Timer { id: fitTimer; interval: 40; onTriggered: root.refit() }
    Connections { target: page; function onHeightChanged() { fitTimer.restart(); } }
    Connections { target: flick; function onHeightChanged() { fitTimer.restart(); } }

    // ── прокрутка ──
    Flickable {
        id: flick
        anchors.fill: parent
        interactive: false
        clip: true
        contentWidth: width
        contentHeight: page.height
        ScrollBar.vertical: ScrollBar {
            policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#40ffffff" }
        }

        // тло: кнопки миші для живого показу і для призначення, колесо для прокрутки
        MouseArea {
            width: flick.width
            height: Math.max(flick.height, page.height)
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            property string down: ""
            onPressed: (m) => {
                root.forceActiveFocus();
                const n = root.mouseName(m.button);
                if (root.waiting) { if (n) root.assign(n); return; }
                if (root.live && n) { down = n; root.previewKey(n, true); }
            }
            onReleased: (m) => { const n = root.mouseName(m.button); if (n && n === down) { down = ""; root.previewKey(n, false); } }
            onCanceled: { if (down) { root.previewKey(down, false); down = ""; } }
            onWheel: (w) => {
                if (root.waiting) { const k = root.wheelKey(w); if (k) root.assign(k); return; }
                const dy = w.pixelDelta.y ? w.pixelDelta.y : w.angleDelta.y / 120 * 60;
                flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY - dy));
            }
        }

        Column {
            id: page
            readonly property real cw: Math.min(1440, root.width - 2 * root.sideInset)
            readonly property bool narrow: cw <= (root.inGame ? 600 : 900)   // у меню гри ліворуч список розділів, тож місця менше
            x: (root.width - cw) / 2
            width: cw
            topPadding: 0
            bottomPadding: root.tighter ? 2 : root.inGame ? 12 : 28
            spacing: 0
            // відступи між частинами — як у прототипі (12 між заголовком і екраном, 10 поля екрана, 14 під верхом, 8 між частинами)

            // заголовок
            Item {
                visible: !root.inGame
                width: page.cw
                height: h1.implicitHeight
                Text {
                    id: h1
                    objectName: "apH1"
                    text: qsTr("Керування AnyPlay")
                    color: ap.ink
                    font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 22; font.letterSpacing: 1.5
                    font.capitalization: Font.AllUppercase
                }
            }

            Gap { height: root.inGame ? 0 : 21 }
            // ── верх: розкладка, режим, кнопки й миша ──
            Item {
                id: side
                objectName: "apSide"
                width: page.cw
                readonly property real gapX: 28
                readonly property bool modesInline: pickBlock.width + gapX + modesBlock.width <= width
                readonly property bool actsInline: modesInline && pickBlock.width + gapX + modesBlock.width + gapX + actsBlock.width <= width
                height: Math.max(pickBlock.height, modesInline ? modesBlock.height : pickBlock.height + 12 + modesBlock.height,
                                 actsInline ? actsBlock.y + actsBlock.height : 0, actsBlock.y + actsBlock.height)

                Column {
                    id: pickBlock
                    spacing: 5
                    Cap { text: qsTr("Розкладка") }
                    Rectangle {
                        id: pick
                        width: Math.max(210, pickRow.implicitWidth + 18)
                        height: 36
                        radius: 2
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: "#ffffff" }
                            GradientStop { position: 1; color: "#d9ffffff" }
                        }
                        // клік по полю розкладки лише скасовує очікування клавіші (не призначає ЛКМ)
                        MouseArea { anchors.fill: parent; onPressed: { root.cancelWait(); root.forceActiveFocus(); } }
                        Row {
                            id: pickRow
                            x: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0
                            Image {
                                width: 22; height: 22
                                anchors.verticalCenter: parent.verticalCenter
                                source: root.layouts[root.layoutIndex()] ? root.layouts[root.layoutIndex()].logo : ""
                                fillMode: Image.PreserveAspectCrop
                                smooth: true; mipmap: true
                            }
                            Item { width: 8; height: 1 }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.layouts[root.layoutIndex()] ? root.layouts[root.layoutIndex()].name : ""
                                color: ap.dark
                                font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 14
                            }
                        }
                        Row {
                            anchors.right: parent.right; anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                rightPadding: 4
                                text: (root.layoutIndex() + 1) + " / " + root.layouts.length
                                color: "#6a6278"
                                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 11
                            }
                            Repeater {
                                model: [[-1, "‹", qsTr("Попередня розкладка")], [1, "›", qsTr("Наступна розкладка")]]
                                Rectangle {
                                    required property var modelData
                                    width: arrow.implicitWidth + 12; height: arrow.implicitHeight + 4
                                    radius: 4
                                    color: arrowArea.containsMouse ? "#221a0b2e" : "transparent"
                                    Text {
                                        id: arrow
                                        anchors.centerIn: parent
                                        text: modelData[1]
                                        color: ap.dark
                                        font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 15
                                    }
                                    MouseArea {
                                        id: arrowArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        Accessible.name: modelData[2]
                                        onClicked: {
                                            const n = root.layouts.length, i = (root.layoutIndex() + modelData[0] + n) % n;
                                            root.setLayout(root.layouts[i].id);
                                            root.forceActiveFocus();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Column {
                    id: modesBlock
                    objectName: "apModes"
                    x: side.modesInline ? pickBlock.width + side.gapX : 0
                    y: side.modesInline ? 0 : pickBlock.height + 12
                    width: Math.min(side.width, Math.max(modesRow.implicitWidth, root.tight ? side.width - pickBlock.width - side.gapX : 560))
                    spacing: 5
                    Cap { text: qsTr("Режим") }
                    Row {
                        id: modesRow
                        spacing: 2
                        Repeater {
                            model: root.view.modes
                            Item {
                                required property var modelData
                                readonly property bool cur: modelData.id === root.mode
                                width: tabRow.implicitWidth + 28
                                height: 33
                                opacity: cur || tabArea.containsMouse ? 1 : 0.7
                                Row {
                                    id: tabRow
                                    anchors.centerIn: parent
                                    anchors.verticalCenterOffset: -1
                                    spacing: 15
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.name
                                        color: ap.ink
                                        font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 14
                                    }
                                    Rectangle {
                                        visible: modelData.key !== ""
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: mk.implicitWidth + 8; height: mk.implicitHeight + 1
                                        radius: 3; color: "transparent"; border.width: 1; border.color: "#40ffffff"
                                        Text {
                                            id: mk
                                            anchors.centerIn: parent
                                            text: root.kname(modelData.key)
                                            color: "#a6ffffff"
                                            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 10
                                        }
                                    }
                                }
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: cur ? "#ffffff" : "#26ffffff" }
                                MouseArea {
                                    id: tabArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.setMode(modelData.id); root.forceActiveFocus(); }
                                }
                            }
                        }
                    }
                    Text {
                        width: Math.min(root.tight ? 900 : 560, modesBlock.width)
                        topPadding: 1
                        text: root.tighter ? (root.view.hintShort || "") : root.view.hint
                        visible: text !== ""
                        height: visible ? implicitHeight : 0
                        textFormat: Text.StyledText
                        wrapMode: Text.WordWrap
                        color: "#a6ffffff"
                        font.family: ap.body; font.pixelSize: 12
                    }
                }

                Grid {
                    id: actsBlock
                    x: side.width - width
                    y: side.actsInline ? 22 : modesBlock.y + modesBlock.height + (root.tighter ? 6 : 12)
                    columns: root.tighter ? 2 : 1          // у дуже низькому вікні кнопки й чутливість в один рядок
                    layoutDirection: root.tighter ? Qt.RightToLeft : Qt.LeftToRight
                    rowSpacing: 7
                    columnSpacing: 22
                    horizontalItemAlignment: Grid.AlignRight
                    verticalItemAlignment: Grid.AlignVCenter
                    Row {
                        spacing: 6
                        LinkButton { text: qsTr("Скинути до стандартної"); onClicked: root.resetKeys() }
                        LinkButton { text: qsTr("Показати вибір перед грою"); onClicked: root.askBeforeGame() }
                    }
                    // нове: чутливість миші для камери та інверсія вертикалі (діють одразу, і в грі теж)
                    Row {
                        spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.vehicleSens ? qsTr("Миша в транспорті") : qsTr("Миша пішки")
                            color: "#d9ffffff"
                            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 12
                        }
                        Slider {
                            id: sens
                            anchors.verticalCenter: parent.verticalCenter
                            width: 100; height: 20
                            padding: 0
                            from: 0.3; to: 3.0; stepSize: 0.1
                            focusPolicy: Qt.NoFocus
                            value: root.sensNow
                            onMoved: root.setSens(Math.round(value * 10) / 10)
                            onPressedChanged: if (!pressed) root.forceActiveFocus()
                            Accessible.name: qsTr("Чутливість миші")
                            background: Item {
                                x: sens.leftPadding + 6; y: sens.topPadding + sens.availableHeight / 2 - 1
                                width: sens.availableWidth - 12; height: 2
                                Rectangle { anchors.fill: parent; radius: 1; color: "#33ffffff" }
                                Rectangle { width: sens.visualPosition * parent.width; height: 2; radius: 1; color: "#ffffff" }
                            }
                            handle: Rectangle {
                                x: sens.leftPadding + sens.visualPosition * (sens.availableWidth - width)
                                y: sens.topPadding + sens.availableHeight / 2 - height / 2
                                width: 12; height: 12; radius: 6
                                color: sens.pressed ? ap.cyan : "#ffffff"
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 22
                            text: Number(root.sensNow).toFixed(1).replace(".", ",")
                            color: ap.ink
                            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 12
                        }
                        Item {
                            anchors.verticalCenter: parent.verticalCenter
                            width: invRow.implicitWidth + 6; height: 20
                            Row {
                                id: invRow
                                x: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 7
                                Rectangle {
                                    width: 14; height: 14; radius: 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: Chiaki.settings.anyplayInvertY ? "#ffffff" : "transparent"
                                    border.width: 1; border.color: invArea.containsMouse || Chiaki.settings.anyplayInvertY ? "#ffffff" : "#80ffffff"
                                    Text { anchors.centerIn: parent; visible: Chiaki.settings.anyplayInvertY; text: "✓"; color: ap.dark; font.family: ap.body; font.pixelSize: 11; font.weight: Font.DemiBold }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.tighter ? qsTr("Інверсія") : qsTr("Інвертувати вертикаль")
                                    color: "#d9ffffff"
                                    font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 12
                                }
                            }
                            MouseArea {
                                id: invArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                Accessible.name: qsTr("Інвертувати вертикаль")
                                onClicked: { root.cancelWait(); Chiaki.settings.anyplayInvertY = !Chiaki.settings.anyplayInvertY; root.forceActiveFocus(); }
                            }
                        }
                    }
                }
            }

            Gap { height: root.tighter ? 4 : 14 }
            // ── назва режиму над геймпадом ──
            Column {
                objectName: "apTitle"
                visible: !root.tight
                height: visible ? implicitHeight : 0
                width: page.cw
                spacing: 4
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.view.title
                    color: ap.ink
                    font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 20; font.letterSpacing: 2
                    font.capitalization: Font.AllUppercase
                }
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 1; height: 16; color: "#66ffffff" }
            }

            Gap { height: root.tight ? 0 : 8 }
            // ── геймпад з підписами ──
            Item {
                id: rig
                objectName: "apRig"
                width: page.cw
                readonly property real gap: Math.max(24, Math.min(110, page.cw * 0.07))
                readonly property real leftMC: colL.maxRow
                readonly property real rightMC: colR.maxRow
                readonly property real gpW: page.narrow ? Math.min(440, root.gpCap, page.cw)
                                                        : Math.max(200, Math.min(540, root.gpCap, page.cw - leftMC - rightMC - 2 * gap))
                readonly property real rest: page.cw - 2 * gap - gpW
                readonly property real leftW: page.narrow ? 0 : (leftMC > rest / 2 ? leftMC : rightMC > rest / 2 ? Math.max(leftMC, rest - rightMC) : rest / 2)
                readonly property real rightW: page.narrow ? 0 : Math.max(rightMC, rest - leftW)
                readonly property int narrowCols: page.cw >= 560 ? 2 : 1
                readonly property real narrowColW: narrowCols === 2 ? (page.cw - 28) / 2 : page.cw
                height: page.narrow ? gp.height + 8 + (narrowCols === 2 ? Math.max(colL.height, colR.height) : colL.height + colR.height)
                                    : Math.max(gp.height, colL.height, colR.height) + 12

                Column {
                    id: colL
                    property real maxRow: 0
                    x: page.narrow ? 0 : rig.leftW - width
                    y: page.narrow ? gp.height + 8 : (rig.height - height) / 2
                    width: page.narrow ? rig.narrowColW : rig.leftW
                    spacing: 1
                    z: 2
                    Repeater {
                        id: rowsL
                        model: root.view.left
                        onItemAdded: Qt.callLater(colL.measure)
                        PadRow { required property var modelData; row: modelData; leftSide: true; colWidth: colL.width; onImplicitWidthChanged: colL.measure() }
                    }
                    function measure() { let m = 0; for (let i = 0; i < rowsL.count; i++) if (rowsL.itemAt(i)) m = Math.max(m, rowsL.itemAt(i).naturalWidth); maxRow = m; wires.schedule(); }
                }
                Column {
                    id: colR
                    property real maxRow: 0
                    x: page.narrow ? (rig.narrowCols === 2 ? rig.narrowColW + 28 : 0) : rig.leftW + rig.gap + rig.gpW + rig.gap
                    y: page.narrow ? (rig.narrowCols === 2 ? gp.height + 8 : gp.height + 8 + colL.height) : (rig.height - height) / 2
                    width: page.narrow ? rig.narrowColW : rig.rightW
                    spacing: 1
                    z: 2
                    Repeater {
                        id: rowsR
                        model: root.view.right
                        onItemAdded: Qt.callLater(colR.measure)
                        PadRow { required property var modelData; row: modelData; leftSide: false; colWidth: colR.width; onImplicitWidthChanged: colR.measure() }
                    }
                    function measure() { let m = 0; for (let i = 0; i < rowsR.count; i++) if (rowsR.itemAt(i)) m = Math.max(m, rowsR.itemAt(i).naturalWidth); maxRow = m; wires.schedule(); }
                }

                // фото геймпада: незмінне в спокої; натиснута кнопка — готовий «натиснутий» знімок і блакитний контур
                Item {
                    id: gp
                    objectName: "anyplayPad"
                    x: page.narrow ? (page.cw - width) / 2 : rig.leftW + rig.gap
                    y: page.narrow ? 0 : (rig.height - height) / 2
                    width: rig.gpW
                    height: width * root.padH / root.padW
                    z: 1
                    readonly property real s: width / root.padW
                    onXChanged: wires.schedule()
                    onYChanged: wires.schedule()
                    onWidthChanged: wires.schedule()

                    Item {
                        id: art
                        width: root.padW; height: root.padH
                        transform: Scale { xScale: gp.s; yScale: gp.s }
                        Item {
                            // початок координат малюнка (у прототипі viewBox починався з y = -16)
                            y: root.padTop
                            PadImage { g: root.gpd.floor }
                            // курки позаду корпусу: L2/R2 визирають над L1/R1 і з'їжджають униз
                            Repeater {
                                model: [["L1", "L2"], ["R1", "R2"]]
                                Item {
                                    required property var modelData
                                    Item {
                                        y: root.onMap[modelData[1]] ? 6 : 0
                                        Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                                        PadImage { g: root.gpd.l2[modelData[1]]; opacity: root.onMap[modelData[1]] ? 0 : 1 }
                                        PadImage { g: root.gpd.l2[modelData[1]]; dark: true; opacity: root.onMap[modelData[1]] ? 1 : 0 }
                                    }
                                    Item {
                                        y: root.onMap[modelData[0]] ? 4 : 0
                                        Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                                        PadImage { g: root.gpd.sh[modelData[0]]; opacity: root.onMap[modelData[0]] ? 0 : 1 }
                                        PadImage { g: root.gpd.sh[modelData[0]]; dark: true; opacity: root.onMap[modelData[0]] ? 1 : 0 }
                                    }
                                }
                            }
                            PadImage { g: root.gpd.base }
                            Repeater {
                                model: Object.keys(root.gpd.pressed)
                                PadImage {
                                    required property var modelData
                                    g: root.gpd.pressed[modelData]
                                    opacity: root.onMap[modelData] ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 60 } }
                                }
                            }
                            // стіки: рухаються від WASD і миші, ковпачок L3/R3 тисне всередину
                            Repeater {
                                model: [["L3", "LS"], ["R3", "RS"]]
                                Item {
                                    id: stick
                                    required property var modelData
                                    readonly property var cap: root.gpd.caps[modelData[0]]
                                    readonly property var vec: modelData[1] === "LS" ? root.lsVec : root.rsVec
                                    x: vec[0] * 17
                                    y: vec[1] * 17
                                    Behavior on x { NumberAnimation { duration: 60 } }
                                    Behavior on y { NumberAnimation { duration: 60 } }
                                    Item {
                                        id: capItem
                                        readonly property bool pressedIn: !!root.onMap[stick.modelData[0]]
                                        property real press: pressedIn ? 0.955 : 1
                                        Behavior on press { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
                                        transform: Scale {
                                            origin.x: stick.cap.cx; origin.y: stick.cap.cy
                                            xScale: capItem.press; yScale: capItem.press
                                        }
                                        PadImage { g: stick.cap; opacity: capItem.pressedIn ? 0 : 1 }
                                        PadImage { g: stick.cap; dark: true; opacity: capItem.pressedIn ? 1 : 0 }
                                    }
                                    Glow { g: root.gpd.glow[stick.modelData[0]]; on: !!root.onMap[stick.modelData[0]] }
                                    Glow { g: root.gpd.glow[stick.modelData[0]]; on: !!root.onMap[stick.modelData[1]] }
                                }
                            }
                            Repeater {
                                model: Object.keys(root.gpd.glow).filter((n) => ["L1", "L2", "R1", "R2", "L3", "R3"].indexOf(n) < 0)
                                Glow { required property var modelData; g: root.gpd.glow[modelData]; on: !!root.onMap[modelData] }
                            }
                            Repeater {
                                model: [["L1", "L2"], ["R1", "R2"]]
                                Item {
                                    required property var modelData
                                    Item {
                                        y: root.onMap[modelData[1]] ? 6 : 0
                                        Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                                        Glow { g: root.gpd.glow[modelData[1]]; on: !!root.onMap[modelData[1]] }
                                    }
                                    Item {
                                        y: root.onMap[modelData[0]] ? 4 : 0
                                        Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
                                        Glow { g: root.gpd.glow[modelData[0]]; on: !!root.onMap[modelData[0]] }
                                    }
                                }
                            }
                        }
                    }

                    // наведи: що робить кнопка в грі і яка клавіша; клацни: кнопка натиснеться
                    MouseArea {
                        id: gpArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        cursorShape: tipBtn ? Qt.PointingHandCursor : Qt.ArrowCursor
                        property string tipBtn: ""
                        property point at
                        function hit(mx, my) { return root.padAt(mx / gp.s, my / gp.s - root.padTop); }
                        onPositionChanged: (m) => { tipBtn = hit(m.x, m.y); at = Qt.point(m.x, m.y) }
                        onExited: tipBtn = ""
                        onPressed: (m) => {
                            root.forceActiveFocus();
                            if (root.waiting) { const n = root.mouseName(m.button); if (n) root.assign(n); return; }
                            const n = hit(m.x, m.y);
                            if (!n) return;
                            root.clickBtn = n;
                            const b = root.mainOf(root.cfg, root.mode, n);
                            root.log(root.padLong[n] + (b ? " → " + root.clean(b.name) + (b.key ? qsTr(", клавіша %1").arg(root.kname(b.key)) : "") : qsTr(": у цьому режимі нічого")));
                        }
                        onReleased: root.clickBtn = ""
                        onCanceled: root.clickBtn = ""
                        onWheel: (w) => {
                            const k = root.wheelKey(w);
                            if (root.waiting) { if (k) root.assign(k); return; }
                            // колесо крутить зброю лише над малюнком геймпада і лише якщо воно тут призначене; інакше сторінка гортається
                            if (!k || !root.live || !root.findActive(k)) { w.accepted = false; return; }
                            const now = Date.now();
                            if (now - root.wheelAt < 180) return;
                            root.wheelAt = now;
                            root.previewTap(k);
                        }
                    }
                }

                // лінії від підписів до країв кнопок
                Canvas {
                    id: wires
                    anchors.fill: parent
                    visible: !page.narrow
                    z: 3
                    property var wd: []
                    function schedule() { wireTimer.restart(); }
                    Timer { id: wireTimer; interval: 15; onTriggered: root.computeWires() }
                    onWidthChanged: schedule()
                    onHeightChanged: schedule()
                    onPaint: {
                        const c = getContext("2d");
                        c.reset();
                        c.lineCap = "round";
                        const path = (w) => { c.beginPath(); c.moveTo(w.x0, w.y0); c.lineTo(w.xb, w.y0); c.bezierCurveTo(w.c[0], w.c[1], w.c[2], w.c[3], w.ax, w.ay); };
                        // м'яка темна підкладка під усіма лініями
                        c.strokeStyle = "rgba(26,18,48,0.18)"; c.lineWidth = 3;
                        for (const w of wd) { path(w); c.stroke(); }
                        for (const w of wd) {
                            const hot = !!root.onMap[w.btn];
                            path(w);
                            c.strokeStyle = hot ? "#8fe3ff" : "rgba(255,255,255,0.85)"; c.lineWidth = hot ? 1.6 : 1;
                            c.stroke();
                            c.beginPath(); c.arc(w.x0, w.y0, 1.6, 0, 2 * Math.PI);
                            c.fillStyle = hot ? "#8fe3ff" : "rgba(255,255,255,0.85)"; c.fill();
                            c.beginPath(); c.arc(w.ax, w.ay, 3, 0, 2 * Math.PI);
                            c.fillStyle = hot ? "#8fe3ff" : "#ffffff"; c.fill();
                            c.strokeStyle = "rgba(26,18,48,0.35)"; c.lineWidth = 1; c.stroke();
                        }
                    }
                    Connections { target: root; function onOnMapChanged() { wires.requestPaint(); } }
                }

                // підказка над кнопкою геймпада
                Rectangle {
                    id: tip
                    z: 6
                    visible: gpArea.tipBtn !== "" && gpArea.containsMouse
                    readonly property var lines: visible ? root.tipLines(gpArea.tipBtn) : []
                    readonly property real wantX: gp.x + gpArea.at.x - width / 2
                    x: Math.max(-page.x + 6, Math.min(wantX, root.width - page.x - width - 6))
                    y: gp.y + gpArea.at.y - height - 12
                    width: tipCol.implicitWidth + 20
                    height: tipCol.implicitHeight + 12
                    radius: 4
                    color: "#ee16121f"
                    border.width: 1; border.color: "#40ffffff"
                    Column {
                        id: tipCol
                        x: 10; y: 6
                        spacing: 2
                        Text {
                            text: root.padLong[gpArea.tipBtn] || gpArea.tipBtn
                            color: ap.cyan
                            font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 13; font.letterSpacing: 1
                            font.capitalization: Font.AllUppercase
                        }
                        Repeater {
                            model: tip.lines
                            Row {
                                required property var modelData
                                spacing: 4
                                Repeater {
                                    model: modelData
                                    Item {
                                        id: seg
                                        required property var modelData
                                        readonly property bool isChip: modelData.chip !== undefined
                                        width: isChip ? segChip.width : segText.implicitWidth
                                        height: 20
                                        Text {
                                            id: segText
                                            visible: !seg.isChip
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: seg.isChip ? "" : seg.modelData.t
                                            color: "#ffffff"
                                            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
                                        }
                                        Rectangle {
                                            id: segChip
                                            visible: seg.isChip
                                            width: segChipText.implicitWidth + 14; height: 20; radius: 3
                                            color: "#12ffffff"; border.width: 1; border.color: seg.modelData.chip ? "#4dffffff" : "#66ffffff"
                                            Text {
                                                id: segChipText
                                                anchors.centerIn: parent
                                                text: seg.isChip ? (seg.modelData.chip ? root.kname(seg.modelData.chip) : qsTr("немає")) : ""
                                                color: seg.modelData.chip ? "#ffffff" : "#99ffffff"
                                                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 11
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Gap { height: 8; visible: extra.visible }
            // ── інші дії ──
            Item {
                id: extra
                visible: root.view.extra.length > 0
                width: page.cw
                height: visible ? extraGrid.y + extraGrid.height : 0
                readonly property int cols: Math.max(1, Math.floor((width + 24) / ((root.tighter ? 168 : 230) + 24)))
                readonly property real colW: (width - (cols - 1) * 24) / cols
                Rectangle { width: parent.width; height: 1; color: "#2bffffff" }
                Cap { id: extraCap; y: 11; text: qsTr("Інші дії") }
                Grid {
                    id: extraGrid
                    y: extraCap.y + extraCap.height + 4
                    columns: extra.cols
                    columnSpacing: 24
                    Repeater {
                        id: extraRep
                        model: root.view.extra
                        Item {
                            id: li
                            required property var modelData
                            required property int index
                            width: extra.colW
                            // рядки однакової висоти в межах ряду сітки, як у прототипі
                            readonly property int rowIdx: Math.floor(index / extra.cols)
                            readonly property real natural: Math.max(root.rowH, Math.max(liText.implicitHeight, liKeys.implicitHeight) + (root.rowH < 26 ? 2 : 8))
                            height: extra.rowHeight(rowIdx)
                            Column {
                                id: liText
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - liKeys.width - 12
                                spacing: 1
                                Text {
                                    width: parent.width
                                    // назва і сіра примітка («на джойстику: L1») в одному рядку: так усі дії вміщуються без прокрутки
                                    text: li.modelData.name + (li.modelData.how ? '  <font color="#80ffffff">' + li.modelData.how + '</font>' : "")
                                    textFormat: Text.StyledText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    color: ap.ink
                                    font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
                                }
                            }
                            Flow {
                                id: liKeys
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitW, parent.width * 0.75)   // дві клавіші (Колесо↑ Колесо↓) в один рядок
                                readonly property real implicitW: { let w = 0; for (let i = 0; i < chipsRep.count; i++) if (chipsRep.itemAt(i)) w += chipsRep.itemAt(i).implicitWidth + (i ? 3 : 0); return w; }
                                layoutDirection: Qt.RightToLeft
                                spacing: 3
                                Repeater { id: chipsRep; model: li.modelData.chips.slice().reverse(); KeyChip { required property var modelData; chip: modelData } }
                            }
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#14ffffff" }
                        }
                    }
                }
                function rowHeight(r) {
                    let h = root.rowH;
                    for (let i = r * cols; i < Math.min(extraRep.count, (r + 1) * cols); i++)
                        if (extraRep.itemAt(i)) h = Math.max(h, extraRep.itemAt(i).natural);
                    return h;
                }
            }

            Gap { height: root.inGame ? 0 : 12 }
            // ── підказки внизу ──
            Flow {
                visible: !root.inGame
                height: visible ? implicitHeight : 0
                width: page.cw
                layoutDirection: Qt.RightToLeft
                spacing: 16
                Repeater {
                    model: (root.live ? [[root.padStatus, ""]] : [])
                        .concat([[qsTr("Меню AnyPlay:"), qsTr("клавіша ` (під Esc)")], [qsTr("Прибрати клавішу:"), "Backspace"], [qsTr("Скасувати:"), "Esc"], [qsTr("Змінити клавішу:"), qsTr("клацни на неї")]])
                    Text {
                        required property var modelData
                        text: modelData[1] ? modelData[0] + " " + root.bold(modelData[1]) : modelData[0]
                        textFormat: Text.StyledText
                        color: "#b3ffffff"
                        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 13; font.letterSpacing: 1
                        font.capitalization: Font.AllUppercase
                    }
                }
            }

            Gap { height: 22; visible: logBox.visible }
            // ── перевірка: що щойно отримала б приставка ──
            Rectangle {
                id: logBox
                visible: (root.live || (!root.inGame && !Chiaki.session)) && !root.tight
                width: page.cw
                height: Math.max(44, logRow.implicitHeight + 16)
                radius: 4
                color: "#0affffff"
                border.width: 1; border.color: "#38ffffff"
                Row {
                    id: logRow
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Cap { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Перевірка") }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: page.cw - 140
                        spacing: 1
                        Repeater {
                            model: root.logLines
                            Text {
                                required property var modelData
                                required property int index
                                width: parent.width
                                text: modelData
                                elide: Text.ElideRight
                                color: index === 0 ? ap.cyan : "#99ffffff"
                                font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }
    }

    // спливне повідомлення внизу
    Rectangle {
        visible: root.toastText !== ""
        z: 20
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        width: Math.min(520, toastLabel.implicitWidth + 28, root.width - 32)
        height: toastLabel.implicitHeight + 16
        radius: 4
        color: "#f2221d2e"
        border.width: 1; border.color: "#66ffffff"
        Text {
            id: toastLabel
            x: 14; y: 8
            width: parent.width - 28
            text: root.toastText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            color: ap.ink
            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
        }
    }

    // ── лінії: точка на краю кнопки, яку лінія досягає, не перетинаючи інших кнопок (як wires() у прототипі) ──
    function computeWires() {
        if (page.narrow || !occ) { wires.wd = []; wires.requestPaint(); return; }
        const s = gp.s, px = gp.x, py = gp.y;
        const toScr = (ux, uy) => [px + ux * s, py + (uy + padTop) * s];
        const toUsr = (x, y) => [(x - px) / s, (y - py) / s - padTop];
        const occAt = (x, y) => { const gx = Math.floor(x / occ.g), gy = Math.floor(y / occ.g); return gx < 0 || gy < 0 || gx >= occ.w || gy >= occ.h ? 0 : occ.a[gy * occ.w + gx]; };
        const curve = (x0, y0, xb, ax, ay) => { const k = ax - xb; return [xb + k * 0.5, y0, ax - k * 0.18, ay - (ay - y0) * 0.12]; };
        const bez = (p0, p1, p2, p3, t) => { const u = 1 - t; return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3; };
        const out = [];
        for (const [rep, left] of [[rowsL, true], [rowsR, false]]) {
            for (let i = 0; i < rep.count; i++) {
                const row = rep.itemAt(i);
                if (!row) continue;
                const btn = row.row.btn, cs = gpd.cand[btn];
                if (!cs) continue;
                const pr = row.pill.mapToItem(rig, 0, 0);
                const x0 = left ? pr.x + row.pill.width + 6 : pr.x - 6, y0 = pr.y + row.pill.height / 2, xb = left ? x0 + 16 : x0 - 16;
                const own = occ.names.indexOf(ownOf[btn] || btn) + 1;
                let best = null;
                for (const [ux, uy] of cs) {
                    const [ax, ay] = toScr(ux, uy), c = curve(x0, y0, xb, ax, ay);
                    let hit = 0;
                    for (let j = 2; j < 40; j++) {
                        const t = j / 40, [x, y] = toUsr(bez(xb, c[0], c[2], ax, t), bez(y0, c[1], c[3], ay, t)), o = occAt(x, y);
                        if (o && (o !== own || Math.hypot(ux - x, uy - y) > 14)) hit++;
                    }
                    const sc = Math.hypot(ax - xb, ay - y0) + Math.abs(ay - y0) * 0.35 + hit * 30;
                    if (!best || sc < best.sc) best = { sc: sc, ax: ax, ay: ay, c: c };
                }
                out.push({ btn: btn, x0: x0, y0: y0, xb: xb, c: best.c, ax: best.ax, ay: best.ay });
            }
        }
        wires.wd = out;
        wires.requestPaint();
    }

    // яка кнопка під курсором (у координатах малюнка геймпада)
    function padAt(ux, uy) {
        for (const [n, r] of [["L3", "LS"], ["R3", "RS"]]) {
            const c = gpd.caps[n];
            if (Math.hypot(ux - c.cx, uy - c.cy) < c.r + 4) return n;
        }
        if (uy < 60 && (ux < 300 || ux > 790)) {
            const l = ux < 542;
            return uy < 22 ? (l ? "L2" : "R2") : (l ? "L1" : "R1");
        }
        if (!occ) return "";
        const gx = Math.floor(ux / occ.g), gy = Math.floor(uy / occ.g);
        if (gx < 0 || gy < 0 || gx >= occ.w || gy >= occ.h) return "";
        const o = occ.a[gy * occ.w + gx];
        return o ? occ.names[o - 1] : "";
    }
    // текст підказки: рядки з шматків {t} і фішок {chip}
    function tipLines(n) {
        const b = mainOf(cfg, mode, n);
        const keyChip = (x) => ({ chip: x && x.key ? x.key : "" });
        if (n === "L3" || n === "R3") {
            const lb = (mode !== "global" && prof(mode) && prof(mode).labels) || {};
            const mv = ownList(cfg, mode).concat(globalList(cfg)).filter((x) => x.l && x.l.length === 2);
            const first = n === "L3" ? (mv.length ? [{ t: lb.LS || qsTr("Рух") }].concat(mv.map(keyChip)) : []) : [{ t: (lb.RS || qsTr("Камера")) + qsTr(": рух миші") }];
            const second = [{ t: qsTr("Натиснути: ") + (b ? rowName(cfg, mode, n, b) : qsTr("нічого")) }].concat(b ? [keyChip(b)] : []);
            return first.length ? [first, second] : [second];
        }
        return b ? [[{ t: rowName(cfg, mode, n, b) }, keyChip(b)]] : [[{ t: qsTr("У цьому режимі нічого") }]];
    }

    // ── складові ──
    component Gap: Item { width: 1 }

    component Cap: Text {
        color: ap.ink
        opacity: 0.85
        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 14; font.letterSpacing: 1.5
        font.capitalization: Font.AllUppercase
    }

    component LinkButton: Rectangle {
        id: lb
        property alias text: lbText.text
        signal clicked()
        width: lbText.implicitWidth + 18
        height: lbText.implicitHeight + 10
        radius: 2
        color: "#0affffff"
        border.width: 1
        border.color: lbArea.containsMouse ? "#ffffff" : "#38ffffff"
        Text { id: lbText; anchors.centerIn: parent; color: ap.ink; font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13 }
        MouseArea { id: lbArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.forceActiveFocus(); lb.clicked(); } }   // фокус спершу: кнопка може відкрити вікно, яке забере його собі
    }

    // фішка клавіші: клацни, щоб призначити іншу
    component KeyChip: Rectangle {
        id: kc
        property var chip: null
        property string fixedText: ""
        readonly property bool fixed: fixedText !== ""
        readonly property bool isWait: !fixed && !!root.waiting && !!chip && root.waiting.p === chip.p && root.waiting.id === chip.id
        readonly property bool isEmpty: !fixed && !!chip && !chip.key && !isWait
        readonly property bool hov: !fixed && kcArea.containsMouse
        implicitWidth: kcText.implicitWidth + 16
        implicitHeight: 20
        width: implicitWidth; height: implicitHeight
        radius: 3
        color: isWait ? "#ffffff" : hov ? "#24ffffff" : "#12ffffff"
        border.width: isEmpty ? 0 : 1
        border.color: isWait || hov ? "#ffffff" : "#4dffffff"
        Text {
            id: kcText
            anchors.centerIn: parent
            text: kc.isWait ? qsTr("тисни…") : kc.fixed ? kc.fixedText : (kc.chip && kc.chip.key ? kc.chip.keyName : qsTr("немає"))
            color: kc.isWait ? ap.dark : kc.isEmpty ? "#99ffffff" : "#ffffff"
            font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 11
        }
        Canvas {
            // пунктирна рамка порожньої клавіші
            anchors.fill: parent
            visible: kc.isEmpty
            onVisibleChanged: requestPaint()
            onPaint: {
                const c = getContext("2d");
                c.reset();
                c.strokeStyle = kc.hov ? "#ffffff" : "rgba(255,255,255,0.3)";
                c.lineWidth = 1;
                c.setLineDash([3, 2]);
                c.beginPath();
                c.roundedRect(0.5, 0.5, width - 1, height - 1, 3, 3);
                c.stroke();
            }
        }
        MouseArea {
            id: kcArea
            anchors.fill: parent
            enabled: !kc.fixed
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            // інші кнопки миші по фішці нічого не призначають (як у прототипі)
            onClicked: (m) => { if (m.button === Qt.LeftButton) root.startWait(kc.chip); }
        }
    }

    // рядок підпису: кнопка геймпада, клавіші, що робить
    component PadRow: Item {
        id: pr
        property var row: ({})
        property bool leftSide: true
        property real colWidth: 0
        readonly property bool hot: !!root.onMap[row.btn]
        readonly property bool none: row.name === ""
        readonly property bool mirrored: leftSide && !page.narrow   // ліворуч від геймпада: назва, клавіші, кнопка
        property alias pill: pillRect
        readonly property real naturalWidth: pillRect.width + 8 + content.width
        implicitWidth: naturalWidth
        width: colWidth
        height: page.narrow ? 28 : root.rowH
        Rectangle {
            visible: page.narrow
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: "#12ffffff"
        }
        // кнопка геймпада стоїть точно посередині рядка (від неї йде лінія), без округлення до пікселя
        Rectangle {
            visible: pr.hot
            x: pillRect.x - 3; y: pillRect.y - 3
            width: pillRect.width + 6; height: pillRect.height + 6; radius: height / 2
            color: "#408fe3ff"
        }
        Rectangle {
            id: pillRect
            x: pr.mirrored ? pr.width - width : 0
            y: (pr.height - height) / 2
            width: Math.max(20, pillText.implicitWidth + 10); height: 18; radius: 9
            color: pr.hot ? ap.cyan : "#ffffff"
            Text {
                id: pillText
                anchors.centerIn: parent
                text: pr.row.pad || ""
                color: pr.hot ? "#10212b" : ap.dark
                font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 10
            }
        }
        Row {
            id: content
            anchors.verticalCenter: parent.verticalCenter
            x: pr.mirrored ? pillRect.x - 8 - width : pillRect.width + 8
            layoutDirection: pr.mirrored ? Qt.RightToLeft : Qt.LeftToRight
            spacing: 8
            Row {
                id: keysRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                layoutDirection: Qt.LeftToRight
                Repeater { model: pr.row.chips || []; KeyChip { required property var modelData; chip: modelData } }
                KeyChip { visible: !!pr.row.fixed; fixedText: pr.row.fixed || "" }
            }
            Text {
                id: nameText
                anchors.verticalCenter: parent.verticalCenter
                // порожній ряд клавіш займає місце, як у прототипі (інакше назва прилипає до кнопки)
                readonly property real gapFix: keysRow.width > 0 ? 0 : 8
                rightPadding: pr.mirrored ? gapFix : 0
                leftPadding: pr.mirrored ? 0 : gapFix
                text: pr.none ? qsTr("вільна") : pr.row.name
                color: pr.hot ? ap.cyan : pr.none ? "#66ffffff" : ap.ink
                font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 14; font.letterSpacing: 0.8
                font.capitalization: Font.AllUppercase
            }
        }
        Component.onCompleted: wires.schedule()
    }

    component PadImage: Image {
        property var g: null
        property bool dark: false
        x: g ? g.x : 0
        y: g ? g.y : 0
        width: g ? g.w : 0
        height: g ? g.h : 0
        source: g ? "qrc:/anyplay-pad/" + (dark ? g.dark : g.src) : ""
        smooth: true
        mipmap: true
        asynchronous: false
    }

    component Glow: PadImage {
        property bool on: false
        opacity: on ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 80 } }
    }
}
