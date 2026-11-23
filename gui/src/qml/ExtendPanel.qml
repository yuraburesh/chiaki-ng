// AnyPlay: продовження гри й оплата прямо в програмі (з головного екрана і з меню під час гри).
// Обраний час одразу закривається для інших у боті; оплата перевіряється автоматично або адміном.
// Оплата: з балансу (одразу, гра не переривається), баланс + картка (решту переказом) або вся сума переказом.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: panel
    property var cloud: Chiaki.cloud
    property bool compact: false          // у меню під час гри — без заголовка й довгих пояснень
    property int maxOptions: 3
    readonly property var info: cloud.extendInfo || ({})
    readonly property var pending: info.pending || null
    readonly property var methods: info.methods || []
    property string method: ""
    readonly property string curMethod: method !== "" ? method : (pending ? pending.method : (info.method || ""))
    readonly property bool bank: curMethod === "uah" || curMethod === "pln"
    property string status: ""
    property bool statusOk: true
    // чим закінчилась остання оплата: "" | paid | rejected | expired — щоб було видно однозначно
    property var lastPending: null
    property string verdict: ""
    property double paidEnd: 0
    readonly property Item firstOption: optRepeater.count > 0 ? optRepeater.itemAt(0) : null
    AnyPlayStyle { id: ap }
    AnyPlayWallet { id: wallet }
    property string pay: ""               // вибір клієнта: wallet | transfer; "" — з балансу, якщо там щось є
    readonly property real walletBal: wallet.balance(wallet.currencyOf(curMethod))
    readonly property string payChoice: !wallet.on || walletBal <= 0 ? "transfer" : (pay !== "" ? pay : "wallet")
    // «Баланс + картка»: скільки з балансу вже відкладено на це продовження (переказати треба лише решту)
    readonly property var walletPart: pending ? (pending.walletPart || null) : null
    function quoteFor(o) { return wallet.quote(o, priceFor(o), curMethod); }
    // що піде на сервер для цього варіанта: wallet — з балансу, mix — баланс + доплата, transfer — переказом
    function payModeFor(o) { return payChoice === "wallet" ? (quoteFor(o).ok ? "wallet" : "mix") : "transfer"; }
    onInfoChanged: {
        if (pending) {
            lastPending = pending;
            verdict = "";
        } else if (skipVerdict) {
            skipVerdict = false; lastPending = null;
        } else if (lastPending && info.active !== undefined) {
            if (info.active && info.end >= lastPending.end) { verdict = "paid"; paidEnd = info.end; status = ""; }
            else if (lastPending.status === "pending_review") { verdict = "rejected"; status = ""; }
            else verdict = "expired";
            lastPending = null;
        }
    }
    spacing: compact ? 10 : 14

    function reload() { status = ""; cloud.loadExtend(); }
    // клієнт лише подивився й передумав — звільняємо час одразу, без «час на оплату минув»
    function cancelHold() {
        if (!pending || pending.status !== "hold")
            return;
        const id = pending.id;
        lastPending = null;
        verdict = "";
        status = "";
        skipVerdict = true;
        cloud.cancelBooking(id);
    }
    property bool skipVerdict: false
    // поки оплата не підтверджена — перепитуємо сервер, щоб статус змінився сам
    Timer {
        interval: 5000; repeat: true
        running: panel.visible && !!panel.pending
        onTriggered: panel.cloud.loadExtend()
    }
    function priceFor(o) { return (o.prices && o.prices[panel.curMethod]) ? o.prices[panel.curMethod] : o.price; }
    function hoursOf(p) { return Math.round((p.end - p.start) / 3600); }
    onVisibleChanged: if (visible) reload()
    Component.onCompleted: if (visible) reload()

    Connections {
        target: panel.cloud
        function onExtendResult(ok, text) { panel.status = text; panel.statusOk = ok; }
    }

    ApText {
        visible: !panel.compact
        role: "h2"
        text: qsTr("Продовжити бронювання")
    }
    // ── стан оплати одним рядком: не оплачено / перевіряємо / оплачено / відхилено ──
    Rectangle {
        id: payState
        readonly property string kind: panel.pending ? (panel.pending.status === "pending_review" ? "review" : "hold") : panel.verdict
        readonly property color tone: kind === "paid" ? ap.ok : (kind === "review" ? ap.gold : (kind === "hold" ? ap.cyan : ap.bad))
        visible: kind !== ""
        Layout.fillWidth: true
        implicitHeight: payStateRow.implicitHeight + 22
        radius: ap.radius
        color: ap.glass
        border.width: 1
        border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.55)
        Rectangle {   // кольорова смужка зліва
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 3
            color: payState.tone
        }
        RowLayout {
            id: payStateRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 14 }
            spacing: 12
            BusyIndicator {
                visible: payState.kind === "review"
                running: visible
                Layout.preferredWidth: 26; Layout.preferredHeight: 26
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                ApText {
                    Layout.fillWidth: true
                    font.weight: Font.DemiBold
                    font.pixelSize: panel.compact ? 15 : 16
                    color: payState.tone
                    text: {
                        const p = panel.pending;
                        if (payState.kind === "review")
                            return qsTr("Оплату ще НЕ підтверджено: перевіряємо платіж %1").arg(wallet.price(p.price));
                        if (payState.kind === "hold")
                            return qsTr("Ще не оплачено: +%1 год (%2–%3), %4").arg(panel.hoursOf(p))
                                .arg(panel.cloud.formatTime(p.start)).arg(panel.cloud.formatTime(p.end)).arg(wallet.price(p.price));
                        if (payState.kind === "paid")
                            return qsTr("✓ Оплачено, гру продовжено до %1").arg(panel.cloud.formatTime(panel.paidEnd));
                        if (payState.kind === "rejected")
                            return qsTr("✕ Оплату не підтверджено, час не додано");
                        return qsTr("Час на оплату минув, продовження скасовано");
                    }
                }
                ApText {
                    Layout.fillWidth: true
                    role: "small"
                    color: ap.mute
                    text: payState.kind === "review" ? qsTr("Гра триває. Щойно платіж знайдеться, тут з'явиться «✓ Оплачено», час додасться сам, а в бот прийде повідомлення.")
                        : payState.kind === "hold" ? qsTr("Продовження ще не оформлено. Оплати точну суму й натисни «✓ Я оплатив» або скасуй, якщо передумав.")
                        : payState.kind === "paid" ? qsTr("Підтвердження також прийшло тобі в бот. Можна грати далі.")
                        : payState.kind === "rejected" ? qsTr("Ми не знайшли цей платіж. Якщо ти платив, напиши нам у Telegram: кнопка «🆘 Допомога» в боті.")
                        : qsTr("Можеш обрати час ще раз нижче.")
                }
            }
        }
    }
    ApText {
        Layout.fillWidth: true
        Layout.maximumWidth: 620
        visible: !panel.pending
        role: "lead"; rich: true
        text: {
            const i = panel.info;
            if (i.active === undefined) return qsTr("Завантажуємо…");
            if (!i.active) return qsTr("Продовжити можна лише під час своєї гри. Нову бронь можна зробити тут же: вкладка «Бронювання» на головному екрані.");
            if (i.closed) return qsTr("Зараз триває обслуговування, продовження тимчасово недоступне.");
            return (wallet.on ? qsTr("Гра зараз до <b>%1</b>. Обери, на скільки продовжити. Гра не переривається.")
                              : qsTr("Гра зараз до <b>%1</b>. Обери, на скільки продовжити. Оплата тут же, гра не переривається."))
                .arg(panel.cloud.formatTime(i.end));
        }
    }

    // ── з балансу або переказом ──
    GridLayout {
        visible: wallet.on && !!panel.info.active && !panel.info.closed && !panel.pending
        Layout.fillWidth: true
        Layout.fillHeight: false   // кнопки однакової висоти, але сітка не розтягується на висоту стовпця
        Layout.maximumWidth: 460
        columns: 2
        columnSpacing: 6
        rowSpacing: 6
        ApMethod {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            enabled: panel.walletBal > 0
            checked: panel.payChoice === "wallet"
            text: qsTr("З балансу")
            sub: panel.walletBal > 0
                ? qsTr("є %1, не вистачить — доплатиш %2").arg(wallet.money(panel.walletBal, wallet.currencyOf(panel.curMethod))).arg(wallet.viaText(panel.curMethod))
                : qsTr("баланс порожній")
            onClicked: panel.pay = "wallet"
        }
        ApMethod {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            checked: panel.payChoice === "transfer"
            text: qsTr("Переказом")
            sub: wallet.transferText(panel.curMethod)
            onClicked: panel.pay = "transfer"
        }
    }

    // ── спосіб оплати ──
    Flow {
        visible: panel.methods.length > 1 && !!panel.info.active && !panel.info.closed
                 && !(panel.pending && panel.pending.status === "pending_review")
        Layout.fillWidth: true
        spacing: 8
        Repeater {
            model: panel.methods
            ApButton {
                id: mb
                required property var modelData
                small: true
                ghost: panel.curMethod !== modelData.code
                font.family: ap.body
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                font.pixelSize: 15           // валюту оплати має бути добре видно
                font.weight: Font.Medium
                topPadding: 11; bottomPadding: 11
                leftPadding: 16; rightPadding: 16
                text: modelData.label
                onClicked: {
                    panel.method = modelData.code;
                    if (panel.pending && panel.pending.method !== modelData.code) {
                        // заявку «Баланс + картка» в іншій валюті лишаємо такою, лише якщо в цій валюті щось є на балансі
                        const mix = !!panel.walletPart && wallet.balance(wallet.currencyOf(modelData.code)) > 0;
                        panel.cloud.extend(panel.hoursOf(panel.pending), modelData.code, mix ? "mix" : "transfer");
                    }
                }
            }
        }
    }

    // ── варіанти: +1 / +2 / +3 год, до якого часу і ціна ──
    ColumnLayout {
        visible: !!panel.info.active && !panel.info.closed && !panel.pending
        Layout.fillWidth: true
        spacing: 0
        Repeater {
            id: optRepeater
            model: (panel.info.options || []).slice(0, panel.maxOptions)
            ApOpt {
                id: opt
                required property var modelData
                radio: false
                enabled: modelData.free
                text: qsTr("+%1 год, до %2").arg(modelData.hours).arg(panel.cloud.formatTime((panel.info.end || 0) + modelData.hours * 3600))
                onClicked: {
                    const how = panel.payModeFor(modelData);
                    panel.status = how === "wallet" ? qsTr("Оплачуємо з балансу…") : qsTr("Закріплюємо час…");
                    panel.statusOk = true;
                    panel.cloud.extend(modelData.hours, panel.curMethod, how);
                }
                ApChip {
                    readonly property var q: panel.quoteFor(opt.modelData)
                    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                    // ціна з урахуванням способу: «з балансу 75 ₴», «60 ₴ + 15 ₴ карткою» або просто ціна
                    text: !opt.modelData.free ? qsTr("зайнято")
                        : panel.payChoice !== "wallet" ? wallet.price(panel.priceFor(opt.modelData))
                        : q.ok ? qsTr("з балансу %1").arg(wallet.money(q.price, q.currency))
                        : qsTr("%1 + %2 %3").arg(wallet.money(q.part, q.currency)).arg(wallet.money(q.rest, q.currency)).arg(wallet.viaText(panel.curMethod))
                }
            }
        }
    }

    // ── оплата: сума, реквізити, «Я оплатив» ──
    ColumnLayout {
        visible: !!panel.pending && panel.pending.status === "hold"
        Layout.fillWidth: true
        spacing: panel.compact ? 8 : 10
        RowLayout {
            spacing: 14
            Text {
                text: panel.pending ? wallet.price(panel.pending.price) : ""
                font.family: ap.display; font.weight: Font.Medium; font.pixelSize: panel.compact ? 34 : 44; font.letterSpacing: 1
                color: ap.ink
            }
            ApButton { small: true; ghost: true; text: qsTr("Копіювати суму"); onClicked: panel.cloud.copyText(panel.pending.amount) }
        }
        ApText {   // «Баланс + картка»: це лише доплата, решту відкладено з балансу
            visible: !!panel.walletPart
            Layout.fillWidth: true
            color: ap.gold
            role: panel.compact ? "small" : "body"
            text: panel.walletPart
                ? qsTr("Це доплата. Ще %1 спишемо з балансу, щойно вона надійде.")
                    .arg(wallet.money(panel.walletPart.amount, panel.walletPart.currency || wallet.currencyOf(panel.pending.method)))
                : ""
        }
        ApButton {   // головне: відкрити оплату одразу з потрібною сумою
            visible: !!panel.pending && !!panel.pending.payUrl
            Layout.fillWidth: !panel.compact
            text: qsTr("Оплатити %1").arg(panel.pending ? wallet.price(panel.pending.price) : "")
            onClicked: Qt.openUrlExternally(panel.pending.payUrl)
        }
        ApText {
            visible: !!panel.pending && !!panel.pending.payUrl
            Layout.fillWidth: true
            role: "small"
            text: qsTr("Відкриється сторінка оплати з уже вписаною сумою: карткою, Apple Pay чи Google Pay. Або переказ за реквізитами:")
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: panel.pending ? panel.pending.requisites : []
                ApRow {
                    id: reqRow
                    required property var modelData
                    title: modelData.value
                    subtitle: modelData.label
                    ApButton {
                        small: true; ghost: true
                        text: reqRow.modelData.url ? qsTr("Відкрити") : qsTr("Копіювати")
                        onClicked: reqRow.modelData.url ? Qt.openUrlExternally(reqRow.modelData.value) : panel.cloud.copyText(reqRow.modelData.value)
                    }
                }
            }
        }
        ApField {
            id: senderField
            Layout.fillWidth: true
            visible: !panel.compact && panel.bank
            placeholderText: qsTr("Ім'я та прізвище відправника, як у банку (необов'язково)")
        }
        Flow {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 10
            ApButton {
                ghost: !!panel.pending && !!panel.pending.payUrl
                enabled: !panel.cloud.busy
                text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("✓ Я оплатив")
                onClicked: panel.cloud.payExtend(panel.pending.id, senderField.text)
            }
            ApButton {
                ghost: true
                text: panel.compact ? qsTr("Скасувати") : qsTr("Я передумав, скасувати")
                onClicked: panel.cancelHold()
            }
        }
    }

    ApText {
        Layout.fillWidth: true
        visible: panel.status !== ""
        maximumLineCount: panel.compact ? 3 : 6
        elide: Text.ElideRight
        font.weight: Font.Medium
        color: panel.statusOk ? ap.ok : ap.bad
        text: panel.status
    }
}
