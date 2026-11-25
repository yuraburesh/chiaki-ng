// AnyPlay: продовження гри й оплата прямо в програмі (з головного екрана і з меню під час гри).
// Обраний час одразу закривається для інших у боті; оплата перевіряється автоматично або адміном.
// Оплата: з балансу (одразу, гра не переривається), баланс + доплата (решту переказом) або вся сума переказом.
// 117: у стилі Vice City. Три кроки на одному екрані без прокрутки: картки «+1 / +2 / +3 год» з часом і ціною,
// картки способу оплати (баланс, картка в гривнях, BLIK у злотих, USDT — усе, що дав сервер), одна головна кнопка.
// Нічого не бронюється, поки не натиснеш головну кнопку. Клавіатура й геймпад: стрілки ходять картками.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: panel
    property var cloud: Chiaki.cloud
    property bool compact: false          // у меню під час гри — без заголовка й довгих пояснень
    property int maxOptions: 3
    property Item navLeft: null           // куди йти стрілкою ← з лівої картки (пункт меню паузи)
    readonly property var info: cloud.extendInfo || ({})
    readonly property var pending: info.pending || null
    readonly property var methods: info.methods || []
    readonly property bool canPick: !!info.active && !info.closed && !pending
    property string method: ""            // обраний спосіб переказу (uah | pln | usdt)
    property string pay: ""               // вибір клієнта: wallet | transfer; "" — з балансу, якщо там щось є
    property int hours: 0                 // обрана кількість годин (0 — перша вільна)
    property string status: ""
    property bool statusOk: true
    // чим закінчилась остання оплата: "" | paid | rejected | expired — щоб було видно однозначно
    property var lastPending: null
    property string verdict: ""
    property double paidEnd: 0
    AnyPlayStyle { id: ap }
    AnyPlayWallet { id: wallet; cloud: panel.cloud }

    // ── баланс: з якої валюти платимо (звична клієнта, інакше будь-яка, де щось є) ──
    readonly property string walletMethod: {
        if (!wallet.on) return "";
        const order = [wallet.primary, "UAH", "PLN", "USDT"];
        for (let i = 0; i < order.length; i++)
            if (wallet.balance(order[i]) > 0) return order[i].toLowerCase();
        return "";
    }
    readonly property bool canWallet: walletMethod !== ""
    readonly property string payChoice: canWallet && pay !== "transfer" ? "wallet" : "transfer"
    readonly property string transferMethod: method !== "" ? method
        : (methods.some((m) => m.code === info.method) ? info.method : (methods.length ? methods[0].code : (info.method || "")))
    readonly property string curMethod: pending ? (method !== "" ? method : pending.method)
        : (payChoice === "wallet" ? walletMethod : transferMethod)
    readonly property bool bank: curMethod === "uah" || curMethod === "pln"
    readonly property real walletBal: wallet.balance(wallet.currencyOf(curMethod))
    // «Баланс + доплата»: скільки з балансу вже відкладено на це продовження (переказати треба лише решту)
    readonly property var walletPart: pending ? (pending.walletPart || null) : null
    function quoteFor(o) { return wallet.quote(o, priceFor(o), curMethod); }
    // що піде на сервер для цього варіанта: wallet — з балансу, mix — баланс + доплата, transfer — переказом
    function payModeFor(o) { return payChoice === "wallet" ? (quoteFor(o).ok ? "wallet" : "mix") : "transfer"; }
    // доплату переказом можна лише тим способом, що зараз увімкнений на сервері
    function mixOk() { return methods.some((m) => m.code === curMethod); }

    readonly property var options: (info.options || []).slice(0, maxOptions)
    readonly property var picked: {
        let first = null;
        for (let i = 0; i < options.length; i++) {
            if (!options[i].free) continue;
            if (options[i].hours === hours) return options[i];
            if (!first) first = options[i];
        }
        return first;
    }
    readonly property Item firstOption: hourRep.count > 0 && canPick ? (hourRep.itemAt(Math.max(0, options.indexOf(picked))) || hourRep.itemAt(0))
                                      : (methodRep.count > 0 && methodRow.visible ? methodRep.itemAt(0) : null)

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
    spacing: compact ? 12 : 14

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
    function go() {
        const o = picked;
        if (!o) return;
        const how = payModeFor(o);
        status = how === "wallet" ? qsTr("Оплачуємо з балансу…") : qsTr("Закріплюємо час…");
        statusOk = true;
        cloud.extend(o.hours, curMethod, how);
    }
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

    // назва й підпис способу оплати: коротко, без прапорців з назви сервера
    function methodTitle(code, label) {
        return code === "uah" ? qsTr("Картка, гривні") : code === "pln" ? qsTr("BLIK, злоті") : code === "usdt" ? qsTr("USDT")
             : String(label || code).replace(/^[^A-Za-zА-Яа-яІіЇїЄєҐґ0-9]+/, "");
    }
    function methodSub(code) {
        return code === "uah" ? qsTr("Apple Pay, Google Pay") : code === "pln" ? qsTr("BLIK або переказ")
             : code === "usdt" ? qsTr("TRC20 або Binance Pay") : "";
    }

    // ── заголовок: до котрої гра і що на балансі ──
    RowLayout {
        Layout.fillWidth: true
        spacing: 14
        ApText {
            visible: !panel.compact
            role: "h2"
            text: qsTr("Продовжити бронювання")
        }
        ApText {
            visible: panel.compact
            role: "cap"
            text: qsTr("Продовжити бронювання")
        }
        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
        ApChip {
            visible: wallet.on && !panel.pending
            text: qsTr("На балансі %1").arg(wallet.money(wallet.primaryAmount, wallet.primary))
                + wallet.others.map((b) => ", " + wallet.money(b.amount, b.currency)).join("")
        }
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
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 8; bottomMargin: 8 }
            width: 3; radius: 1.5
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
                        : payState.kind === "hold" ? qsTr("Час закріплено за тобою. Оплати точну суму й натисни «✓ Я оплатив» або скасуй, якщо передумав.")
                        : payState.kind === "paid" ? qsTr("Підтвердження також прийшло тобі в бот. Можна грати далі.")
                        : payState.kind === "rejected" ? qsTr("Ми не знайшли цей платіж. Якщо ти платив, напиши нам у Telegram: кнопка «🆘 Допомога» в боті.")
                        : qsTr("Можеш обрати час ще раз нижче.")
                }
            }
        }
    }
    ApText {
        Layout.fillWidth: true
        visible: !panel.pending
        role: "lead"; rich: true
        text: {
            const i = panel.info;
            if (i.active === undefined) return qsTr("Завантажуємо…");
            if (!i.active) return qsTr("Продовжити можна лише під час своєї гри. Нову бронь можна зробити тут же: вкладка «Бронювання» на головному екрані.");
            if (i.closed) return qsTr("Зараз триває обслуговування, продовження тимчасово недоступне.");
            return qsTr("Гра зараз до <b>%1</b>. Обери час і спосіб оплати: гра не переривається.").arg(panel.cloud.formatTime(i.end));
        }
    }

    // ── крок 1: скільки додати (картки з часом і ціною) ──
    ApText { visible: panel.canPick && hourRep.count > 0; role: "cap"; text: qsTr("Скільки додати") }
    RowLayout {
        id: hourRow
        visible: panel.canPick && hourRep.count > 0
        Layout.fillWidth: true
        spacing: 12
        Repeater {
            id: hourRep
            model: panel.options
            HourCard {
                required property var modelData
                required property int index
                opt: modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                KeyNavigation.left: index > 0 ? hourRep.itemAt(index - 1) : panel.navLeft
                KeyNavigation.right: hourRep.itemAt(index + 1)
                KeyNavigation.down: methodRow.visible ? methodRep.itemAt(Math.max(0, panel.methodIndex())) : goBtn
            }
        }
    }

    // ── крок 2: чим платити (баланс і способи переказу, що дав сервер: гривні, злоті, USDT) ──
    readonly property var methodCards: (canPick && canWallet ? [{ code: "wallet" }] : [])
        .concat((canPick || (pending && pending.status === "hold")) ? methods : [])
    function methodIndex() {
        for (let i = 0; i < methodCards.length; i++) {
            const c = methodCards[i];
            if (c.code === "wallet" ? (!pending && payChoice === "wallet") : ((pending || payChoice === "transfer") && c.code === curMethod)) return i;
        }
        return 0;
    }
    ApText { visible: methodRow.visible; role: "cap"; text: panel.pending ? qsTr("Валюта оплати") : qsTr("Чим платити") }
    RowLayout {
        id: methodRow
        visible: panel.methodCards.length > 1 || (panel.canPick && panel.methodCards.length > 0)
        Layout.fillWidth: true
        spacing: 10
        Repeater {
            id: methodRep
            model: panel.methodCards
            ApMethod {
                required property var modelData
                required property int index
                readonly property bool isWallet: modelData.code === "wallet"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                focusPolicy: Qt.StrongFocus
                big: true
                checked: index === panel.methodIndex()
                text: isWallet ? qsTr("З балансу") : panel.methodTitle(modelData.code, modelData.label)
                sub: {
                    if (!isWallet) return panel.methodSub(modelData.code);
                    const cur = wallet.currencyOf(panel.walletMethod), q = panel.picked ? wallet.quote(panel.picked, panel.picked.prices && panel.picked.prices[panel.walletMethod] ? panel.picked.prices[panel.walletMethod] : panel.picked.price, panel.walletMethod) : null;
                    return q && !q.ok && q.price > 0 ? qsTr("є %1, решту доплатиш").arg(wallet.money(wallet.balance(cur), cur))
                                                      : qsTr("є %1, без переказу").arg(wallet.money(wallet.balance(cur), cur));
                }
                KeyNavigation.left: index > 0 ? methodRep.itemAt(index - 1) : panel.navLeft
                KeyNavigation.right: methodRep.itemAt(index + 1)
                KeyNavigation.up: hourRow.visible ? hourRep.itemAt(Math.max(0, panel.options.indexOf(panel.picked))) : null
                KeyNavigation.down: goBtn.visible ? goBtn : (payNow.visible ? payNow : paidBtn)
                onClicked: {
                    if (isWallet) { panel.pay = "wallet"; return; }
                    panel.pay = "transfer";
                    panel.method = modelData.code;
                    if (panel.pending && panel.pending.method !== modelData.code) {
                        // заявку «Баланс + доплата» в іншій валюті лишаємо такою, лише якщо в цій валюті щось є на балансі
                        const mix = !!panel.walletPart && wallet.balance(wallet.currencyOf(modelData.code)) > 0;
                        panel.cloud.extend(panel.hoursOf(panel.pending), modelData.code, mix ? "mix" : "transfer");
                    }
                }
            }
        }
    }

    // ── крок 3: головна кнопка ──
    RowLayout {
        visible: panel.canPick && !!panel.picked
        Layout.fillWidth: true
        Layout.topMargin: 4
        spacing: 16
        ApButton {
            id: goBtn
            focusPolicy: Qt.StrongFocus
            readonly property var q: panel.picked ? panel.quoteFor(panel.picked) : null
            readonly property string how: panel.picked ? panel.payModeFor(panel.picked) : "transfer"
            enabled: !panel.cloud.busy && !!panel.picked && (how !== "mix" || panel.mixOk())
            text: !panel.picked ? ""
                : how === "wallet" ? qsTr("Продовжити на %1 год з балансу").arg(panel.picked.hours)
                : how === "mix" ? qsTr("Продовжити на %1 год, доплата %2").arg(panel.picked.hours).arg(wallet.money(q.rest, q.currency))
                : qsTr("Продовжити на %1 год за %2").arg(panel.picked.hours).arg(wallet.price(panel.priceFor(panel.picked)))
            onClicked: panel.go()
            KeyNavigation.up: methodRow.visible ? methodRep.itemAt(Math.max(0, panel.methodIndex())) : hourRep.itemAt(0)
            KeyNavigation.left: panel.navLeft
        }
        ApText {
            Layout.fillWidth: true
            role: "small"
            color: ap.mute
            text: !panel.picked ? ""
                : goBtn.how === "wallet" ? qsTr("Спишемо %1 з балансу, гра продовжиться одразу.").arg(wallet.money(goBtn.q.price, goBtn.q.currency))
                : goBtn.how === "mix" && !panel.mixOk() ? qsTr("На балансі не вистачає, а доплата в цій валюті зараз вимкнена. Обери інший спосіб.")
                : goBtn.how === "mix" ? qsTr("%1 з балансу, решту оплатиш переказом на наступному кроці.").arg(wallet.money(goBtn.q.part, goBtn.q.currency))
                : qsTr("Час одразу закріпиться за тобою, далі оплата: %1.").arg(panel.methodSub(panel.curMethod) || panel.methodTitle(panel.curMethod, ""))
        }
    }

    // ── оплата: сума, реквізити, «Я оплатив» ──
    ColumnLayout {
        visible: !!panel.pending && panel.pending.status === "hold"
        Layout.fillWidth: true
        spacing: panel.compact ? 8 : 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Text {
                text: panel.pending ? wallet.price(panel.pending.price) : ""
                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: panel.compact ? 36 : 44; font.letterSpacing: 1
                color: ap.gold
            }
            ApButton { small: true; ghost: true; text: qsTr("Копіювати суму"); onClicked: panel.cloud.copyText(panel.pending.amount) }
            ApText {   // «Баланс + доплата»: це лише доплата, решту відкладено з балансу
                visible: !!panel.walletPart
                Layout.fillWidth: true
                color: ap.gold
                role: "small"
                text: panel.walletPart
                    ? qsTr("Це доплата. Ще %1 спишемо з балансу, щойно вона надійде.")
                        .arg(wallet.money(panel.walletPart.amount, panel.walletPart.currency || wallet.currencyOf(panel.pending.method)))
                    : ""
            }
        }
        Flow {
            Layout.fillWidth: true
            spacing: 10
            ApButton {   // головне: відкрити оплату одразу з потрібною сумою
                id: payNow
                visible: !!panel.pending && !!panel.pending.payUrl
                focusPolicy: Qt.StrongFocus
                text: qsTr("Оплатити %1").arg(panel.pending ? wallet.price(panel.pending.price) : "")
                onClicked: Qt.openUrlExternally(panel.pending.payUrl)
                KeyNavigation.right: paidBtn
                KeyNavigation.left: panel.navLeft
                KeyNavigation.up: methodRow.visible ? methodRep.itemAt(Math.max(0, panel.methodIndex())) : null
            }
            ApButton {
                id: paidBtn
                focusPolicy: Qt.StrongFocus
                ghost: !!panel.pending && !!panel.pending.payUrl
                height: payNow.visible ? payNow.height : implicitHeight
                enabled: !panel.cloud.busy
                text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("✓ Я оплатив")
                onClicked: panel.cloud.payExtend(panel.pending.id, senderField.text)
                KeyNavigation.left: payNow.visible ? payNow : panel.navLeft
                KeyNavigation.right: cancelBtn
                KeyNavigation.up: methodRow.visible ? methodRep.itemAt(Math.max(0, panel.methodIndex())) : null
            }
            ApButton {
                id: cancelBtn
                focusPolicy: Qt.StrongFocus
                ghost: true
                height: paidBtn.height
                text: panel.compact ? qsTr("Скасувати") : qsTr("Я передумав, скасувати")
                onClicked: panel.cancelHold()
                KeyNavigation.left: paidBtn
                KeyNavigation.up: methodRow.visible ? methodRep.itemAt(Math.max(0, panel.methodIndex())) : null
            }
        }
        ApText {
            Layout.fillWidth: true
            role: "small"
            text: panel.pending && panel.pending.payUrl
                ? qsTr("Сторінка оплати відкриється з уже вписаною сумою. Або переказ за реквізитами:")
                : qsTr("Реквізити для переказу:")
        }
        GridLayout {   // реквізити: на широкому у два стовпці, щоб усе влізло без прокрутки
            Layout.fillWidth: true
            columns: panel.width >= 640 && reqRep.count > 1 && (panel.pending ? panel.pending.requisites || [] : []).every((r) => String(r.value).length <= 26) ? 2 : 1
            columnSpacing: 18
            rowSpacing: 0
            Repeater {
                id: reqRep
                model: panel.pending ? panel.pending.requisites : []
                ApRow {
                    id: reqRow
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
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

    // картка «+N год»: великий час, до котрої, ціна у валюті оплати і що з балансу. Обрана — рамка й смужка заходу сонця
    component HourCard: AbstractButton {
        id: hc
        property var opt: ({})
        readonly property bool sel: !!panel.picked && panel.picked.hours === opt.hours
        readonly property var q: opt && opt.free ? panel.quoteFor(opt) : null
        enabled: !!opt.free
        hoverEnabled: true
        focusPolicy: Qt.StrongFocus
        implicitHeight: hcCol.implicitHeight + (panel.compact ? 26 : 30)
        opacity: enabled ? 1 : 0.45
        onClicked: panel.hours = opt.hours
        Keys.onReturnPressed: { panel.hours = opt.hours; goBtn.forceActiveFocus(Qt.TabFocusReason); }
        Keys.onEnterPressed: { panel.hours = opt.hours; goBtn.forceActiveFocus(Qt.TabFocusReason); }
        Keys.onSpacePressed: panel.hours = opt.hours
        onActiveFocusChanged: if (activeFocus && enabled) panel.hours = opt.hours   // стрілками: обирає одразу
        transform: Translate { y: hc.down ? 1 : (hc.hovered && hc.enabled && !hc.sel ? -ap.lift : 0); Behavior on y { NumberAnimation { duration: ap.tHover; easing.type: Easing.OutCubic } } }
        scale: hc.down ? ap.pressScale : 1
        Behavior on scale { NumberAnimation { duration: ap.tPress } }
        background: Item {
            Rectangle {   // тінь
                anchors { fill: parent; topMargin: 4; bottomMargin: -4; leftMargin: 2; rightMargin: 2 }
                radius: ap.cardRadius
                color: hc.sel ? "#55a01c4a" : ap.shadow
                opacity: hc.sel || hc.hovered ? 0.8 : 0.45
                Behavior on opacity { NumberAnimation { duration: ap.tHover } }
            }
            Rectangle {   // скло
                anchors.fill: parent
                radius: ap.cardRadius
                color: hc.sel ? "#2affffff" : (hc.hovered && hc.enabled ? ap.glassHi : ap.glass)
                border.width: hc.sel ? 2 : 1
                border.color: hc.sel ? ap.accent : (hc.hovered && hc.enabled ? ap.edgeHi : ap.edge)
                Rectangle { x: 8; y: 1; width: parent.width - 16; height: 1; color: ap.cardTop }
            }
            Rectangle {   // обрана: смужка заходу сонця вгорі
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 14; topMargin: 2 }
                height: 3; radius: 1.5
                opacity: hc.sel ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: ap.tPage } }
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
            Rectangle {   // фокус з клавіатури чи геймпада
                anchors { fill: parent; margins: -3 }
                radius: ap.cardRadius + 3
                visible: hc.visualFocus
                color: "transparent"
                border.width: 2; border.color: ap.cyan
            }
        }
        contentItem: Item {
            implicitHeight: hcCol.implicitHeight
            Column {
                id: hcCol
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 14 }
                spacing: 2
                Text {
                    text: qsTr("+%1 год").arg(hc.opt.hours)
                    font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: panel.compact ? 28 : 32; font.letterSpacing: 1.4
                    font.capitalization: Font.AllUppercase
                    color: ap.ink
                }
                Text {
                    text: qsTr("до %1").arg(panel.cloud.formatTime((panel.info.end || 0) + hc.opt.hours * 3600))
                    font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 14
                    color: ap.mute
                }
                Item { width: 1; height: 6 }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: !hc.opt.free ? qsTr("зайнято") : wallet.price(panel.priceFor(hc.opt))
                    font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: hc.opt.free ? 19 : 15
                    color: hc.opt.free ? ap.gold : ap.faint
                }
                Text {
                    visible: !!hc.q && panel.payChoice === "wallet"
                    width: parent.width
                    elide: Text.ElideRight
                    text: !hc.q ? "" : hc.q.ok ? qsTr("з балансу")
                        : qsTr("%1 з балансу + %2").arg(wallet.money(hc.q.part, hc.q.currency)).arg(wallet.money(hc.q.rest, hc.q.currency))
                    font.family: ap.body; font.pixelSize: 13
                    color: hc.q && hc.q.ok ? ap.ok : ap.faint
                }
            }
        }
    }
}
