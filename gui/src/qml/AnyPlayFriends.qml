// AnyPlay 116: головне вікно → вкладка «Друзі».
// Ліворуч: передана гра («Андрій передав тобі гру» → «Грати»; «Ти передав гру Андрію» → «Повернути собі»), запити в друзі,
// список друзів: хто грає зараз і до котрої, хто в ефірі («Дивитись» → watch.html у вбудованому браузері), «Подарунок».
// Праворуч: «Додати друга» (посилання-запрошення для Telegram, код), «Подарунки» (book.html у вбудованому браузері:
// поповнити баланс друга, переказати зі свого, забронювати години для друга), де шукати трансляцію й допомогу друга.
// Дані — через AnyPlayLiveApi. Без даних про друзів від C++ — сторінка друзів з book.html у вбудованому браузері.
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
    function openWeb(url, title, mic) {
        if (!url) return;
        if (!canWeb) { fr.toast(overGame ? qsTr("Це відкривається поза грою або в боті") : qsTr("Відкрий це в боті: у цій збірці немає вбудованого браузера")); return; }
        webTitle = title; webMic = !!mic; webUrl = url;
    }
    function watch(f) {
        const u = f.watchUrl || (api.webUrl("watch.html") + (f.roomId ? "?r=" + encodeURIComponent(f.roomId) : "?friend=" + f.id));
        openWeb(u, qsTr("Трансляція: %1").arg(f.name), true);
        if (webUrl !== "") api.setWatching(f.roomId || "");   // поки дивимось, програма питає, чи не передають нам гру
    }
    function gift(f) { openWeb(api.webUrl("book.html") + (f ? "#gift=" + f.id : "#gift"), f ? qsTr("Подарунок: %1").arg(f.name) : qsTr("Подарунки"), false); }
    onVisibleChanged: { if (visible) api.loadFriends(); else webUrl = ""; }
    onWebUrlChanged: if (webUrl === "") api.setWatching("")
    Timer { interval: 30000; repeat: true; running: fr.visible && fr.webUrl === ""; onTriggered: fr.api.loadFriends() }

    property int tick: 0
    Timer { interval: 30000; repeat: true; running: fr.visible; onTriggered: fr.tick++ }
    function untilText(ts) { return ts > 0 && cloud && typeof cloud.formatTime === "function" ? cloud.formatTime(ts) : ""; }

    property var confirmRemove: null
    Timer { id: confirmTimer; interval: 5000; onTriggered: fr.confirmRemove = null }

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
        }
    }

    // ═════ список ═════
    Flickable {
        id: pg
        visible: fr.webUrl === ""
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

                    // друг передав мені гру («Передати повністю»)
                    StateCard {
                        visible: !!fr.api.incoming
                        edgeColor: ap.cyan
                        eyebrow: qsTr("Тобі передали гру")
                        text: fr.api.incoming ? qsTr("Гру тобі передає %1, до %2. Граєш зі своєї програми, без затримки; власник броні може будь-коли повернути її собі.")
                                                .arg(fr.api.incoming.from).arg(fr.untilText(fr.api.incoming.end)) : ""
                        ApButton { text: qsTr("▶ Грати"); onClicked: fr.api.acceptHandoff() }
                    }
                    // я передав гру другу
                    StateCard {
                        visible: fr.api.handoff !== ""
                        edgeColor: ap.gold
                        eyebrow: fr.api.handoff === "preparing" ? qsTr("Готуємо гру для друга") : fr.api.handoff === "returning" ? qsTr("Повертаємо гру тобі") : qsTr("Гру передано другу")
                        text: fr.api.handoff === "returning" ? qsTr("Ще кілька секунд, і можна грати.")
                            : qsTr("Зараз грає %1. Час броні йде, як і йшов; повернути гру собі можна будь-коли.").arg(fr.api.handoffTo)
                        ApButton {
                            visible: fr.api.handoff !== "returning"
                            text: qsTr("Повернути собі")
                            onClicked: { fr.api.handoffBack(); fr.toast(qsTr("Повертаємо гру: у друга вона зупиниться за кілька секунд")); }
                        }
                        ApButton {
                            readonly property var f: fr.api.friends.find(x => x.name === fr.api.handoffTo && x.live)
                            visible: !!f
                            ghost: true
                            text: qsTr("Дивитись")
                            onClicked: fr.watch(f)
                        }
                    }

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
                visible: !row.asking
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
