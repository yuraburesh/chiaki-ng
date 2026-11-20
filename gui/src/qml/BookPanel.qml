// AnyPlay: бронювання й оплата прямо в програмі — день, скільки грати, початок, оплата (чотири стовпці). Без Telegram.
// Оплата: з балансу (одразу), баланс + картка (решту переказом) або вся сума переказом — клієнт обирає щоразу сам.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: panel
    property var cloud: Chiaki.cloud
    readonly property var info: cloud.bookInfo || ({})
    readonly property var days: info.days || []
    readonly property var tariffs: info.tariffs || []
    readonly property var methods: info.methods || []
    readonly property var mine: info.mine || []
    // бронь, яку зараз треба оплатити (перша неоплачена)
    readonly property var payItem: {
        for (let i = 0; i < mine.length; i++)
            if (mine[i].pending && mine[i].status === "hold")
                return mine[i];
        return null;
    }
    property int dayIndex: 0
    property string code: ""
    property string method: ""
    property double start: 0
    property string wantTime: ""           // час початку, який клієнт обрав раніше: на іншому дні чи тарифі беремо найближчий після нього
    property bool choosing: false          // true — показуємо вибір часу, навіть якщо є неоплачена бронь
    property string status: ""
    property bool statusOk: true
    property double confirmId: 0           // бронь, для якої зараз питаємо «точно скасувати?»
    readonly property string curMethod: method !== "" ? method : (methods.length ? methods[0].code : "")
    readonly property var tariff: {
        for (let i = 0; i < tariffs.length; i++)
            if (tariffs[i].code === code)
                return tariffs[i];
        return null;
    }
    readonly property bool showPay: !!payItem && !choosing
    // «Баланс + картка»: скільки з балансу вже відкладено на цю бронь (переказати треба лише решту)
    readonly property var payWalletPart: payItem ? (payItem.pending.walletPart || payItem.walletPart || null) : null
    signal walletRequested()               // «поповни баланс»: відкрити вкладку «Баланс»
    AnyPlayWallet { id: wallet }
    property string pay: ""                // вибір клієнта: wallet (з балансу чи баланс + картка) | transfer; "" — з балансу, якщо там щось є
    readonly property var quote: wallet.quote(tariff, tariff ? (tariff.prices[curMethod] || "") : "", curMethod)
    readonly property string payChoice: !wallet.on || quote.balance <= 0 ? "transfer" : (pay !== "" ? pay : "wallet")
    // що піде на сервер: wallet — уся сума з балансу, mix — баланс + доплата переказом, transfer — уся сума переказом
    readonly property string payMode: payChoice === "wallet" ? (quote.ok ? "wallet" : "mix") : "transfer"
    function money(x) { return wallet.money(x, quote.currency); }
    function price(text) { return wallet.price(text); }   // «250.00 грн» від сервера → «250 ₴», як суми балансу
    // стовпці: 4 на широкому вікні, 2 на середньому, 1 на вузькому
    readonly property int cols: width >= 960 ? 4 : (width >= 540 ? 2 : 1)
    readonly property real colGap: width >= 1100 ? 36 : 24
    readonly property real colW: Math.floor((width - (cols - 1) * colGap) / cols)
    spacing: 20
    AnyPlayStyle { id: ap }

    function reload() { status = ""; cloud.loadBook(); }
    function loadStarts() {
        start = 0;
        // дні беремо прямо з відповіді сервера: тарифи й дні приходять разом, а обробник зміни тарифу
        // спрацьовує раніше, ніж оновиться days (інакше на першому відкритті вільний час не з'являвся)
        const d = (cloud.bookInfo && cloud.bookInfo.days) || days;
        if (d.length > dayIndex && code !== "")
            cloud.loadBookStarts(d[dayIndex].date, code);
    }
    function pad2(n) { return String(n).padStart(2, "0"); }
    function dayLabel(i) {
        if (i === 0) return qsTr("Сьогодні");
        if (i === 1) return qsTr("Завтра");
        const d = new Date((days[i].start + 12 * 3600) * 1000);
        return [qsTr("Нд"), qsTr("Пн"), qsTr("Вт"), qsTr("Ср"), qsTr("Чт"), qsTr("Пт"), qsTr("Сб")][d.getDay()] + ", " + d.getDate() + "." + pad2(d.getMonth() + 1);
    }
    function hhmm(ts) {
        const d = new Date(ts * 1000);
        return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
    }
    // «Сьогодні, 19:00–22:00» / «Сб, 21.11, 18:00–20:00»; кінець наступного дня — з назвою дня
    function rangeText(a, b) {
        const da = new Date(a * 1000), db = new Date(b * 1000 - 1000), now = new Date();
        const same = (x, y) => x.toDateString() === y.toDateString();
        const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
        const name = (d) => same(d, now) ? qsTr("Сьогодні") : same(d, tomorrow) ? qsTr("Завтра")
            : [qsTr("Нд"), qsTr("Пн"), qsTr("Вт"), qsTr("Ср"), qsTr("Чт"), qsTr("Пт"), qsTr("Сб")][d.getDay()] + ", " + d.getDate() + "." + pad2(d.getMonth() + 1);
        return name(da) + ", " + hhmm(a) + "–" + (same(da, db) ? "" : name(db).toLowerCase() + " ") + hhmm(b);
    }
    function statusChip(m) {
        const now = Math.floor(Date.now() / 1000) + cloud.clockSkew;
        if (m.status === "hold") return { text: qsTr("чекає оплату"), kind: "wait" };
        if (m.status === "pending_review") return { text: qsTr("перевіряємо оплату"), kind: "wait" };
        if (m.status === "active" || (m.start <= now && now < m.end)) return { text: qsTr("йде гра"), kind: "live" };
        return { text: (m.pay || m.payMode) === "wallet" ? qsTr("оплачено з балансу") : qsTr("оплачено"), kind: "ok" };
    }

    onVisibleChanged: if (visible) { choosing = false; confirmId = 0; reload(); }
    Component.onCompleted: if (visible) reload()
    onDayIndexChanged: loadStarts()
    onCodeChanged: loadStarts()
    onTariffsChanged: if (code === "" && tariffs.length) code = tariffs[0].code

    Connections {
        target: panel.cloud
        function onBookResult(ok, text) {
            panel.status = text; panel.statusOk = ok;
            panel.confirmId = 0;
            if (ok) panel.choosing = false;
            panel.loadStarts();
        }
        // нові вільні старти: фіксований початок обираємо сам, інакше найближчий до обраного раніше часу
        function onBookStartsChanged() {
            const s = panel.cloud.bookStarts;
            if (panel.cloud.bookStartsLoading || !s.length || panel.start > 0)
                return;
            if (panel.tariff && panel.tariff.fixed) { panel.start = s[0]; return; }
            if (panel.wantTime === "")
                return;
            for (let i = 0; i < s.length; i++)
                if (panel.hhmm(s[i]) >= panel.wantTime) { panel.start = s[i]; return; }
        }
    }

    // ── заголовок ──
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        ApText { role: "h2"; text: qsTr("Бронювання") }
        ApText {
            Layout.fillWidth: true
            Layout.maximumWidth: 640
            role: "hint"
            text: panel.showPay ? qsTr("Час закріплено за тобою. Лишилось оплатити.")
                                : qsTr("Обери день, скільки грати і початок. Час закріплюється за тобою одразу, оплата тут же.")
        }
        ApText {
            Layout.fillWidth: true
            visible: panel.mine.length > 0 && !panel.showPay
            role: "small"
            text: qsTr("Твої броні (%1) і їх скасування: внизу сторінки.").arg(panel.mine.length)
        }
        ApText {
            Layout.fillWidth: true
            visible: !!panel.info.closed
            color: ap.gold
            text: qsTr("Зараз технічні роботи, бронювання тимчасово недоступне.")
        }
    }

    // ───────── оплата закріпленого часу ─────────
    GridLayout {
        Layout.fillWidth: true
        visible: panel.showPay
        columns: panel.width >= 760 ? 2 : 1
        columnSpacing: 48
        rowSpacing: 20
        ColumnLayout {
            Layout.preferredWidth: panel.width >= 760 ? (panel.width - 48) / 2 : panel.width
            Layout.alignment: Qt.AlignTop
            spacing: 10
            ApText { role: "cap"; text: qsTr("Оплата") }
            ApText {
                Layout.fillWidth: true
                font.weight: Font.Medium
                font.pixelSize: 16
                text: panel.payItem ? qsTr("%1, %2").arg(panel.rangeText(panel.payItem.start, panel.payItem.end)).arg(panel.payItem.title) : ""
            }
            RowLayout {
                spacing: 14
                Text {
                    text: panel.payItem ? wallet.price(panel.payItem.pending.price) : ""
                    font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 44; font.letterSpacing: 1
                    color: ap.ink
                }
                ApButton { small: true; ghost: true; text: qsTr("Копіювати суму"); onClicked: panel.cloud.copyText(panel.payItem.pending.amount) }
            }
            ApText {
                Layout.fillWidth: true
                role: "hint"
                text: qsTr("Переказуй точну суму до копійки: так оплата знайдеться автоматично.")
            }
            ApText {   // «Баланс + картка»: це лише доплата, решту відкладено з балансу
                visible: !!panel.payWalletPart
                Layout.fillWidth: true
                color: ap.gold
                text: panel.payWalletPart
                    ? qsTr("Це доплата. Ще %1 спишемо з балансу, щойно вона надійде, і бронь підтвердиться.")
                        .arg(wallet.money(panel.payWalletPart.amount, panel.payWalletPart.currency || wallet.currencyOf(panel.payItem.pending.method)))
                    : ""
            }
            ApButton {
                visible: !!panel.payItem && !!panel.payItem.pending.payUrl
                Layout.fillWidth: true
                Layout.topMargin: 4
                text: qsTr("Оплатити %1").arg(panel.payItem ? wallet.price(panel.payItem.pending.price) : "")
                onClicked: Qt.openUrlExternally(panel.payItem.pending.payUrl)
            }
            ApText {
                visible: !!panel.payItem && !!panel.payItem.pending.payUrl
                Layout.fillWidth: true
                role: "small"
                text: qsTr("Відкриється сторінка оплати з уже вписаною сумою: карткою, Apple Pay чи Google Pay.")
            }
        }
        ColumnLayout {
            Layout.preferredWidth: panel.width >= 760 ? (panel.width - 48) / 2 : panel.width
            Layout.alignment: Qt.AlignTop
            spacing: 0
            ApText {
                visible: !!panel.payItem && panel.payItem.pending.requisites && panel.payItem.pending.requisites.length > 0
                role: "cap"
                Layout.bottomMargin: 6
                text: panel.payItem && panel.payItem.pending.payUrl ? qsTr("Або переказ за реквізитами") : qsTr("Реквізити")
            }
            Repeater {
                model: panel.payItem ? panel.payItem.pending.requisites : []
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
            ApField {
                id: senderField
                Layout.fillWidth: true
                Layout.topMargin: 14
                visible: !!panel.payItem && (panel.payItem.pending.method === "uah" || panel.payItem.pending.method === "pln")
                placeholderText: qsTr("Ім'я та прізвище відправника, як у банку (необов'язково)")
            }
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 14
                spacing: 10
                ApButton {
                    ghost: !!panel.payItem && !!panel.payItem.pending.payUrl
                    enabled: !panel.cloud.busy
                    text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("✓ Я оплатив")
                    onClicked: panel.cloud.payBooking(panel.payItem.id, senderField.text)
                }
                ApButton {
                    ghost: true
                    text: qsTr("Скасувати бронь")
                    onClicked: panel.cloud.cancelBooking(panel.payItem.id)
                }
            }
        }
    }

    // ───────── вибір часу: 1. День, 2. Скільки грати, 3. Початок, 4. Оплата ─────────
    GridLayout {
        Layout.fillWidth: true
        visible: !panel.showPay && !panel.info.closed
        columns: panel.cols
        columnSpacing: panel.colGap
        rowSpacing: 28

        // 1. День
        ColumnLayout {
            Layout.preferredWidth: panel.colW
            Layout.maximumWidth: panel.colW
            Layout.alignment: Qt.AlignTop
            spacing: 0
            ApText { role: "cap"; text: qsTr("1. День"); Layout.bottomMargin: 6 }
            Repeater {
                model: panel.days.length
                ApOpt {
                    required property int index
                    text: panel.dayLabel(index)
                    checked: panel.dayIndex === index
                    onClicked: panel.dayIndex = index
                }
            }
        }

        // 2. Скільки грати
        ColumnLayout {
            Layout.preferredWidth: panel.colW
            Layout.maximumWidth: panel.colW
            Layout.alignment: Qt.AlignTop
            spacing: 0
            ApText { role: "cap"; text: qsTr("2. Скільки грати"); Layout.bottomMargin: 6 }
            Repeater {
                model: panel.tariffs
                ApOpt {
                    id: tOpt
                    required property var modelData
                    text: modelData.title
                    radio: false
                    checked: panel.code === modelData.code
                    onClicked: panel.code = modelData.code
                    ApChip {
                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                        text: panel.price(tOpt.modelData.prices[panel.curMethod] || "")
                    }
                }
            }
        }

        // 3. Початок
        ColumnLayout {
            Layout.preferredWidth: panel.colW
            Layout.maximumWidth: panel.colW
            Layout.alignment: Qt.AlignTop
            spacing: 0
            ApText { role: "cap"; text: qsTr("3. Початок"); Layout.bottomMargin: 6 }
            ApText {
                Layout.fillWidth: true
                Layout.topMargin: 6
                visible: panel.cloud.bookStartsLoading || panel.cloud.bookStarts.length === 0
                role: "hint"
                text: panel.cloud.bookStartsLoading ? qsTr("Шукаємо вільний час…")
                    : qsTr("На цей день для такої тривалості вільного часу немає: обери інший день або менше годин.")
            }
            // приставка вільна просто зараз: найближчий початок окремою помітною кнопкою
            TimeButton {
                id: nowBtn
                readonly property var first: panel.cloud.bookStarts.length ? panel.cloud.bookStarts[0] : 0
                readonly property bool soon: first > 0 && first - Date.now() / 1000 < 900 && !(panel.tariff && panel.tariff.fixed)
                visible: !panel.cloud.bookStartsLoading && soon
                Layout.fillWidth: true
                Layout.bottomMargin: 6
                accent: true
                verticalPadding: 11
                text: panel.tariff ? qsTr("Грати зараз: %1–%2").arg(panel.hhmm(first)).arg(panel.hhmm(first + panel.tariff.hours * 3600))
                                   : qsTr("Грати зараз: %1").arg(panel.hhmm(first))
                checked: panel.start === first
                onClicked: { panel.start = first; panel.wantTime = panel.hhmm(first); }
            }
            GridLayout {
                id: times
                Layout.fillWidth: true
                visible: !panel.cloud.bookStartsLoading && panel.cloud.bookStarts.length > 0
                columns: panel.tariff && panel.tariff.fixed ? 1 : (panel.colW >= 240 ? 4 : 3)
                columnSpacing: 5
                rowSpacing: 5
                Repeater {
                    model: panel.cloud.bookStarts
                    TimeButton {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        text: panel.tariff && panel.tariff.fixed ? qsTr("%1, фіксований початок").arg(panel.hhmm(modelData)) : panel.hhmm(modelData)
                        checked: panel.start === modelData
                        onClicked: { panel.start = modelData; panel.wantTime = panel.hhmm(modelData); }
                    }
                }
            }
            ApText {
                Layout.fillWidth: true
                Layout.topMargin: 8
                visible: panel.cloud.bookStarts.length > 0
                role: "small"
                text: qsTr("Час за годинником твого комп'ютера. Показано лише вільні початки.")
            }
        }

        // 4. Оплата
        ColumnLayout {
            Layout.preferredWidth: panel.colW
            Layout.maximumWidth: panel.colW
            Layout.alignment: Qt.AlignTop
            spacing: 12
            ApText { role: "cap"; text: qsTr("4. Оплата") }
            ColumnLayout {
                spacing: 2
                Text {
                    text: panel.tariff ? wallet.price(panel.tariff.prices[panel.curMethod] || "") : ""
                    font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 44; font.letterSpacing: 1
                    color: ap.ink
                }
                // коли гратимеш: великими цифрами, щоб одразу було видно, з якої по яку
                Text {
                    visible: panel.start > 0 && !!panel.tariff
                    Layout.topMargin: 6
                    text: visible ? panel.hhmm(panel.start) + "–" + panel.hhmm(panel.start + panel.tariff.hours * 3600) : ""
                    font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 30; font.letterSpacing: 1
                    color: ap.gold
                }
                ApText {
                    Layout.preferredWidth: panel.colW
                    role: panel.start > 0 && panel.tariff ? "lead" : "small"
                    color: panel.start > 0 && panel.tariff ? ap.ink : ap.faint
                    text: panel.start > 0 && panel.tariff
                        ? qsTr("Гратимеш: %1").arg(panel.rangeText(panel.start, panel.start + panel.tariff.hours * 3600) + ", " + String(panel.tariff.title).split(",")[0].toLowerCase())
                        : qsTr("Обери час початку")
                }
            }
            Flow {   // спосіб оплати, якщо їх кілька
                visible: panel.methods.length > 1
                Layout.fillWidth: true
                spacing: 5
                Repeater {
                    model: panel.methods
                    TimeButton {
                        required property var modelData
                        text: modelData.label
                        checked: panel.curMethod === modelData.code
                        horizontalPadding: 14
                        verticalPadding: 10
                        onClicked: panel.method = modelData.code
                    }
                }
            }
            GridLayout {   // з балансу (чи баланс + картка) або переказом
                visible: wallet.on
                Layout.fillWidth: true
                Layout.fillHeight: false   // кнопки однакової висоти, але сітка не розтягується на висоту стовпця
                columns: 2
                columnSpacing: 6
                rowSpacing: 6
                ApMethod {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 1
                    enabled: panel.quote.balance > 0
                    checked: panel.payChoice === "wallet"
                    text: panel.quote.ok || panel.quote.balance <= 0 ? qsTr("З балансу") : qsTr("Баланс + картка")
                    sub: panel.quote.balance <= 0 ? qsTr("баланс порожній")
                        : panel.quote.ok ? qsTr("є %1, спишеться одразу").arg(panel.money(panel.quote.balance))
                        : qsTr("%1 з балансу, %2 %3").arg(panel.money(panel.quote.part)).arg(panel.money(panel.quote.rest)).arg(wallet.viaText(panel.curMethod))
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
            ApText {   // на балансі не вистачає: решту доплатить, або спершу поповнить
                visible: wallet.on && panel.payMode === "mix"
                Layout.preferredWidth: panel.colW
                rich: true
                color: ap.gold
                font.pixelSize: 13
                text: qsTr("На балансі %1, не вистачає %2: їх доплатиш %3. Або <a href=\"wallet\">поповни баланс</a>.")
                    .arg(panel.money(panel.quote.balance)).arg(panel.money(panel.quote.rest)).arg(wallet.viaText(panel.curMethod))
                onLinkActivated: panel.walletRequested()
                HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }
            ApButton {
                Layout.fillWidth: true
                font.pixelSize: 15
                font.letterSpacing: 1.6
                leftPadding: 14; rightPadding: 14
                enabled: panel.start > 0 && !!panel.tariff && !panel.cloud.busy
                text: !(panel.start > 0 && panel.tariff) ? qsTr("Обери час початку")
                    : panel.payMode === "wallet" ? qsTr("Оплатити з балансу %1").arg(panel.money(panel.quote.price))
                    : panel.payMode === "mix" ? qsTr("Доплатити %1 %2").arg(panel.money(panel.quote.rest)).arg(wallet.viaText(panel.curMethod))
                    : qsTr("Забронювати %1–%2").arg(panel.hhmm(panel.start)).arg(panel.hhmm(panel.start + panel.tariff.hours * 3600))
                onClicked: panel.cloud.book(panel.start, panel.code, panel.curMethod, panel.payMode)
            }
            ApText {
                Layout.preferredWidth: panel.colW
                role: "small"
                text: panel.payMode === "wallet" ? qsTr("Бронь підтвердиться одразу, без переказу. Залишиться %1.").arg(panel.money(panel.quote.after))
                    : panel.payMode === "mix" ? qsTr("Час закріплено за тобою. Як тільки надійде доплата %1, спишемо %2 з балансу, і бронь підтвердиться.")
                        .arg(panel.money(panel.quote.rest)).arg(panel.money(panel.quote.part))
                    : wallet.on ? qsTr("Відкриється сторінка оплати з уже вписаною сумою: карткою, Apple Pay чи Google Pay.")
                    : qsTr("Після бронювання відкриється оплата з уже вписаною сумою: карткою, Apple Pay чи Google Pay.")
            }
            ApButton {
                visible: !!panel.payItem
                ghost: true; small: true
                text: qsTr("← Назад до оплати")
                onClicked: panel.choosing = false
            }
        }
    }

    ApText {
        Layout.fillWidth: true
        visible: panel.status !== ""
        color: panel.statusOk ? ap.ok : ap.bad
        font.weight: Font.Medium
        text: panel.status
    }

    // ───────── мої броні ─────────
    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8
        visible: panel.mine.length > 0
        spacing: 0
        ApText { role: "cap"; text: qsTr("Мої броні"); Layout.bottomMargin: 6 }
        Repeater {
            model: panel.mine
            ColumnLayout {
                id: mineCard
                required property var modelData
                readonly property bool asking: panel.confirmId === modelData.id
                readonly property var chip: panel.statusChip(modelData)
                Layout.fillWidth: true
                spacing: 6
                ApRow {
                    hairline: !mineCard.asking && !mineCard.modelData.extPending && !mineCard.modelData.cancelNote
                    title: panel.rangeText(mineCard.modelData.start, mineCard.modelData.end)
                    subtitle: qsTr("%1, %2").arg(mineCard.modelData.title).arg(wallet.price(mineCard.modelData.price))
                    ApChip { text: mineCard.chip.text; kind: mineCard.chip.kind }
                    ApButton {
                        visible: !!mineCard.modelData.canCancel && !mineCard.asking
                        small: true; ghost: true
                        text: qsTr("Скасувати")
                        onClicked: panel.confirmId = mineCard.modelData.id
                    }
                }
                ApText {
                    Layout.fillWidth: true
                    visible: !!mineCard.modelData.extPending
                    color: ap.gold
                    role: "small"
                    text: mineCard.modelData.extPending
                        ? (mineCard.modelData.extPending.status === "hold"
                            ? qsTr("Продовження до %1 (%2) ще не оплачено.") : qsTr("Продовження до %1 (%2): перевіряємо оплату."))
                            .arg(panel.hhmm(mineCard.modelData.extPending.end)).arg(wallet.price(mineCard.modelData.extPending.price))
                        : ""
                }
                ApText {   // правило скасування: до якого часу можна і що буде з оплатою
                    Layout.fillWidth: true
                    visible: !!mineCard.modelData.cancelNote && !mineCard.asking
                    role: "small"
                    text: mineCard.modelData.cancelNote || ""
                }
                ApText {
                    Layout.fillWidth: true
                    visible: mineCard.asking
                    text: mineCard.modelData.cancelKind === "refund"
                        ? (wallet.on ? qsTr("Скасувати цю бронь? Ти її оплатив, тому %1 одразу повернемо на баланс: їх можна витратити на наступну гру.").arg(wallet.price(mineCard.modelData.price))
                                     : qsTr("Скасувати цю бронь? Ти її оплатив, тому ми повернемо %1. Бот у Telegram запитає, куди повернути кошти.").arg(mineCard.modelData.price))
                        : qsTr("Скасувати цю бронь? Оплати за неї не було, тож повертати нічого не треба.")
                }
                RowLayout {
                    visible: mineCard.asking
                    spacing: 10
                    ApButton { small: true; danger: true; text: qsTr("Так, скасувати"); onClicked: panel.cloud.cancelBooking(mineCard.modelData.id) }
                    ApButton { small: true; ghost: true; text: qsTr("Ні, лишити"); onClicked: panel.confirmId = 0 }
                }
                Rectangle {
                    visible: mineCard.asking || !!mineCard.modelData.extPending || !!mineCard.modelData.cancelNote
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    Layout.preferredHeight: 1
                    color: ap.hair
                }
            }
        }
        ApButton {
            visible: panel.showPay && (panel.info.openCount || 0) < (panel.info.limit || 1)
            Layout.topMargin: 14
            ghost: true
            text: qsTr("+ Забронювати ще час")
            onClicked: panel.choosing = true
        }
    }

    // кнопка часу: тонка рамка, обрана — суцільна світла
    component TimeButton: AbstractButton {
        id: tb
        checkable: false        // обраний стан задає панель через checked
        property bool accent: false   // «Грати зараз»: золота рамка й напис
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        horizontalPadding: 0
        verticalPadding: 8
        implicitWidth: tbText.implicitWidth + leftPadding + rightPadding
        implicitHeight: tbText.implicitHeight + topPadding + bottomPadding
        Keys.onReturnPressed: clicked()
        contentItem: Text {
            id: tbText
            text: tb.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 16
            color: tb.checked ? ap.dark : (tb.accent ? ap.gold : ap.ink)
        }
        background: Rectangle {
            radius: ap.radius
            color: tb.checked ? (tb.accent ? ap.gold : ap.ink) : (tb.hovered ? "#14ffffff" : "#0affffff")
            border.width: tb.visualFocus ? 2 : 1
            border.color: tb.visualFocus ? ap.cyan : (tb.accent ? ap.gold : (tb.checked || tb.hovered ? ap.ink : ap.edge))
        }
    }
}
