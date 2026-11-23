// AnyPlay: вкладка «Баланс» — скільки на балансі і навіщо він, поповнення переказом, як це працює, історія.
// Баланс необов'язковий: за кожну гру клієнт сам обирає, платити з балансу чи переказом. Виводу на картку немає.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

GridLayout {
    id: panel
    property var cloud: Chiaki.cloud
    property bool twoCol: true
    property real leftW: width
    property real rightW: width
    property real amountSize: 88
    columns: twoCol ? 2 : 1
    rowSpacing: 28
    AnyPlayStyle { id: ap }
    AnyPlayWallet { id: wallet }

    // ── поповнення: спосіб (від нього залежить валюта) і сума ──
    readonly property var methods: wallet.topup.methods || []
    property string method: ""
    readonly property string curMethod: {
        if (method !== "")
            return method;
        for (let i = 0; i < methods.length; i++)
            if (wallet.currencyOf(methods[i].code) === wallet.primary)
                return methods[i].code;
        return methods.length ? methods[0].code : wallet.primary.toLowerCase();
    }
    readonly property string cur: wallet.currencyOf(curMethod)
    readonly property var presets: ({ UAH: [250, 500, 1000], PLN: [25, 50, 100], USDT: [5, 10, 20] })
    readonly property var amounts: (wallet.topup.amounts && wallet.topup.amounts[cur]) || presets[cur] || []
    readonly property real minAmount: (wallet.topup.min && wallet.topup.min[cur]) || 0
    readonly property real maxAmount: (wallet.topup.max && wallet.topup.max[cur]) || 0
    property bool own: false               // «Інша сума»: клієнт вписує свою
    property real asked: 0                 // сума, яку щойно обрали (поки сервер не відповів)
    property string status: ""
    property bool statusOk: true
    // поповнення, яке чекає переказу (не те, що вже перевіряють)
    readonly property var hold: {
        const p = wallet.pending;
        for (let i = 0; i < p.length; i++)
            if (p[i].status !== "pending_review")
                return p[i];
        return null;
    }
    // сума поповнення без «копійок» для впізнавання (base), якщо сервер її дає
    function baseOf(t) { return t.base !== undefined ? Number(t.base) : wallet.parse(t.amount !== undefined ? t.amount : t.price); }
    function holdIs(a) { return !!hold && wallet.currencyOf(hold.method) === cur && Math.abs(baseOf(hold) - a) < 1; }
    function picked(a) { return hold ? holdIs(a) : (!own && asked === a && cloud.busy); }
    function topUp(a) {
        if (!(a > 0) || holdIs(a))
            return;   // це поповнення вже показано
        asked = a;    // неоплачене поповнення на іншу суму програма прибере сама
        status = "";
        cloud.topUp(curMethod, a);
    }
    function ownSubmit() {
        const a = wallet.parse(ownField.text);
        if (!(a > 0)) { status = qsTr("Впиши суму поповнення."); statusOk = false; return; }
        if ((minAmount > 0 && a < minAmount) || (maxAmount > 0 && a > maxAmount)) {
            status = qsTr("Поповнити можна на суму від %1 до %2.").arg(wallet.money(minAmount, cur)).arg(wallet.money(maxAmount, cur));
            statusOk = false;
            return;
        }
        own = false;
        topUp(Math.round(a * 100) / 100);
    }
    function methodLabel(code) {
        for (let i = 0; i < methods.length; i++)
            if (methods[i].code === code)
                return methods[i].label;
        return String(code || "").toUpperCase();
    }

    // ── валюта балансу: у чому тримати гроші; усе, що є і що прийде, перераховується за курсом ──
    // сервер дає коди рядками ("UAH"); старий формат — об'єкти {code}
    readonly property var curList: (wallet.data.currencies || ["UAH", "PLN", "USDT"]).map(x => typeof x === "string" ? x : (x && x.code) || "")
                                                                                  .filter(x => x !== "")
    readonly property string balCur: wallet.data.currency || wallet.primary
    property var curPreview: null          // відповідь сервера «що вийде», поки клієнт не підтвердив
    property string curAsked: ""
    function curName(c) { return c === "UAH" ? qsTr("Гривні ₴") : c === "PLN" ? qsTr("Злоті zł") : "USDT"; }
    function askCurrency(c) {
        status = "";
        if (c === balCur && wallet.others.length === 0) { curPreview = null; curAsked = ""; return; }
        curAsked = c;
        curPreview = null;
        cloud.walletCurrency(c, true);
    }

    onVisibleChanged: if (visible) { status = ""; own = false; curPreview = null; curAsked = ""; cloud.loadWallet(); }
    Component.onCompleted: if (visible) cloud.loadWallet()
    Connections {
        target: panel.cloud
        function onWalletResult(ok, text) { panel.status = text; panel.statusOk = ok; panel.curPreview = null; panel.curAsked = ""; }
        function onWalletCurrencyPreview(info) { if (panel.curAsked !== "") panel.curPreview = info; }
    }
    // відкрите поповнення: перепитуємо сервер, щоб гроші з'явились на балансі самі
    Timer {
        interval: 10000; repeat: true
        running: panel.visible && wallet.pending.length > 0
        onTriggered: panel.cloud.loadWallet()
    }

    // ═════ ліворуч: скільки є, навіщо, поповнення ═════
    ColumnLayout {
        Layout.preferredWidth: panel.leftW
        Layout.maximumWidth: panel.leftW
        Layout.alignment: Qt.AlignTop
        spacing: 0
        ApText { role: "h2"; text: qsTr("Баланс") }
        ApTimer {   // та сама велика цифра, що й таймер гри
            Layout.topMargin: 8
            size: panel.amountSize
            text: wallet.primaryText
        }
        ApText {
            visible: wallet.others.length > 0
            Layout.fillWidth: true
            Layout.topMargin: 8
            role: "small"
            text: qsTr("Ще на балансі: %1").arg(wallet.others.map(b => wallet.money(b.amount, b.currency)).join(", "))
        }
        ApText {
            Layout.fillWidth: true
            Layout.maximumWidth: 520
            Layout.topMargin: 8
            role: "lead"; rich: true
            text: qsTr("Баланс — це передоплата за гру в AnyPlay. Поповнюєш один раз, а далі платиш за броні й продовження <b>одним натиском</b>: без переказу і без чекання, поки знайдеться оплата.")
        }
        ApText {
            Layout.fillWidth: true
            Layout.maximumWidth: 520
            Layout.topMargin: 6
            role: "lead"
            text: qsTr("Це не обов'язково: за кожну гру можна заплатити й переказом. Спосіб оплати обираєш щоразу сам. Якщо на балансі не вистачає, решту доплачуєш карткою.")
        }

        ApText { role: "cap"; text: qsTr("Валюта балансу"); Layout.topMargin: 24; Layout.bottomMargin: 6 }
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 6
            Repeater {
                model: panel.curList
                AmountButton {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    text: panel.curName(modelData)
                    checked: panel.curAsked !== "" ? panel.curAsked === modelData : panel.balCur === modelData
                    enabled: !panel.cloud.busy
                    onClicked: panel.askCurrency(modelData)
                }
            }
        }
        ApText {
            visible: !panel.curPreview
            Layout.fillWidth: true
            Layout.maximumWidth: 520
            Layout.topMargin: 6
            role: "small"
            text: qsTr("Поповнюй будь-яким способом: гроші самі перерахуються у вибрану валюту за курсом НБУ.")
        }
        Rectangle {   // що вийде після зміни валюти: показуємо до того, як щось міняти
            visible: !!panel.curPreview
            Layout.fillWidth: true
            Layout.topMargin: 8
            radius: ap.radius
            color: "#0affffff"
            border.width: 1; border.color: ap.edge
            implicitHeight: curCol.implicitHeight + 28
            ColumnLayout {
                id: curCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                spacing: 4
                readonly property var pv: panel.curPreview || ({})
                readonly property var parts: pv.parts || []
                ApText {
                    Layout.fillWidth: true
                    font.weight: Font.Medium
                    text: curCol.parts.length
                        ? qsTr("Баланс стане %1").arg(wallet.money(curCol.pv.to ? curCol.pv.to.amount : 0, curCol.pv.to ? curCol.pv.to.currency : panel.curAsked))
                        : qsTr("Нові поповнення зараховуватимуться в цій валюті")
                }
                Repeater {
                    model: curCol.parts
                    ApText {
                        required property var modelData
                        Layout.fillWidth: true
                        role: "small"
                        text: qsTr("%1 → %2, курс %3").arg(wallet.money(modelData.from.amount, modelData.from.currency))
                            .arg(wallet.money(modelData.to.amount, modelData.to.currency)).arg(modelData.rate)
                    }
                }
                ApText {
                    visible: Number(curCol.pv.fee) > 0
                    Layout.fillWidth: true
                    role: "small"
                    text: qsTr("Комісія за зміну валюти: %1%").arg(String(curCol.pv.fee).replace(".", ","))
                }
                RowLayout {
                    Layout.topMargin: 8
                    spacing: 8
                    ApButton {
                        small: true
                        enabled: !panel.cloud.busy
                        text: curCol.parts.length ? qsTr("Перевести") : qsTr("Обрати")
                        onClicked: panel.cloud.walletCurrency(panel.curAsked, false)
                    }
                    ApButton {
                        small: true; ghost: true
                        text: qsTr("Скасувати")
                        onClicked: { panel.curPreview = null; panel.curAsked = ""; }
                    }
                }
            }
        }

        ApText { role: "cap"; text: qsTr("Поповнити"); Layout.topMargin: 24; Layout.bottomMargin: 6 }
        Flow {   // валюта поповнення, якщо способів кілька
            visible: panel.methods.length > 1
            Layout.fillWidth: true
            Layout.bottomMargin: 10
            spacing: 8
            Repeater {
                model: panel.methods
                ApButton {
                    required property var modelData
                    small: true
                    ghost: panel.curMethod !== modelData.code
                    font.family: ap.body
                    font.capitalization: Font.MixedCase
                    font.letterSpacing: 0
                    font.pixelSize: 15
                    topPadding: 11; bottomPadding: 11
                    leftPadding: 16; rightPadding: 16
                    text: modelData.label
                    onClicked: { panel.method = modelData.code; panel.own = false; panel.status = ""; }
                }
            }
        }
        GridLayout {
            Layout.fillWidth: true
            columns: 4
            columnSpacing: 6
            rowSpacing: 6
            Repeater {
                model: panel.amounts
                AmountButton {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    text: wallet.money(modelData, panel.cur)
                    checked: panel.picked(modelData)
                    enabled: !panel.cloud.busy
                    onClicked: { panel.own = false; panel.topUp(modelData); }
                }
            }
            AmountButton {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                text: qsTr("Інша сума")
                checked: panel.own || (!!panel.hold && wallet.currencyOf(panel.hold.method) === panel.cur && !panel.amounts.some(a => panel.holdIs(a)))
                enabled: !panel.cloud.busy
                onClicked: { panel.own = true; panel.status = ""; ownField.forceActiveFocus(); }
            }
        }
        RowLayout {   // своя сума
            visible: panel.own
            Layout.fillWidth: true
            Layout.topMargin: 10
            spacing: 10
            ApField {
                id: ownField
                Layout.preferredWidth: 180
                placeholderText: qsTr("Сума, %1").arg(wallet.symbol(panel.cur))
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                maximumLength: 9
                onAccepted: panel.ownSubmit()
            }
            ApButton {
                small: true
                Layout.preferredHeight: ownField.implicitHeight
                enabled: !panel.cloud.busy && ownField.text.trim() !== ""
                text: qsTr("Поповнити")
                onClicked: panel.ownSubmit()
            }
            ApText {
                visible: panel.minAmount > 0 && panel.maxAmount > 0
                Layout.fillWidth: true
                role: "small"
                text: qsTr("від %1 до %2").arg(wallet.money(panel.minAmount, panel.cur)).arg(wallet.money(panel.maxAmount, panel.cur))
            }
        }
        ApText {
            visible: panel.status !== ""
            Layout.fillWidth: true
            Layout.topMargin: 10
            font.weight: Font.Medium
            color: panel.statusOk ? ap.ok : ap.bad
            text: panel.status
        }
        Repeater {   // відкриті поповнення: реквізити й «Я оплатив», або «перевіряємо»
            model: wallet.pending
            TopupBox { }
        }
    }

    // ═════ праворуч: як це працює, історія ═════
    ColumnLayout {
        Layout.preferredWidth: panel.rightW
        Layout.maximumWidth: panel.rightW
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: panel.twoCol ? 4 : 0   // верх підпису праворуч — на рівні верху заголовка ліворуч
        spacing: 0
        ApText { role: "cap"; text: qsTr("Як це працює"); Layout.bottomMargin: 6 }
        Repeater {
            model: [
                { t: qsTr("Поповнюєш на будь-яку суму"), s: qsTr("переказом, як за звичайну бронь; гроші з'являться на балансі за 1–2 хвилини") },
                { t: qsTr("Платиш з балансу за секунду"), s: qsTr("бронь чи продовження бронювання прямо під час гри, нічого не переказуєш") },
                { t: qsTr("Не вистачає — доплачуєш карткою"), s: qsTr("частину спишемо з балансу, решту переказуєш як звичайну оплату") },
                { t: qsTr("Скасував бронь — гроші на баланс"), s: qsTr("повертаються одразу, можна витратити на наступну гру") },
                { t: qsTr("Залишок не згорає"), s: qsTr("лишається на балансі для наступних ігор") }
            ]
            ApRow {
                required property var modelData
                required property int index
                rich: true
                title: "<font color=\"#a6ffffff\">" + (index + 1) + ".</font> " + modelData.t
                subtitle: modelData.s
            }
        }
        ApText { role: "cap"; text: qsTr("Історія"); Layout.topMargin: 22; Layout.bottomMargin: 6 }
        ApText {
            visible: wallet.history.length === 0
            role: "hint"
            topPadding: 10; bottomPadding: 10
            text: wallet.data.history === undefined ? qsTr("Завантажуємо…") : qsTr("Поки порожньо.")
        }
        Repeater {
            model: wallet.history.slice(0, 30)
            ApRow {
                required property var modelData
                title: modelData.title || ""
                subtitle: modelData.subtitle || wallet.dayText(modelData.ts)
                ApChip {
                    text: wallet.money(modelData.amount, modelData.currency, true)
                    kind: Number(modelData.amount) > 0 ? "ok" : ""
                }
            }
        }
    }

    // кнопка суми: тонка рамка, обрана — суцільна світла
    component AmountButton: AbstractButton {
        id: ab
        checkable: false
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        horizontalPadding: 4
        verticalPadding: 10
        implicitWidth: abText.implicitWidth + leftPadding + rightPadding
        implicitHeight: abText.implicitHeight + topPadding + bottomPadding
        opacity: enabled || checked ? 1 : 0.6
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        contentItem: Text {
            id: abText
            text: ab.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            font.family: ap.body; font.pixelSize: 15
            color: ap.ink
            font.weight: ab.checked ? Font.Bold : Font.Medium
        }
        transform: Translate { y: ab.down ? 1 : (ab.hovered && !ab.checked ? -1 : 0); Behavior on y { NumberAnimation { duration: ap.tHover } } }
        scale: ab.down ? ap.pressScale : 1
        Behavior on scale { NumberAnimation { duration: ap.tPress } }
        background: Rectangle {   // дизайн 112: скло, обране — захід сонця
            radius: ap.radius
            color: ab.hovered ? ap.glassHi : ap.glass
            border.width: ab.visualFocus ? 2 : (ab.checked ? 0 : 1)
            border.color: ab.visualFocus ? ap.cyan : (ab.hovered ? ap.edgeHi : ap.edge)
            Rectangle {
                anchors.fill: parent; radius: parent.radius
                visible: ab.checked
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
        }
    }

    // відкрите поповнення: сума до копійки, оплата за посиланням чи реквізитами, «Я оплатив», «Скасувати»
    component TopupBox: Rectangle {
        id: tb
        required property var modelData
        readonly property var t: modelData
        readonly property string tcur: t.currency || wallet.currencyOf(t.method)
        readonly property bool review: t.status === "pending_review"   // «Я оплатив» уже натиснуто
        readonly property bool bank: t.method === "uah" || t.method === "pln"
        readonly property string sum: wallet.money(wallet.parse(t.amount !== undefined ? t.amount : t.price), tcur)
        Layout.fillWidth: true
        Layout.topMargin: 10
        implicitHeight: tbCol.implicitHeight + 30
        radius: ap.radius
        color: "#08ffffff"
        border.width: 1
        border.color: review ? "#80ffd9a0" : ap.edge
        ColumnLayout {
            id: tbCol
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 15 }
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ApText {
                    Layout.fillWidth: true
                    role: "small"
                    color: tb.review ? ap.gold : ap.faint
                    text: tb.review ? qsTr("Перевіряємо оплату поповнення")
                        : tb.t.method === "uah" ? qsTr("Переказ на картку AnyPlay")
                        : qsTr("Переказ: %1").arg(panel.methodLabel(tb.t.method))
                }
                ApButton {   // передумав поповнювати
                    visible: !tb.review
                    small: true; ghost: true
                    text: qsTr("Скасувати")
                    onClicked: { panel.asked = 0; panel.status = ""; panel.cloud.topUpCancel(tb.t.topupId); }
                }
            }
            RowLayout {
                spacing: 14
                BusyIndicator {
                    visible: tb.review
                    running: visible
                    Layout.preferredWidth: 26; Layout.preferredHeight: 26
                }
                Text {
                    text: tb.sum
                    font.family: ap.display; font.weight: Font.Medium; font.pixelSize: 34; font.letterSpacing: 1
                    color: ap.ink
                }
                ApButton { visible: !tb.review; small: true; ghost: true; text: qsTr("Копіювати суму"); onClicked: panel.cloud.copyText(String(tb.t.amount)) }
            }
            ApText {
                Layout.fillWidth: true
                role: "small"
                text: tb.review ? qsTr("Зазвичай 1–2 хвилини. Баланс поповниться сам, програму можна не закривати.")
                    : qsTr("Переказуй точну суму до копійки: так оплата знайдеться сама і з'явиться на балансі за 1–2 хвилини.")
                      + (tb.t.holdUntil > 0 ? " " + qsTr("Чекаємо переказ до %1.").arg(panel.cloud.formatTime(tb.t.holdUntil)) : "")
            }
            ColumnLayout {   // реквізити, якщо платити не за посиланням
                visible: !tb.review && !!tb.t.requisites && tb.t.requisites.length > 0
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: tb.review ? [] : (tb.t.requisites || [])
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
                visible: !tb.review && tb.bank
                Layout.fillWidth: true
                placeholderText: qsTr("Ім'я та прізвище відправника, як у банку (необов'язково)")
            }
            Flow {
                visible: !tb.review
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 10
                ApButton {
                    id: payBtn
                    visible: !!tb.t.payUrl
                    text: qsTr("Оплатити %1").arg(tb.sum)
                    onClicked: Qt.openUrlExternally(tb.t.payUrl)
                }
                ApButton {
                    ghost: !!tb.t.payUrl
                    height: payBtn.visible ? payBtn.height : implicitHeight
                    enabled: !panel.cloud.busy
                    text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("Я оплатив")
                    onClicked: panel.cloud.topUpPaid(tb.t.topupId, senderField.text)
                }
            }
        }
    }
}
