// AnyPlay 116–118: одне місце, де QML бере трансляцію для друзів, голос, допомогу друга, друзів і подарунки з C++.
// Усі екрани (меню гри «Друзі й трансляція», підказки в грі, вкладка «Друзі») читають лише цей об'єкт: якщо в C++
// назви інші — міняємо тут, а не в екранах. Немає модуля трансляції (стара збірка, Android, C++ ще не готовий) —
// available: false, і екрани просто не показують трансляцію.
//
// Джерело: Chiaki.live (AnyPlayLive, модуль «Трансляції»). Друзі — з Chiaki.live або Chiaki.cloud (де будуть).
// Кожен метод викликаємо, лише якщо він справді є (typeof === "function"); кожне поле має розумне типове значення.
// demo: true — перегляд без гри (панель адміна «Меню гри: перегляд», офскрін-знімки): правдоподібні заглушки,
// нічого не надсилає й не зберігає; demoState обирає, що показати.
import QtQuick

import org.streetpea.chiaking

QtObject {
    id: api
    property bool demo: false
    // off | on | h265 | pending | reconnecting | lag | checking | weak | nolive | friend | preparing | away | incoming
    property string demoState: "on"
    readonly property var cloud: Chiaki.cloud
    readonly property var src: demo ? demoLive : (Chiaki.live ? Chiaki.live : null)
    // друзі: де їх віддасть C++ (у модулі трансляції чи в AnyPlayCloud)
    readonly property var fsrc: demo ? demoLive : (src && src.friends !== undefined ? src : (cloud && cloud.friends !== undefined ? cloud : null))

    readonly property bool available: !!src && src.allowed !== false
    // що власник увімкнув у CRM (/api/live/config): live helper handoff friends gifts; немає даних — усе можна
    readonly property var features: src && src.features ? src.features : ({})
    readonly property bool featLive: features.live !== false
    readonly property bool featHelper: features.helper !== false
    readonly property bool featHandoff: features.handoff !== false
    readonly property bool featFriends: features.friends !== false
    readonly property bool featGifts: features.gifts !== false
    function loadConfig() { if (has("loadConfig")) src.loadConfig(); }
    readonly property bool friendsAvailable: !!fsrc
    function has(name) { return !!src && typeof src[name] === "function"; }
    function call(name, a, b) {
        if (!has(name)) { console.warn("[anyplay-live] QML: немає методу " + name); return false; }
        src[name](a, b);
        return true;
    }
    function fcall(name, a, b) {
        if (!fsrc || typeof fsrc[name] !== "function") { console.warn("[anyplay-live] QML: немає методу " + name); return false; }
        fsrc[name](a, b);
        return true;
    }

    // Назви — з контракту «Трансляції» (scratchpad/team7/контракт-трансляція.md, розділ 2, клас AnyPlayLive) і «Сервера»
    // (team7/контракт.md: адреси watch.html?r=<код кімнати>, book.html#friends, #gift=<id>); у дужках поруч —
    // запасні назви з чернетки «Програми» (team7/програма.md), щоб будь-яка з двох версій C++ працювала.
    function f(a, b) { if (!src) return undefined; const x = src[a]; return x !== undefined ? x : (b ? src[b] : undefined); }
    // перший з методів, що справді є: call2("grantControl", "giveControl", id)
    function call2(a, b, x, y) {
        if (has(a)) { src[a](x, y); return true; }
        if (b && has(b)) { src[b](x, y); return true; }
        console.warn("[anyplay-live] QML: немає методу " + a);
        return false;
    }

    // ── трансляція ──
    // 118: глядачі отримують гру як є (ті самі кадри й звук, що прийшли з PS5), нічого не кодуємо. Ефір сам не стає
    // на паузу й не знижує якість. state (для екранів): off — вимкнено; checking — перевіряємо вихідний інтернет;
    // starting — підключаємось; on — іде; reconnecting — зник інтернет чи гра перепідключається, ефір повернеться
    // сам; error — не вдалося (reason пояснює). C++: off | checking | starting | live | reconnecting | error
    readonly property string rawState: src && src.state ? String(src.state) : "off"
    readonly property string state: rawState === "live" ? "on" : rawState === "stopping" ? "off" : rawState
    readonly property bool on: state === "on" || state === "reconnecting" || state === "starting" || state === "checking"
    readonly property bool supported: !!src && src.supported !== false           // модуль трансляції є в цій збірці
    readonly property string unsupportedText: src && src.unsupportedText ? src.unsupportedText
        : qsTr("Трансляція не ввійшла в цю збірку програми. Онови програму.")
    // чому чекаємо чи помилка (statusText у звичайному стані — «Трансляція йде», його не показуємо)
    readonly property string reason: (state === "reconnecting" || state === "error" || state === "checking") && f("statusText")
        ? String(f("statusText")) : ""
    readonly property bool gameAudio: f("gameAudio") !== false
    function mbps(kbps) { return (Number(kbps || 0) / 1000).toFixed(1).replace(".", ","); }
    // гра зараз: що саме піде глядачам (кодек, потік) і скільки вихідного інтернету на це треба
    readonly property string gameCodec: String(f("gameCodec") || "")
    readonly property int gameKbps: Number(f("gameKbps") || 0)
    readonly property int gameFps: Number(f("gameFps") || 0)
    readonly property int needKbps: Number(f("needKbps") || 0)
    readonly property int uplinkKbps: f("uplinkKbps") !== undefined ? Number(f("uplinkKbps")) : -1
    readonly property bool viewersLag: f("viewersLag") === true
    readonly property bool compatVideo: f("compatVideo") === true
    readonly property bool compatPending: f("compatPending") === true
    readonly property string browserNote: String(f("browserNote") || "")
    readonly property bool canCompat: has("setCompatVideo")
    // що реально йде глядачам: «60 кадр/с, 14,6 Мбіт/с, H.265»
    readonly property string sendText: {
        const fps = Number(f("liveFps") || 0), kbps = Number(f("liveKbps") || 0);
        if (!(kbps > 0)) return "";
        return qsTr("%1 кадр/с, %2 Мбіт/с").arg(fps).arg(mbps(kbps)) + (gameCodec ? ", " + gameCodec : "");
    }
    // що піде, якщо почати: «Гра зараз: 60 кадр/с, 14,6 Мбіт/с, H.265»
    readonly property string gameText: gameKbps > 0 ? qsTr("%1 кадр/с, %2 Мбіт/с").arg(gameFps).arg(mbps(gameKbps)) + (gameCodec ? ", " + gameCodec : "") : ""
    readonly property int maxViewers: Number(f("viewerLimit", "maxViewers") || 5)
    // [{id, name, role: viewer|helper, speaking, mic, friend, muted}]; C++ дає uid = memberId — тут це id (його й
    // передаємо в kick / muteViewer / grantControl / handoverFull), userId — id людини (для invite)
    readonly property var viewers: (f("viewers") || []).map(v => Object.assign({}, v, { id: v.uid !== undefined ? v.uid : (v.memberId !== undefined ? v.memberId : v.id) }))
    readonly property string tgLink: String(f("link", "watchUrl") || "")          // для Telegram (міні-застосунок)
    readonly property string webLink: String(f("webLink") || "")                  // для браузера: …/app/watch.html?r=КОД
    readonly property string watchUrl: tgLink || webLink                           // що копіюємо й шлемо в Telegram
    readonly property string code: String(f("code") || "")                        // 6 символів («AB3K9M»)
    // QR: сервер картинки не дає — малюємо самі (AnyPlayQr) з посилання для браузера (відкривається і без Telegram)
    readonly property string qr: String(f("qr") || "")
    readonly property string qrText: webLink || (code ? webUrl("watch.html?r=" + code) : tgLink)
    readonly property bool canMute: has("muteViewer")
    readonly property bool canInvite: has("invite")

    // ── голос і чат ──
    readonly property bool mic: f("micOn", "mic") === true
    readonly property bool micReady: f("micReady") !== false               // мікрофон є і дозволений системою
    readonly property bool speaking: f("speaking") === true               // гравець зараз говорить
    readonly property bool hasMicVolume: has("setMicVolume")
    readonly property int micVolume: f("micVolume") !== undefined ? Number(f("micVolume")) : 100
    readonly property bool voices: f("voicesOn", "voices") !== false
    readonly property int voicesVolume: f("voiceVolume", "voicesVolume") !== undefined ? Number(f("voiceVolume", "voicesVolume")) : 80   // 0–100
    // [{id, uid, name, text, ts, mine, system}]; C++ дає ts у мілісекундах — тут секунди (як усюди в програмі)
    readonly property var chat: (f("chat") || []).map(m => m.ts > 100000000000 ? Object.assign({}, m, { ts: Math.floor(m.ts / 1000) }) : m)
    readonly property int unread: Number(f("chatUnread", "unread") || 0)

    // ── допомога друга ──
    // керування дано другові (controlUid ≠ 0); controlActive — від нього справді зараз іде ввід
    readonly property bool friendControls: Number(f("controlUid") || 0) > 0 || f("control") === "friend"
    readonly property bool friendInputNow: f("controlActive") === true
    readonly property string controlBy: String(f("controlName", "controlBy") || "")
    // чим забрати керування просто в грі: C++ ловить PS (кнопку на геймпаді й клавішу PS гравця) навіть тоді, коли решта
    // вводу гравця ігнорується
    // (коротко з налаштувань гравця — «P (або PS на геймпаді)»; інакше рядок з C++)
    readonly property string takeBackKey: src ? psKeyText() : ""
    function psKeyText() {
        try {
            const profiles = Chiaki.settings.anyplayProfiles();
            for (let i = 0; i < profiles.length; i++)
                if (profiles[i].id === "global")
                    for (let j = 0; j < profiles[i].bindings.length; j++)
                        if (profiles[i].bindings[j].id === "ps")
                            return qsTr("%1 (або PS на геймпаді)").arg(profiles[i].bindings[j].keyName);
        } catch (e) {}
        return src && src.takeBackKey ? String(src.takeBackKey) : qsTr("PS на геймпаді");
    }
    // handoff (для екранів): "" — ні; preparing — готуємо «Передати повністю»; away — грає друг зі своєї програми;
    // returning — повертаємо. C++: handoverState "" | offered | ready | active, handedOver
    readonly property string handoff: {
        const hs = String(f("handoverState") || "");
        if (hs === "offered" || hs === "ready") return "preparing";
        if (hs === "active" || f("handedOver") === true) return "away";
        return String(f("handoff") || "");
    }
    readonly property string handoffTo: String(f("handoverName", "handoffTo") || "")
    // друг передає гру мені (у програмі друга): C++ offer {id, from, state: ready|active, until (до коли діє пропозиція),
    // waiting (уже натиснули «Грати», чекаємо старту), roomId} → {id, from, state, waiting, until}
    readonly property var incoming: {
        const o = f("offer");
        if (o && o.from) return { id: o.id !== undefined ? String(o.id) : "", from: o.from, state: o.state || "ready",
                                  waiting: o.waiting === true, until: o.until || 0, roomId: o.roomId || "" };
        return f("incoming") || null;
    }

    // тексти для картки «Тобі передають гру» (вкладки «Гра» і «Друзі»); імена — у називному відмінку
    readonly property string incomingTitle: !incoming ? "" : incoming.state === "active" ? qsTr("Тобі передали гру") : qsTr("Тобі хочуть передати гру")
    readonly property string incomingText: !incoming ? ""
        : incoming.waiting ? qsTr("Чекаємо, поки %1 передасть гру: програма підключиться сама, щойно це станеться.").arg(incoming.from)
        : incoming.state === "active" ? qsTr("Гру тобі передає %1. Граєш зі своєї програми, без затримки; власник броні може будь-коли повернути її собі.").arg(incoming.from)
        : qsTr("%1 хоче передати тобі свою гру. Натисни «Грати»: щойно передачу підтвердять, програма підключиться сама, без затримки.").arg(incoming.from)

    // ── друзі ──
    // [{id, name, username, playing, until, live, roomId, watchUrl, canWatch}], запити: [{id, name, username}]
    readonly property var friends: fsrc && fsrc.friends ? fsrc.friends : []
    readonly property var friendRequests: fsrc && fsrc.friendRequests ? fsrc.friendRequests : []
    readonly property var friendInvite: fsrc && fsrc.friendInvite ? fsrc.friendInvite : null   // {link, code, bot}

    // повідомлення з C++ для людини (тост): message(text)
    signal message(string text)
    property Connections fwd: Connections {
        target: api.src
        ignoreUnknownSignals: true
        function onMessage(text) { api.message(text); }
    }

    // ── дії ──
    function start(audio) { return has("start") ? (src.start("game", audio), true) : call("start"); }
    function stop() { return call("stop"); }
    function setCompatVideo(on) { return call("setCompatVideo", on); }
    // гра зараз перепідключиться за згодою гравця: ефір не вимикати, глядачі чекають
    function holdForReconnect(sec) { if (has("holdForReconnect")) src.holdForReconnect(sec || 120); }
    function setGameAudio(on) { return call("setGameAudio", on); }
    function setMic(on) { return call2("setMicOn", "setMic", on); }
    function setMicVolume(v) { return call("setMicVolume", v); }
    function setVoices(on) { return call2("setVoicesOn", "setVoices", on); }
    function setVoicesVolume(v) { return call2("setVoiceVolume", "setVoicesVolume", v); }
    function sendChat(text) { return call("sendChat", text); }
    function markRead() { if (has("markChatRead")) src.markChatRead(); else if (has("markRead")) src.markRead(); }
    function invite(friendUserId) { return call("invite", friendUserId); }
    function removeViewer(id) { return call2("kick", "removeViewer", id); }
    function muteViewer(id, on) { return call("muteViewer", id, on); }
    function giveControl(id) { return call2("grantControl", "giveControl", id); }
    function takeControl() { return call("takeControl"); }
    function prepareHandoff(id) { if (has("prepareHandover")) src.prepareHandover(id); }   // друг отримає ключі заздалегідь
    function handoffFull(id) { return call2("handoverFull", "handoffFull", id); }
    function cancelHandoff() { return call2("cancelHandover", "cancelHandoff"); }
    function handoffBack() { return call2("returnFull", "handoffBack"); }
    function acceptHandoff() { return call2("acceptHandover", "acceptHandoff", incoming ? incoming.id : ""); }
    // друг відкрив перегляд трансляції в програмі (код кімнати) чи закрив ("")
    function setWatching(code) { if (has("setWatching")) src.setWatching(code || ""); }
    function loadFriends() { if (fsrc && typeof fsrc.loadFriends === "function") fsrc.loadFriends(); }
    function acceptFriend(id) { return fcall("acceptFriend", id); }
    function declineFriend(id) { return fcall("declineFriend", id); }
    function removeFriend(id) { return fcall("removeFriend", id); }
    // «Посилання для всіх»: адреса для браузера (watch.html?r=КОД), а не для Telegram
    function copyWebLink() {
        const u = qrText || watchUrl;
        if (u && cloud && typeof cloud.copyText === "function") cloud.copyText(u);
    }
    function copyLink() {
        if (has("copyLink")) { src.copyLink(); return; }
        if (watchUrl && cloud && typeof cloud.copyText === "function") cloud.copyText(watchUrl);
    }
    // адреса сторінки нашого сервера (watch.html, book.html#friends): з C++, а якщо методу ще немає — поруч з CRM
    function webUrl(page) {
        if (cloud && typeof cloud.webAppUrl === "function") return cloud.webAppUrl(page);
        if (cloud && typeof cloud.crmUrl === "function") return String(cloud.crmUrl()).replace(/admin\.html$/, page);
        return "";
    }
    // глядачі, яким можна дати керування (друзі серед глядачів; без них — усі глядачі)
    function nameOf(id) {
        for (let i = 0; i < viewers.length; i++) if (viewers[i].id === id) return viewers[i].name;
        for (let i = 0; i < friends.length; i++) if (friends[i].id === id) return friends[i].name;
        return "";
    }

    // ── перегляд без гри: заглушки (нічого не надсилає, не вмикає мікрофон, не кодує) ──
    property QtObject demoLive: QtObject {
        id: d
        readonly property int t0: Math.floor(Date.now() / 1000)
        readonly property string ds: api.demoState
        signal message(string text)
        property bool allowed: true
        property bool supported: ds !== "nolive"
        property var features: ({ live: true, helper: true, handoff: true, friends: true, gifts: true })
        property string unsupportedText: qsTr("Трансляція не ввійшла в цю збірку програми. Онови програму.")
        property string state: ds === "off" || ds === "nolive" || ds === "away" || ds === "incoming" ? "off" : ds === "weak" ? "error"
                               : ds === "reconnecting" ? "reconnecting" : ds === "checking" ? "checking" : "live"
        property string statusText: ds === "reconnecting" ? qsTr("Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться.")
                                   : ds === "checking" ? qsTr("Перевіряю інтернет на відправлення (кілька секунд)…")
                                   : ds === "weak" ? qsTr("Трансляцію не ввімкнути: інтернет на відправлення зараз 8,2 Мбіт/с, а трансляції треба щонайменше 18,6 Мбіт/с (гра йде 14,6 Мбіт/с, і глядачі отримують її як є, без перекодування). Що можна зробити: у меню «Зображення» обери якість нижче (гра піде меншим потоком) або під'єднай комп'ютер кабелем і спробуй ще раз.")
                                   : qsTr("Трансляція йде")
        property string quality: "game"
        property bool gameAudio: true
        property string encoderName: ""
        property string gameCodec: ds === "h265" || ds === "off" || ds === "weak" || ds === "pending" ? "H.265" : "H.264"
        property int gameKbps: 14600
        property int gameFps: 60
        property int needKbps: 18600
        property int uplinkKbps: ds === "weak" ? 8200 : 46000
        property bool viewersLag: ds === "lag"
        property bool compatVideo: ds === "on" || ds === "lag" || ds === "pending"
        property bool compatPending: ds === "pending"
        property string browserNote: gameCodec === "H.265"
            ? qsTr("Відео йде у форматі H.265, як його дає приставка. Його показують Safari (iPhone, iPad, Mac) і Chrome від версії 136 на Android, Windows і Mac. У Firefox і старих браузерах буде лише звук і чат. Щоб відео відкривалось будь-де, увімкни «Відео для всіх браузерів».")
            : qsTr("Відео йде у форматі H.264: його показує будь-який сучасний браузер на телефоні, комп'ютері чи телевізорі.")
        property int liveFps: state === "live" ? 60 : 0
        property int liveKbps: state === "live" ? (ds === "lag" ? 9100 : 14800) : 0
        property int liveHeight: 0
        property string roomId: "41"
        property string code: "AB3K9M"
        property string link: "https://t.me/play_any_bot/app?startapp=live_AB3K9M"
        property string webLink: "https://anyplay.example/app/watch.html?r=AB3K9M"
        property string botLink: "https://t.me/play_any_bot?start=live_AB3K9M"
        property string qr: ""
        property int viewerLimit: 5
        property var viewers: state === "off" ? [] : [
            { uid: 7, memberId: 7, userId: 6002, name: "Андрій", role: ds === "friend" ? "helper" : "viewer", mic: true, speaking: true, friend: true, muted: false },
            { uid: 8, memberId: 8, userId: 6003, name: "Оля", role: "viewer", mic: false, speaking: false, friend: true, muted: false },
            { uid: 9, memberId: 9, userId: 6009, name: "Гість з посиланням", role: "viewer", mic: false, speaking: false, friend: false, muted: false }]
        property int viewerCount: viewers.length
        property bool micOn: true
        property int micVolume: 100
        property bool voicesOn: true
        property int voiceVolume: 80
        property var chat: state === "off" ? [] : [
            { id: 1, name: "", text: qsTr("Оля приєдналась до трансляції"), ts: (t0 - 300) * 1000, system: true },
            { id: 2, uid: 7, name: "Андрій", text: qsTr("Бери машину праворуч, там коротше до пристані"), ts: (t0 - 120) * 1000, role: "viewer" },
            { id: 3, uid: 8, name: "Оля", text: qsTr("Ого, яка графіка"), ts: (t0 - 70) * 1000, role: "viewer" },
            { id: 4, name: qsTr("Я"), text: qsTr("Зараз спробую"), ts: (t0 - 40) * 1000, mine: true, role: "player" },
            { id: 5, uid: 7, name: "Андрій", text: qsTr("Обережно, поліція за мостом!"), ts: (t0 - 5) * 1000, role: "viewer" }]
        property int chatUnread: state === "off" ? 0 : 2
        property bool controlActive: ds === "friend"
        property string controlName: ds === "friend" ? "Андрій" : ""
        property real controlUid: ds === "friend" ? 7 : 0
        property string takeBackKey: qsTr("PS на геймпаді або клавіша, що дає PS (P)")
        property string handoverState: ds === "preparing" ? "ready" : ds === "away" ? "active" : ""
        property string handoverName: ds === "preparing" || ds === "away" ? "Андрій" : ""
        property bool handedOver: ds === "away"
        property var offer: ds === "incoming" ? { id: 3, from: "Андрій", state: "ready", until: t0 + 900, waiting: false, roomId: "" } : ({})
        // друзі: C++ їх не дає (контракт.md п. 8: «усе в book.html#friends»); тут лише для перегляду рідного списку
        property var friends: [
            { id: 7, name: "Андрій", username: "@andrii_ps", playing: false, live: null },
            { id: 8, name: "Оля", username: "@olia_vc", playing: false, live: null },
            { id: 10, name: "Максим", username: "@max_gta", playing: true, until: t0 + 2 * 3600 + 600, live: { code: "ZX7Q2M", webLink: "https://anyplay.example/app/watch.html?r=ZX7Q2M" } },
            { id: 11, name: "Ірина", username: "", playing: false, live: null }]
        property var friendRequests: ds === "incoming" || ds === "off" ? [{ id: 12, name: "Тарас", username: "@taras_99" }] : []
        property var friendInvite: ({ link: "https://t.me/play_any_bot?start=f_K7Q2M", code: "K7Q2M", bot: "@play_any_bot" })
        function start(q, a) { gameAudio = a; state = "live"; }
        function stop() { state = "off"; controlActive = false; }
        function setCompatVideo(on) { compatVideo = on; compatPending = on && gameCodec === "H.265"; }
        function holdForReconnect(sec) {}
        function setGameAudio(a) { gameAudio = a; }
        function setMicOn(on) { micOn = on; }
        function setVoicesOn(on) { voicesOn = on; }
        function setVoiceVolume(v) { voiceVolume = v; }
        function sendChat(t) { chat = chat.concat([{ id: Date.now(), name: qsTr("Я"), text: t, ts: Date.now(), mine: true }]); }
        function setMicVolume(v) { micVolume = v; }
        function muteViewer(uid, m) { viewers = viewers.map(v => v.uid === uid ? Object.assign({}, v, { muted: m }) : v); }
        function invite(userId) {}
        function loadConfig() {}
        function prepareHandover(uid) { handoverState = "ready"; handoverName = api.nameOf(uid); }
        function markChatRead() { chatUnread = 0; }
        function kick(uid) { viewers = viewers.filter(v => v.uid !== uid); }
        function grantControl(uid) { controlActive = true; controlName = api.nameOf(uid); controlUid = uid; }
        function takeControl() { controlActive = false; controlName = ""; controlUid = 0; }
        function handoverFull(uid) { handoverState = "active"; handoverName = api.nameOf(uid); handedOver = true; }
        function cancelHandover() { handoverState = ""; handoverName = ""; }
        function returnFull() { handoverState = ""; handoverName = ""; handedOver = false; }
        function acceptHandover(id) { offer = Object.assign({}, offer, { waiting: true }); }
        function setWatching(roomId) {}
        function loadFriends() {}
        function acceptFriend(id) { friendRequests = []; }
        function declineFriend(id) { friendRequests = []; }
        function removeFriend(id) { friends = friends.filter(f => f.id !== id); }
    }
}
