// AnyPlay 116: одне місце, де QML бере трансляцію для друзів, голос, допомогу друга, друзів і подарунки з C++.
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
    // off | on | paused | reduced | nohw | friend | preparing | away | incoming | error
    property string demoState: "on"
    readonly property var cloud: Chiaki.cloud
    readonly property var src: demo ? demoLive : (Chiaki.live ? Chiaki.live : null)
    // друзі: де їх віддасть C++ (у модулі трансляції чи в AnyPlayCloud)
    readonly property var fsrc: demo ? demoLive : (src && src.friends !== undefined ? src : (cloud && cloud.friends !== undefined ? cloud : null))

    readonly property bool available: !!src && src.allowed !== false
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

    // Назви — з контракту «Трансляції» (scratchpad/team7/контракт-трансляція.md, клас AnyPlayLive); у дужках поруч —
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
    // state (для екранів): off — вимкнено; starting — підключаємось; on — іде; paused — сама стала на паузу (гра
    // важливіша); error — не вдалося (reason пояснює). C++: off | starting | live | paused | stopping | error
    readonly property string rawState: src && src.state ? String(src.state) : "off"
    readonly property string state: rawState === "live" ? "on" : rawState === "stopping" ? "off" : rawState
    readonly property bool on: state === "on" || state === "paused" || state === "starting"
    readonly property bool supported: !!src && src.supported !== false           // є апаратний кодувальник
    readonly property string unsupportedText: src && src.unsupportedText ? src.unsupportedText
        : qsTr("На цьому комп'ютері немає апаратного кодування відео. Без нього трансляція забирала б кадри в гри, тож тут її не вмикаємо.")
    readonly property int quality: { const q = parseInt(String(f("quality") || "")); return q === 540 ? 540 : 720; }   // "720p" або 720
    readonly property int liveHeight: Number(f("liveHeight") || 0)
    // знизили якість, щоб не заважати грі (або C++ каже прямо, або шлемо менше, ніж обрано)
    readonly property bool reduced: f("reduced") === true || (state === "on" && liveHeight > 0 && liveHeight < quality)
    // чому пауза, знижено чи помилка (statusText у звичайному стані — «Трансляція йде», його не показуємо)
    readonly property string reason: f("reason") ? String(f("reason"))
        : (state === "paused" || state === "error" || reduced) && f("statusText") ? String(f("statusText")) : ""
    readonly property bool gameAudio: f("gameAudio") !== false
    readonly property string sendText: {
        if (f("sendText")) return String(f("sendText"));
        const h = liveHeight, fps = Number(f("liveFps") || 0), kbps = Number(f("liveKbps") || 0);
        if (!(h > 0)) return "";
        return qsTr("%1p, %2 кадр/с, %3 Мбіт/с").arg(h).arg(fps).arg((kbps / 1000).toFixed(1).replace(".", ","));
    }
    readonly property string encoder: String(f("encoderName", "encoder") || "")
    readonly property int maxViewers: Number(f("viewerLimit", "maxViewers") || 5)
    // [{id, name, role: viewer|helper, speaking, mic, friend?, muted?}] (C++ дає uid — тут це id)
    readonly property var viewers: (f("viewers") || []).map(v => Object.assign({}, v, { id: v.uid !== undefined ? v.uid : v.id }))
    readonly property string watchUrl: String(f("link", "watchUrl") || "")
    readonly property string code: String(f("code") || "")
    readonly property string qr: String(f("qr") || "")              // картинка QR посилання (data: чи image://), якщо C++ дасть
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
    readonly property var chat: f("chat") || []                   // [{id, uid, name, text, ts, mine, system}]
    readonly property int unread: Number(f("chatUnread", "unread") || 0)

    // ── допомога друга ──
    readonly property bool friendControls: f("controlActive") === true || f("control") === "friend"
    readonly property string controlBy: String(f("controlName", "controlBy") || "")
    // чим забрати керування просто в грі: C++ ловить PS (кнопку на геймпаді й клавішу PS гравця) навіть тоді, коли решта
    // вводу гравця ігнорується
    readonly property string takeBackKey: f("takeBackKey") ? String(f("takeBackKey")) : (src ? psKeyText() : "")
    function psKeyText() {
        try {
            const profiles = Chiaki.settings.anyplayProfiles();
            for (let i = 0; i < profiles.length; i++)
                if (profiles[i].id === "global")
                    for (let j = 0; j < profiles[i].bindings.length; j++)
                        if (profiles[i].bindings[j].id === "ps")
                            return qsTr("%1 (або PS на геймпаді)").arg(profiles[i].bindings[j].keyName);
        } catch (e) {}
        return qsTr("PS на геймпаді");
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
    // друг передає гру мені (у програмі друга): C++ offer {roomId, from, until} → {from, end, roomId}
    readonly property var incoming: {
        const o = f("offer");
        if (o && o.from) return { from: o.from, end: o.until || 0, roomId: o.roomId || "" };
        return f("incoming") || null;
    }

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
    readonly property bool qString: !!src && src.controlActive !== undefined   // C++ «Трансляції»: якість рядком "720p"
    function start(q, audio) { return has("start") ? (src.start(qString ? q + "p" : q, audio), true) : call("start"); }
    function stop() { return call("stop"); }
    function setQuality(q) { return has("setQuality") ? (src.setQuality(qString ? q + "p" : q), true) : call("setQuality"); }
    function setGameAudio(on) { return call("setGameAudio", on); }
    function setMic(on) { return call2("setMicOn", "setMic", on); }
    function setMicVolume(v) { return call("setMicVolume", v); }
    function setVoices(on) { return call2("setVoicesOn", "setVoices", on); }
    function setVoicesVolume(v) { return call2("setVoiceVolume", "setVoicesVolume", v); }
    function sendChat(text) { return call("sendChat", text); }
    function markRead() { if (has("markChatRead")) src.markChatRead(); else if (has("markRead")) src.markRead(); }
    function invite(friendId) { return call("invite", friendId); }
    function removeViewer(id) { return call2("kick", "removeViewer", id); }
    function muteViewer(id, on) { return call("muteViewer", id, on); }
    function giveControl(id) { return call2("grantControl", "giveControl", id); }
    function takeControl() { return call("takeControl"); }
    function handoffFull(id) { return call2("handoverFull", "handoffFull", id); }
    function cancelHandoff() { return call2("cancelHandover", "cancelHandoff"); }
    function handoffBack() { return call2("returnFull", "handoffBack"); }
    function acceptHandoff() { return call2("acceptHandover", "acceptHandoff", incoming ? incoming.roomId : ""); }
    // друг відкрив перегляд трансляції в програмі (roomId) чи закрив ("")
    function setWatching(roomId) { if (has("setWatching")) src.setWatching(roomId || ""); }
    function loadFriends() { if (fsrc && typeof fsrc.loadFriends === "function") fsrc.loadFriends(); }
    function acceptFriend(id) { return fcall("acceptFriend", id); }
    function declineFriend(id) { return fcall("declineFriend", id); }
    function removeFriend(id) { return fcall("removeFriend", id); }
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
        property bool supported: ds !== "nohw"
        property string unsupportedText: qsTr("На цьому комп'ютері немає апаратного кодування відео. Без нього трансляція забирала б кадри в гри, тож тут її не вмикаємо.")
        property string state: ds === "off" || ds === "nohw" || ds === "away" || ds === "incoming" ? "off" : ds === "paused" ? "paused" : "live"
        property string statusText: ds === "paused" ? qsTr("Твоя гра почала втрачати кадри, тож трансляцію поставили на паузу. Глядачі бачать «пауза», голос і чат працюють. Відновиться сама, коли стане краще.")
                                   : ds === "reduced" ? qsTr("Вихідний інтернет не тягне 720p, тож шлемо глядачам 540p. Твоя гра від цього не змінюється.") : qsTr("Трансляція йде")
        property string quality: "720p"
        property bool gameAudio: true
        property string encoderName: "h264_nvenc"
        property int liveFps: 30
        property int liveKbps: ds === "reduced" ? 1200 : 2300
        property int liveHeight: state === "off" ? 0 : ds === "reduced" ? 540 : 720
        property string roomId: "r_ab12"
        property string link: "https://anyplay.example/app/watch.html?r=r_ab12&c=482913"
        property string code: "482913"
        property int viewerLimit: 5
        property var viewers: state === "off" ? [] : [
            { uid: 7, name: "Андрій", role: ds === "friend" ? "helper" : "viewer", mic: true, speaking: true, friend: true },
            { uid: 8, name: "Оля", role: "viewer", mic: false, speaking: false, friend: true },
            { uid: 9, name: "Гість з посиланням", role: "viewer", mic: false, speaking: false, friend: false }]
        property bool micOn: true
        property bool voicesOn: true
        property int voiceVolume: 80
        property var chat: state === "off" ? [] : [
            { id: 1, name: "", text: qsTr("Оля приєдналась до трансляції"), ts: t0 - 300, system: true },
            { id: 2, uid: 7, name: "Андрій", text: qsTr("Бери машину праворуч, там коротше до пристані"), ts: t0 - 120 },
            { id: 3, uid: 8, name: "Оля", text: qsTr("Ого, яка графіка"), ts: t0 - 70 },
            { id: 4, name: qsTr("Я"), text: qsTr("Зараз спробую"), ts: t0 - 40, mine: true },
            { id: 5, uid: 7, name: "Андрій", text: qsTr("Обережно, поліція за мостом!"), ts: t0 - 5 }]
        property int chatUnread: state === "off" ? 0 : 2
        property bool controlActive: ds === "friend"
        property string controlName: ds === "friend" ? "Андрій" : ""
        property real controlUid: ds === "friend" ? 7 : 0
        property string handoverState: ds === "preparing" ? "offered" : ds === "away" ? "active" : ""
        property string handoverName: ds === "preparing" || ds === "away" ? "Андрій" : ""
        property bool handedOver: ds === "away"
        property var offer: ds === "incoming" ? { roomId: "r_cd34", from: "Андрій", until: t0 + 2 * 3600 } : ({})
        // друзі: ні в контракті «Трансляції», ні в «Сервера» для C++ ще немає (див. звіт «Програми»)
        property var friends: [
            { id: 7, name: "Андрій", username: "@andrii_ps", playing: false, live: false },
            { id: 8, name: "Оля", username: "@olia_vc", playing: false, live: false },
            { id: 10, name: "Максим", username: "@max_gta", playing: true, until: t0 + 2 * 3600 + 600, live: true, canWatch: true, roomId: "r_ef56" },
            { id: 11, name: "Ірина", username: "", playing: false, live: false }]
        property var friendRequests: ds === "incoming" || ds === "off" ? [{ id: 12, name: "Тарас", username: "@taras_99" }] : []
        property var friendInvite: ({ link: "https://t.me/play_any_bot?start=f_K7Q2M", code: "K7Q2M", bot: "@play_any_bot" })
        function start(q, a) { quality = q; gameAudio = a; state = "live"; }
        function stop() { state = "off"; controlActive = false; }
        function setQuality(q) { quality = q; }
        function setGameAudio(a) { gameAudio = a; }
        function setMicOn(on) { micOn = on; }
        function setVoicesOn(on) { voicesOn = on; }
        function setVoiceVolume(v) { voiceVolume = v; }
        function sendChat(t) { chat = chat.concat([{ id: Date.now(), name: qsTr("Я"), text: t, ts: Math.floor(Date.now() / 1000), mine: true }]); }
        function markChatRead() { chatUnread = 0; }
        function kick(uid) { viewers = viewers.filter(v => v.uid !== uid); }
        function grantControl(uid) { controlActive = true; controlName = api.nameOf(uid); controlUid = uid; }
        function takeControl() { controlActive = false; controlName = ""; controlUid = 0; }
        function handoverFull(uid) { handoverState = "offered"; handoverName = api.nameOf(uid); }
        function cancelHandover() { handoverState = ""; handoverName = ""; }
        function returnFull() { handoverState = ""; handoverName = ""; handedOver = false; }
        function acceptHandover(roomId) { offer = ({}); }
        function setWatching(roomId) {}
        function loadFriends() {}
        function acceptFriend(id) { friendRequests = []; }
        function declineFriend(id) { friendRequests = []; }
        function removeFriend(id) { friends = friends.filter(f => f.id !== id); }
    }
}
