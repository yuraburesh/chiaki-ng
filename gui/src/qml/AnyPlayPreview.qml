// AnyPlay: маленьке вікно в панелі адміна з тим, що зараз бачить клієнт.
// Поки це вікно відкрите, сервер просить програму клієнта надсилати зменшений кадр раз на ~1,5 с
// (з затримкою кілька секунд і простою якістю; на саму гру клієнта це не впливає).
// Програма клієнта дізнається про запит лише зі свого наступного сигналу серверу (heartbeat, до 20 с), тож перший кадр
// може йти 20–40 с. AnyPlay 115: вікно саме не закривається і показує ясний стан: клієнт на програмі без перегляду,
// чекаю (скільки секунд і до коли), кадр N с тому, картинки давно немає (з кнопкою «Спробувати ще раз»).
// Стан «дивлюсь» живе в store (AnyPlayHome): картка приставки перестворюється з кожним оновленням панелі (раз на 15 с),
// і до 115 разом з нею зникав і перегляд («вантажиться пару секунд і закривається»).
// Необов'язкові поля Chiaki.cloud (якщо програма їх має, див. звіт «Меню» етапу 5): previewState (ok | wait | offline |
// unsupported — заголовок X-Preview-State), previewNext (X-Preview-Next: коли програма клієнта найпізніше дізнається про
// запит, час сервера), previewFrameAt (X-Preview-At: коли сервер отримав кадр). Без них стан рахуємо самі.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: pv
    property var cloud: Chiaki.cloud
    property var bookingId: 0
    property var userId: 0               // гість без броні (bookingId 0): дивимось за userId
    // ключ перегляду: номер броні, а для гостя — мінус userId (щоб не плутати з бронями)
    readonly property var key: Number(bookingId) > 0 ? Number(bookingId) : (Number(userId) > 0 ? -Number(userId) : 0)
    function load() { cloud.loadPreview(Number(bookingId) > 0 ? Number(bookingId) : 0, Number(userId) > 0 ? Number(userId) : 0); }
    property var live: null              // телеметрія гри клієнта (current.live): платформа, збірка
    property QtObject store: null        // спільний стан перегляду (AnyPlayHome), щоб він переживав перестворення картки
    spacing: 8
    AnyPlayStyle { id: ap }

    QtObject {   // запасний стан, якщо store не передали
        id: ownStore
        property var booking: 0
        property bool big: false
        property real since: 0
        property string lastImage: ""
        property real frameSeenAt: 0
    }
    readonly property QtObject st: store || ownStore
    readonly property bool watching: key !== 0 && st.booking === key
    readonly property bool big: watching && st.big
    property int tick: 0

    // ── стан ──
    readonly property string srvState: typeof cloud.previewState === "string" ? cloud.previewState : ""
    readonly property int build: live && live.build ? Number(live.build) : 0
    readonly property bool unsupported: (typeof cloud.previewLive !== "string" || cloud.previewLive === "")
        && (srvState === "unsupported" || (!!live && ((live.platform === "android" && build < 156) || (build > 0 && build < 110))))
    readonly property bool hasImage: watching && cloud.previewImage !== ""
    function nowSrv() { tick; return Date.now() / 1000 + (cloud.clockSkew || 0); }
    readonly property int waited: { tick; return watching && st.since > 0 ? Math.max(0, Math.floor((Date.now() - st.since) / 1000)) : 0; }
    readonly property int frameAge: {
        tick;
        if (!hasImage) return -1;
        if (cloud.previewFrameAt > 0) return Math.max(0, Math.floor(nowSrv() - cloud.previewFrameAt));
        return st.frameSeenAt > 0 ? Math.max(0, Math.floor((Date.now() - st.frameSeenAt) / 1000)) : 0;
    }
    readonly property int nextIn: { tick; return cloud.previewNext > 0 ? Math.max(0, Math.round(cloud.previewNext - nowSrv())) : -1; }
    // що показати: unsupported | wait | offline | none (довго немає кадру) | ok | stale
    readonly property string state_: !watching ? "" : (typeof cloud.previewLive === "string" && cloud.previewLive !== "") ? "live" : unsupported ? "unsupported"
        : hasImage ? (frameAge > 8 ? "stale" : "ok")
        : srvState === "offline" ? "offline"
        : waited >= 40 ? "none" : "wait"

    function start() {
        if (key === 0) return;
        if (st.booking !== key) cloud.clearPreview();
        st.booking = key;
        st.since = Date.now();
        st.lastImage = "";
        st.frameSeenAt = 0;
        load();
    }
    function stop() { st.booking = 0; st.big = false; cloud.clearPreview(); }
    function retry() { cloud.clearPreview(); st.since = Date.now(); st.lastImage = ""; st.frameSeenAt = 0; load(); }

    // кадр справді новий (а не той самий, що сервер віддав ще раз): запам'ятати, коли побачили
    Connections {
        target: pv.cloud
        function onPreviewChanged() {
            if (!pv.watching) return;
            const img = pv.cloud.previewImage;
            if (img !== "" && img !== pv.st.lastImage) { pv.st.lastImage = img; pv.st.frameSeenAt = Date.now(); }
        }
    }
    Timer {   // забираємо кадр раз на 1,5 с; кожен запит ще й продовжує прохання до програми клієнта
        interval: 1500; repeat: true; triggeredOnStart: true
        running: pv.visible && pv.watching   // 156: і для «без перегляду»: запит адміна вмикає відео прихованою трансляцією
        onTriggered: pv.load()
    }
    Timer { interval: 1000; repeat: true; running: pv.visible && pv.watching; onTriggered: pv.tick++ }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        ApText { role: "cap"; text: qsTr("Екран клієнта") }
        ApChip {
            visible: pv.state_ !== ""
            text: {
                switch (pv.state_) {
                case "live": return qsTr("відео наживо");
                case "unsupported": return qsTr("без перегляду");
                case "wait": return qsTr("чекаю, %1 с").arg(pv.waited);
                case "offline": return qsTr("клієнт не в грі");
                case "none": return qsTr("картинки немає %1 с").arg(pv.waited);
                case "ok": return pv.frameAge <= 1 ? qsTr("кадр щойно") : qsTr("кадр %1 с тому").arg(pv.frameAge);
                case "stale": return qsTr("кадр %1 с тому").arg(pv.frameAge);
                }
                return "";
            }
            kind: ({ live: "ok", unsupported: "bad", wait: "live", offline: "wait", none: "bad", ok: "ok", stale: "wait" })[pv.state_] || ""
        }
        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
        ApButton {
            small: true; ghost: true
            text: pv.watching ? qsTr("Сховати") : qsTr("Дивитись")
            onClicked: pv.watching ? pv.stop() : pv.start()
        }
        ApButton {
            visible: pv.watching && !pv.unsupported
            small: true; ghost: true
            text: pv.big ? qsTr("Менше") : qsTr("Збільшити")
            onClicked: pv.st.big = !pv.st.big
        }
    }
    Rectangle {
        visible: pv.watching && !pv.unsupported
        Layout.fillWidth: true
        Layout.preferredHeight: liveView.active ? width * 9 / 16 + 200 : width * 9 / 16
        Layout.maximumWidth: pv.big ? 100000 : (liveView.active ? 640 : 420)
        color: "#40000000"
        border.width: 1
        border.color: ap.hair
        // 156: гравець веде приховану трансляцію для адміна — справжнє відео замість знімків
        Loader {
            id: liveView
            anchors.fill: parent
            anchors.margins: 1
            active: pv.watching && typeof pv.cloud.previewLive === "string" && pv.cloud.previewLive !== "" && pv.cloud.webEngine === true
            sourceComponent: AnyPlayWebPage {
                url: pv.cloud.webAppUrl("watch.html?r=" + encodeURIComponent(pv.cloud.previewLive))
                title: qsTr("Відео наживо")
                showBack: false
            }
        }
        Image {
            visible: !liveView.active
            anchors.fill: parent
            anchors.margins: 1
            fillMode: Image.PreserveAspectFit
            source: pv.watching ? pv.cloud.previewImage : ""
            cache: false
            smooth: true
            opacity: pv.state_ === "stale" ? 0.55 : 1
        }
        ColumnLayout {   // поки кадру немає: що відбувається і скільки чекати
            visible: !pv.hasImage && !liveView.active
            anchors.centerIn: parent
            width: parent.width - 32
            spacing: 10
            ApText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                role: "small"
                color: pv.state_ === "none" ? ap.bad : ap.mute
                text: {
                    if (pv.state_ === "offline")
                        return qsTr("Клієнт зараз не в грі: програма не шле картинку. Перегляд лишається відкритим, кадр з'явиться, щойно гра почнеться.");
                    if (pv.state_ === "none")
                        return qsTr("Картинки немає вже %1 с. Можливо, гра в клієнта згорнута або програма не змогла зняти кадр. Чекаю далі, можна спробувати ще раз.").arg(pv.waited);
                    const when = pv.nextIn > 0 ? qsTr(" Програма клієнта дізнається про запит за %1 с.").arg(pv.nextIn)
                                               : qsTr(" Програма клієнта дізнається про запит, коли наступного разу озветься до сервера (до 20 с).");
                    return qsTr("Чекаю на перший кадр: %1 с.").arg(pv.waited) + when;
                }
            }
            ApButton {
                visible: pv.state_ === "none" || pv.state_ === "offline"
                Layout.alignment: Qt.AlignHCenter
                small: true; ghost: true
                text: qsTr("Спробувати ще раз")
                onClicked: pv.retry()
            }
            Rectangle {   // скільки з 40 с очікування минуло
                visible: pv.state_ === "wait"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(220, parent.width)
                Layout.preferredHeight: 2
                color: ap.hair
                Rectangle {
                    height: parent.height
                    width: parent.width * Math.min(1, pv.waited / 40)
                    color: ap.cyan
                }
            }
        }
    }
    RowLayout {
        visible: pv.watching
        Layout.fillWidth: true
        spacing: 10
        ApText {
            Layout.fillWidth: true
            role: "small"
            color: pv.state_ === "unsupported" ? ap.gold : ap.faint
            text: pv.state_ === "unsupported"
                ? (pv.live && pv.live.platform === "android"
                    ? qsTr("Клієнт грає з телефона: програма для Android картинку для перегляду не шле.")
                    : qsTr("У клієнта збірка %1: перегляд гри є з 110. Він з'явиться, коли клієнт оновить програму.").arg(pv.build || qsTr("стара")))
                : pv.state_ === "stale"
                    ? qsTr("Картинка давно не оновлювалась: клієнт згорнув гру або зник зв'язок. Чекаю на новий кадр.")
                    : qsTr("Затримка кілька секунд і проста якість: у клієнта картинка краща. На його гру це не впливає.")
        }
        ApButton {   // картинка застаріла: попросити ще раз
            visible: pv.state_ === "stale"
            small: true; ghost: true
            text: qsTr("Спробувати ще раз")
            onClicked: pv.retry()
        }
    }
}
