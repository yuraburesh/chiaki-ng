// AnyPlay 116: головне вікно → вкладка «Друзі».
// Ліворуч: передана гра («Андрій передав тобі гру» → «Грати»; «Ти передав гру Андрію» → «Повернути собі»), запити в друзі,
// список друзів: хто грає зараз і до котрої, хто в ефірі («Дивитись» → watch.html у вбудованому браузері), «Подарунок».
// Праворуч: «Додати друга» (посилання-запрошення для Telegram, код), «Подарунки» (book.html у вбудованому браузері:
// поповнити баланс друга, переказати зі свого, забронювати години для друга), де шукати трансляцію й допомогу друга.
// Дані — через AnyPlayLiveApi. C++ друзів не дає (контракт.md п. 8: «усе в book.html#friends»), тож типово вкладка — це
// сторінка book.html#friends у вбудованому браузері (той самий список, запити, «Додати друга», подарунки, «Дивитись»),
// а над нею — картки переданої гри. Рідний список нижче — коли C++ колись дасть friends (і для перегляду на заглушках).
// Адреси: watch.html?r=<код кімнати, 6 символів>, book.html#friends, book.html#gift=<id друга>.
// Поверх гри вбудований браузер не відкриваємо (як і CRM): гравцю нічого не має заважати.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: fr
    property var api: null
    property var cloud: Chiaki.cloud
    property bool overGame: false
    property real padX: 32
    property real cw: width - 2 * padX
    property bool twoCol: cw >= 840
    property real colGap: 28
    property real leftW: twoCol ? Math.floor((cw - colGap) * 1.2 / 2.2) : cw
    property real rightW: twoCol ? cw - colGap - leftW : cw
    signal toast(string text)
    AnyPlayStyle { id: ap }

    // відкрита сторінка сервера ("" — список друзів)
    property string webUrl: ""
    property string webTitle: ""
    property bool webMic: false
    readonly property bool canWeb: !overGame && !!cloud && cloud.webEngine === true
    // сторінка друзів з сервера замість рідного списку
    readonly property bool embedded: !!api && !api.friendsAvailable && canWeb
    // код кімнати з адреси watch.html?r=КОД (друг дивиться трансляцію — програма питає, чи не передають йому гру)
    function codeOf(u) { const m = String(u).match(/watch\.html\?(?:.*&)?r=([A-Za-z0-9]{4,12})/); return m ? m[1] : ""; }
    function openWeb(url, title, mic) {
        if (!url) return;
        if (!canWeb) { fr.toast(overGame ? qsTr("Це відкривається поза грою або в боті") : qsTr("Відкрий це в боті: у цій збірці немає вбудованого браузера")); return; }
        webTitle = title; webMic = !!mic; webUrl = url;
    }
    function watch(f) {
        const code = f.live && f.live.code ? f.live.code : "";
        if (!code) return;
        openWeb(api.webUrl("watch.html?r=" + encodeURIComponent(code)), qsTr("Трансляція: %1").arg(f.name), true);
        if (webUrl !== "") api.setWatching(code);   // поки дивимось, програма питає, чи не передають нам гру
    }
    function gift(f) { openWeb(api.webUrl("book.html") + (f ? "#gift=" + f.id : "#gift"), f ? qsTr("Подарунок: %1").arg(f.name) : qsTr("Подарунки"), false); }
    onVisibleChanged: { if (visible) { api.loadFriends(); api.loadConfig(); } else webUrl = ""; }
    onWebUrlChanged: if (webUrl === "") api.setWatching("")
    Timer { interval: 30000; repeat: true; running: fr.visible && fr.webUrl === ""; onTriggered: fr.api.loadFriends() }

    property int tick: 0
    Timer { interval: 30000; repeat: true; running: fr.visible; onTriggered: fr.tick++ }
    function untilText(ts) { return ts > 0 && cloud && typeof cloud.formatTime === "function" ? cloud.formatTime(ts) : ""; }

    property var confirmRemove: null
    Timer { id: confirmTimer; interval: 5000; onTriggered: fr.confirmRemove = null }

    // ═════ вкладка = book.html#friends (C++ друзів не дає): картки переданої гри зверху, далі сторінка ═════
    ColumnLayout {
        visible: fr.embedded && fr.webUrl === ""
        anchors.fill: parent
        anchors.topMargin: 10
        spacing: 10
        Item {
            visible: !!fr.api.incoming || fr.api.handoff !== ""
            Layout.fillWidth: true
            Layout.leftMargin: fr.padX; Layout.rightMargin: fr.padX
            implicitHeight: topCards.implicitHeight
            ColumnLayout {
                id: topCards
                width: parent.width
                spacing: 10
                IncomingCard { }
                LentCard { }
            }
        }
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: fr.embedded && fr.visible
            sourceComponent: AnyPlayWebPage {
                url: fr.api.webUrl("book.html#friends")
                title: qsTr("Друзі й подарунки")
                showBack: false
                allowMic: true          // «Дивитись» відкриває watch.html тут же: голос у трансляції
                contentWidth: fr.cw
                onMoved: (u) => fr.api.setWatching(fr.codeOf(u))
            }
        }
    }

    // ═════ сторінка сервера у вбудованому браузері ═════
    Loader {
        anchors.fill: parent
        active: fr.webUrl !== ""
        visible: active
        sourceComponent: AnyPlayWebPage {
            url: fr.webUrl
            title: fr.webTitle
            allowMic: fr.webMic
            contentWidth: fr.cw
            onBack: fr.webUrl = ""
            onMoved: (u) => fr.api.setWatching(fr.codeOf(u))
        }
    }

    // ═════ список ═════
    Flickable {
        id: pg
        visible: fr.webUrl === "" && !fr.embedded
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: inner.childrenRect.height + 48
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
            policy: pg.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
        }
        Item {
            id: inner
            x: fr.padX; y: 22
            width: fr.cw
            height: childrenRect.height

            GridLayout {
                width: fr.cw
                columns: fr.twoCol ? 2 : 1
                columnSpacing: fr.colGap
                rowSpacing: 22

                // ── ліворуч: друзі ──
                ColumnLayout {
                    Layout.preferredWidth: fr.leftW
                    Layout.maximumWidth: fr.leftW
                    Layout.alignment: Qt.AlignTop
                    spacing: 14

                    RowLayout {
                        spacing: 12
                        ApText { role: "h2"; text: qsTr("Друзі") }
                        ApChip { visible: fr.api.friends.length > 0; text: fr.api.friends.length }
                    }

                    // передана гра («Передати повністю»): мені — або від мене
                    IncomingCard { }
                    LentCard { }

                    // запити в друзі
                    ColumnLayout {
                        visible: fr.api.friendRequests.length > 0
                        Layout.fillWidth: true
                        spacing: 0
                        ApText { role: "cap"; text: qsTr("Хочуть додати тебе"); Layout.bottomMargin: 4 }
                        Repeater {
                            model: fr.api.friendRequests
                            ApRow {
                                required property var modelData
                                title: modelData.name
                                subtitle: modelData.username || ""
                                ApButton { small: true; text: qsTr("Прийняти"); onClicked: { fr.api.acceptFriend(modelData.id); fr.toast(qsTr("%1 тепер у друзях").arg(modelData.name)); } }
                                ApButton { small: true; ghost: true; text: qsTr("Відхилити"); onClicked: fr.api.declineFriend(modelData.id) }
                            }
                        }
                    }

                    // список
                    ColumnLayout {
                        visible: fr.api.friendsAvailable
                        Layout.fillWidth: true
                        spacing: 0
                        ApText {
                            visible: fr.api.friends.length === 0
                            Layout.fillWidth: true
                            role: "lead"
                            text: qsTr("Поки нікого. Надішли другу запрошення праворуч: він відкриє його в Telegram, і ви одразу друзі.")
                        }
                        Repeater {
                            model: fr.api.friends
                            FriendRow { required property var modelData; f: modelData }
                        }
                    }
                    // без даних про друзів від програми: сторінка друзів з бота
                    ApCard {
                        visible: !fr.api.friendsAvailable
                        title: qsTr("Друзі й подарунки")
                        ApText {
                            Layout.fillWidth: true
                            role: "body"
                            text: qsTr("Список друзів, запрошення й подарунки відкриваються зі сторінки AnyPlay, тієї самої, що в боті.")
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 10
                            ApButton { visible: fr.canWeb; text: qsTr("Відкрити"); onClicked: fr.openWeb(fr.api.webUrl("book.html") + "#friends", qsTr("Друзі"), false) }
                            ApButton { ghost: true; text: qsTr("Відкрити в боті"); onClicked: fr.cloud.openBot() }
                        }
                    }
                }

                // ── праворуч: додати, подарунки, трансляція ──
                ColumnLayout {
                    Layout.preferredWidth: fr.rightW
                    Layout.maximumWidth: fr.rightW
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: fr.twoCol ? 6 : 0
                    spacing: 18

                    ApCard {
                        visible: !!fr.api.friendInvite
                        title: qsTr("Додати друга")
                        ApText {
                            Layout.fillWidth: true
                            role: "small"; color: ap.mute
                            text: qsTr("Друг відкриває посилання в Telegram, і ви одразу друзі. Або хай введе код у боті %1.").arg(fr.api.friendInvite && fr.api.friendInvite.bot ? fr.api.friendInvite.bot : "@play_any_bot")
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14
                            ApText {
                                role: "big"; size: 34
                                color: ap.gold
                                font.letterSpacing: 5
                                text: fr.api.friendInvite ? fr.api.friendInvite.code : ""
                            }
                            Text {
                                Layout.fillWidth: true
                                text: fr.api.friendInvite ? String(fr.api.friendInvite.link).replace(/^https?:\/\//, "") : ""
                                elide: Text.ElideMiddle
                                font.family: ap.body; font.pixelSize: ap.fsSub
                                color: ap.faint
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 10
                            ApButton {
                                small: true
                                text: qsTr("Надіслати в Telegram")
                                onClicked: fr.cloud.openExternal("https://t.me/share/url?url=" + encodeURIComponent(fr.api.friendInvite.link)
                                                                 + "&text=" + encodeURIComponent(qsTr("Додай мене в друзі в AnyPlay")))
                            }
                            ApButton {
                                small: true; ghost: true
                                text: qsTr("Копіювати посилання")
                                onClicked: { fr.cloud.copyText(fr.api.friendInvite.link); fr.toast(qsTr("Посилання скопійовано")); }
                            }
                        }
                    }

                    ApCard {
                        visible: fr.api.featGifts
                        title: qsTr("Подарунки")
                        spacing: 4
                        GiftRow { title: qsTr("Поповнити баланс друга"); subtitle: qsTr("оплатою, як звичайне поповнення") }
                        GiftRow { title: qsTr("Переказати зі свого балансу"); subtitle: qsTr("одразу, друг побачить у своїй історії") }
                        GiftRow { title: qsTr("Забронювати години для друга"); subtitle: qsTr("бронь на друга, оплачуєш ти"); hairline: false }
                        ApText {
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            role: "small"
                            text: fr.canWeb ? qsTr("Друг отримає сповіщення в боті.")
                                            : fr.overGame ? qsTr("Подарунки відкриваються поза грою або в боті. Друг отримає сповіщення в боті.")
                                            : qsTr("Подарунки — у боті. Друг отримає сповіщення там само.")
                        }
                    }

                    ApCard {
                        title: qsTr("Трансляція і допомога друга")
                        spacing: 6
                        ApText {
                            Layout.fillWidth: true
                            role: "small"; color: ap.mute
                            text: qsTr("Почати трансляцію, голосовий чат і «Допомога друга» — у меню під час гри: клавіша ` (під Esc), пункт «Друзі й трансляція». Друзі дивляться з телефона, комп'ютера чи просто в Telegram.")
                        }
                    }
                }
            }
        }
    }

    // ── рядок друга: буква-аватар, ім'я, що робить зараз, дії ──
    component FriendRow: Item {
        id: row
        property var f: ({})
        readonly property bool asking: fr.confirmRemove === f.id
        Layout.fillWidth: true
        implicitHeight: Math.max(64, texts.implicitHeight + 22)
        Rectangle {   // наведення
            anchors { fill: parent; topMargin: 2; bottomMargin: 2 }
            radius: ap.radiusSmall
            color: ap.glass
            opacity: hov.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: ap.tHover } }
        }
        HoverHandler { id: hov }
        Rectangle {   // аватар: перша літера на заході сонця; в ефірі — блакитне кільце
            id: avatar
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 40; height: 40; radius: 20
            gradient: Gradient { GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            border.width: row.f.live ? 2 : 0
            border.color: ap.cyan
            Text {
                anchors.centerIn: parent
                text: (row.f.name || "?").charAt(0).toUpperCase()
                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 19
                color: ap.inkAccent
            }
            Rectangle {   // грає зараз: зелена крапка
                visible: !!row.f.playing
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: -1; bottomMargin: -1 }
                width: 12; height: 12; radius: 6
                color: ap.ok
                border.width: 2; border.color: ap.bg1
            }
        }
        Column {
            id: texts
            anchors { left: avatar.right; leftMargin: 14; right: acts.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 3
            Row {
                spacing: 8
                width: parent.width
                Text {
                    text: row.f.name || ""
                    font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: ap.fsBody
                    color: ap.ink
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - (liveChip.visible ? liveChip.width + 8 : 0))
                }
                ApChip { id: liveChip; visible: !!row.f.live; kind: "live"; text: qsTr("В ефірі"); height: 22; anchors.verticalCenter: parent.verticalCenter }
            }
            Text {
                width: parent.width
                text: { fr.tick; return row.asking ? qsTr("натисни «Так, прибрати», щоб прибрати з друзів")
                    : row.f.playing ? (row.f.until ? qsTr("грає зараз, до %1").arg(fr.untilText(row.f.until)) : qsTr("грає зараз"))
                    : (row.f.username ? row.f.username + ", " : "") + qsTr("не грає"); }
                elide: Text.ElideRight
                font.family: ap.body; font.pixelSize: ap.fsSub
                color: row.asking ? ap.gold : row.f.playing ? ap.ok : ap.faint
            }
        }
        Row {
            id: acts
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 8
            ApButton {
                visible: !!row.f.live && row.f.canWatch !== false && !row.asking
                small: true
                enabled: !fr.overGame
                text: qsTr("Дивитись")
                onClicked: fr.watch(row.f)
            }
            ApButton {
                visible: !row.asking && fr.api.featGifts
                small: true; ghost: true
                text: qsTr("Подарунок")
                onClicked: fr.gift(row.f)
            }
            ApButton {
                small: true; ghost: !row.asking; danger: row.asking
                text: row.asking ? qsTr("Так, прибрати") : "✕"
                onClicked: {
                    if (row.asking) { fr.confirmRemove = null; fr.api.removeFriend(row.f.id); }
                    else { fr.confirmRemove = row.f.id; confirmTimer.restart(); }
                }
            }
        }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: ap.hair }
    }

    component GiftRow: ApRow {
        clickable: true
        onClicked: fr.gift(null)
        Text { text: "›"; font.family: ap.body; font.pixelSize: 22; color: ap.faint }
    }

    // ── друг передає мені гру ──
    component IncomingCard: StateCard {
        visible: !!fr.api.incoming
        edgeColor: ap.cyan
        eyebrow: fr.api.incomingTitle
        text: fr.api.incomingText
        ApButton { visible: !!fr.api.incoming && !fr.api.incoming.waiting; text: qsTr("▶ Грати"); onClicked: fr.api.acceptHandoff() }
    }
    // ── я передав гру другу ──
    component LentCard: StateCard {
        visible: fr.api.handoff !== ""
        edgeColor: ap.gold
        eyebrow: fr.api.handoff === "preparing" ? qsTr("Готуємо гру для друга") : qsTr("Гру передано другу")
        text: qsTr("Зараз грає %1. Час броні йде, як і йшов; повернути гру собі можна будь-коли.").arg(fr.api.handoffTo)
        ApButton {
            text: fr.api.handoff === "preparing" ? qsTr("Скасувати") : qsTr("Повернути собі")
            onClicked: {
                if (fr.api.handoff === "preparing") { fr.api.cancelHandoff(); return; }
                fr.api.handoffBack();
                fr.toast(qsTr("Повертаємо гру: у друга вона зупиниться за кілька секунд"));
            }
        }
    }

    // ── картка стану (передана гра): кольорова смужка зліва, надпис, текст, кнопки ──
    component StateCard: Item {
        id: sc
        property color edgeColor: ap.cyan
        property string eyebrow
        property string text
        default property alias buttons: btns.data
        Layout.fillWidth: true
        implicitHeight: scCol.implicitHeight + 32
        Rectangle {
            anchors.fill: parent
            radius: ap.cardRadius
            color: ap.card
            border.width: 1; border.color: Qt.rgba(sc.edgeColor.r, sc.edgeColor.g, sc.edgeColor.b, 0.6)
            Rectangle { x: 0; y: 12; width: 3; height: parent.height - 24; radius: 1.5; color: sc.edgeColor }
        }
        ColumnLayout {
            id: scCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 22; rightMargin: 18 }
            spacing: 8
            ApText { role: "cap"; color: sc.edgeColor; text: sc.eyebrow }
            ApText { Layout.fillWidth: true; role: "body"; text: sc.text }
            Flow { id: btns; Layout.fillWidth: true; Layout.topMargin: 4; spacing: 10 }
        }
    }
}
