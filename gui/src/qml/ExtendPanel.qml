// AnyPlay: продовження гри й оплата прямо в програмі (з головного екрана і з меню під час гри).
// Обраний час одразу закривається для інших у боті; оплата перевіряється автоматично або адміном.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

ColumnLayout {
    id: panel
    property var cloud: Chiaki.cloud
    property bool compact: false          // у меню під час гри — усе в два рядки
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
    onInfoChanged: {
        if (pending) {
            lastPending = pending;
            verdict = "";
        } else if (lastPending && info.active !== undefined) {
            if (info.active && info.end >= lastPending.end) { verdict = "paid"; paidEnd = info.end; status = ""; }
            else if (lastPending.status === "pending_review") { verdict = "rejected"; status = ""; }
            else verdict = "expired";
            lastPending = null;
        }
    }
    spacing: compact ? 6 : 12

    function reload() { status = ""; cloud.loadExtend(); }
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

    Label {
        visible: !panel.compact
        text: qsTr("⏱ Продовжити гру")
        font.pixelSize: 24; font.bold: true; color: "white"
    }
    // ── стан оплати одним рядком: не оплачено / перевіряємо / оплачено / відхилено ──
    Rectangle {
        id: payState
        readonly property string kind: panel.pending ? (panel.pending.status === "pending_review" ? "review" : "hold") : panel.verdict
        visible: kind !== ""
        Layout.fillWidth: true
        radius: 14
        implicitHeight: payStateRow.implicitHeight + (panel.compact ? 14 : 22)
        color: kind === "paid" ? "#143d2a" : (kind === "review" ? "#3d3214" : (kind === "hold" ? "#1f1240" : "#3d1420"))
        border.width: 2
        border.color: kind === "paid" ? "#3dff9a" : (kind === "review" ? "#ffd23f" : (kind === "hold" ? "#22e4ff" : "#ff4d6d"))
        RowLayout {
            id: payStateRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: panel.compact ? 12 : 16 }
            spacing: 12
            BusyIndicator {
                visible: payState.kind === "review"
                running: visible
                Layout.preferredWidth: 28; Layout.preferredHeight: 28
                Material.accent: "#ffd23f"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    font.pixelSize: panel.compact ? 16 : 18; font.bold: true; color: "white"
                    text: {
                        const p = panel.pending;
                        if (payState.kind === "review")
                            return qsTr("⏳ Оплату ще НЕ підтверджено — перевіряємо платіж %1").arg(p.price);
                        if (payState.kind === "hold")
                            return qsTr("💳 Ще не оплачено: +%1 год (%2–%3) · %4").arg(panel.hoursOf(p))
                                .arg(panel.cloud.formatTime(p.start)).arg(panel.cloud.formatTime(p.end)).arg(p.price);
                        if (payState.kind === "paid")
                            return qsTr("✅ Оплачено — гру продовжено до %1").arg(panel.cloud.formatTime(panel.paidEnd));
                        if (payState.kind === "rejected")
                            return qsTr("❌ Оплату не підтверджено — час не додано");
                        return qsTr("⌛ Час на оплату минув — продовження скасовано");
                    }
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    font.pixelSize: 13; color: "#d8cdea"
                    text: payState.kind === "review" ? qsTr("Гра триває. Щойно платіж знайдеться — тут з'явиться «✅ Оплачено», час додасться сам, а в бот прийде повідомлення.")
                        : payState.kind === "hold" ? qsTr("Час закріплено за тобою на кілька хвилин. Оплати точну суму й натисни «✅ Я оплатив».")
                        : payState.kind === "paid" ? qsTr("Підтвердження також прийшло тобі в бот. Можна грати далі.")
                        : payState.kind === "rejected" ? qsTr("Ми не знайшли цей платіж. Якщо ти платив — напиши нам у боті: «🆘 Допомога».")
                        : qsTr("Можеш обрати час ще раз нижче.")
                }
            }
        }
    }
    Label {
        Layout.fillWidth: true
        visible: !panel.pending
        wrapMode: Text.WordWrap
        font.pixelSize: panel.compact ? 14 : 15
        color: "#bfaed8"
        text: {
            const i = panel.info;
            if (i.active === undefined) return qsTr("Завантажуємо…");
            if (!i.active) return qsTr("Продовжити можна лише під час своєї гри. Нову бронь — у боті.");
            if (i.closed) return qsTr("Зараз триває обслуговування — продовження тимчасово недоступне.");
            if (panel.pending && panel.pending.status === "pending_review")
                return qsTr("⏳ Перевіряємо оплату %1 (%2–%3). Гра триває — коли оплата знайдеться, час додасться сам.")
                    .arg(panel.pending.price).arg(panel.cloud.formatTime(panel.pending.start)).arg(panel.cloud.formatTime(panel.pending.end));
            if (panel.pending)
                return qsTr("Час %1–%2 закріплено за тобою. Переказуй точну суму — так оплата знайдеться автоматично.")
                    .arg(panel.cloud.formatTime(panel.pending.start)).arg(panel.cloud.formatTime(panel.pending.end));
            return qsTr("Гра зараз до %1. Обери, на скільки продовжити — оплата тут же, гра не переривається.")
                .arg(panel.cloud.formatTime(i.end));
        }
    }

    // ── спосіб оплати ──
    RowLayout {
        visible: !panel.compact && panel.methods.length > 1 && !!panel.info.active && !panel.info.closed
                 && !(panel.pending && panel.pending.status === "pending_review")
        spacing: 8
        Repeater {
            model: panel.methods
            Button {
                id: mb
                required property var modelData
                text: modelData.label
                checkable: true
                checked: panel.curMethod === modelData.code
                font.pixelSize: 13
                onClicked: {
                    panel.method = modelData.code;
                    if (panel.pending && panel.pending.method !== modelData.code)
                        panel.cloud.extend(panel.hoursOf(panel.pending), modelData.code);
                }
            }
        }
    }

    // ── варіанти: +1 / +2 / +3 год ──
    RowLayout {
        visible: !!panel.info.active && !panel.info.closed && !panel.pending
        spacing: 10
        Repeater {
            model: (panel.info.options || []).slice(0, panel.maxOptions)
            Button {
                id: opt
                required property var modelData
                focusPolicy: Qt.StrongFocus
                enabled: modelData.free
                Layout.preferredWidth: panel.compact ? 150 : 170
                Layout.preferredHeight: panel.compact ? 62 : 66
                onClicked: { panel.status = qsTr("Закріплюємо час…"); panel.statusOk = true; panel.cloud.extend(modelData.hours, panel.curMethod); }
                Keys.onReturnPressed: clicked()
                contentItem: ColumnLayout {
                    spacing: 0
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("+%1 год").arg(opt.modelData.hours)
                        font.pixelSize: 18; font.bold: true
                        color: opt.enabled ? "white" : "#88ffffff"
                    }
                    Label {
                        Layout.alignment: Qt.AlignHCenter
                        text: opt.modelData.free ? panel.priceFor(opt.modelData) : qsTr("зайнято")
                        font.pixelSize: 13
                        color: opt.enabled ? "#ffe7f6" : "#88ffffff"
                    }
                }
                background: Rectangle {
                    radius: 16
                    opacity: opt.enabled ? (opt.down ? 0.8 : 1) : 0.4
                    border.color: opt.activeFocus || opt.hovered ? "#22e4ff" : "transparent"
                    border.width: 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#ff9a3c" }
                        GradientStop { position: 0.5; color: "#ff2e9a" }
                        GradientStop { position: 1.0; color: "#7b2cff" }
                    }
                }
            }
        }
    }

    // ── оплата: сума, реквізити, «Я оплатив» ──
    Rectangle {
        Layout.fillWidth: true
        visible: !!panel.pending && panel.pending.status === "hold"
        radius: 16
        color: "#1f1240"
        border.color: "#3322e4ff"
        implicitHeight: payCol.implicitHeight + (panel.compact ? 16 : 28)
        ColumnLayout {
            id: payCol
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: panel.compact ? 10 : 16 }
            spacing: panel.compact ? 4 : 8
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Label { text: qsTr("Сума:"); color: "#bfaed8"; font.pixelSize: panel.compact ? 14 : 16 }
                Label {
                    text: panel.pending ? panel.pending.price : ""
                    color: "#ffd23f"; font.bold: true; font.pixelSize: panel.compact ? 18 : 24
                }
                Button {
                    text: qsTr("📋")
                    flat: true
                    onClicked: panel.cloud.copyText(panel.pending.amount)
                }
                Item { Layout.fillWidth: true }
                Button {   // у меню гри: оплата одним натиском, якщо є посилання
                    visible: panel.compact && !!panel.pending && !!panel.pending.payUrl
                    text: qsTr("💳 Оплатити")
                    font.bold: true
                    onClicked: Qt.openUrlExternally(panel.pending.payUrl)
                }
                Repeater {   // у меню гри — реквізити тим самим рядком
                    model: panel.compact && panel.pending && !panel.pending.payUrl ? panel.pending.requisites.slice(0, 1) : []
                    Button {
                        required property var modelData
                        text: modelData.label + ": " + modelData.value + "  📋"
                        flat: true
                        font.pixelSize: 13
                        onClicked: modelData.url ? Qt.openUrlExternally(modelData.value) : panel.cloud.copyText(modelData.value)
                    }
                }
                Button {
                    visible: panel.compact
                    highlighted: true
                    Material.accent: "#ff2e9a"
                    text: qsTr("✅ Я оплатив")
                    font.bold: true
                    enabled: !panel.cloud.busy
                    onClicked: panel.cloud.payExtend(panel.pending.id, "")
                }
            }
            Button {   // головне: відкрити оплату одразу з потрібною сумою
                visible: !panel.compact && !!panel.pending && !!panel.pending.payUrl
                Layout.fillWidth: true
                Layout.preferredHeight: 58
                font.pixelSize: 19; font.bold: true
                text: qsTr("💳 Оплатити %1").arg(panel.pending ? panel.pending.price : "")
                onClicked: Qt.openUrlExternally(panel.pending.payUrl)
                contentItem: Label {
                    text: parent.text; font: parent.font; color: "white"
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 16
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#ff9a3c" }
                        GradientStop { position: 0.5; color: "#ff2e9a" }
                        GradientStop { position: 1.0; color: "#7b2cff" }
                    }
                }
            }
            Label {
                visible: !panel.compact && !!panel.pending && !!panel.pending.payUrl
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                color: "#bfaed8"; font.pixelSize: 13
                text: qsTr("Відкриється сторінка оплати з уже вписаною сумою — карткою, Apple Pay чи Google Pay. Або переказ за реквізитами:")
            }
            Repeater {
                model: !panel.compact && panel.pending ? panel.pending.requisites : []
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 10
                    Label { text: modelData.label + ":"; color: "#bfaed8"; font.pixelSize: 15; Layout.preferredWidth: 150 }
                    Label {
                        Layout.fillWidth: true
                        text: modelData.value; color: "white"; font.pixelSize: 17; font.bold: true
                        elide: Text.ElideMiddle
                    }
                    Button {
                        text: modelData.url ? qsTr("Відкрити") : qsTr("📋 Копіювати")
                        onClicked: modelData.url ? Qt.openUrlExternally(modelData.value) : panel.cloud.copyText(modelData.value)
                    }
                }
            }
            TextField {
                id: senderField
                Layout.fillWidth: true
                visible: !panel.compact && panel.bank
                placeholderText: qsTr("Ім'я та прізвище відправника, як у банку (необов'язково)")
                font.pixelSize: 14
            }
            Button {
                visible: !panel.compact
                Layout.fillWidth: true
                Layout.preferredHeight: 54
                highlighted: true
                Material.accent: "#ff2e9a"
                enabled: !panel.cloud.busy
                font.pixelSize: 18; font.bold: true
                text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("✅ Я оплатив")
                onClicked: panel.cloud.payExtend(panel.pending.id, senderField.text)
            }
        }
    }

    Label {
        Layout.fillWidth: true
        visible: panel.status !== ""
        wrapMode: Text.WordWrap
        maximumLineCount: panel.compact ? 2 : 6
        elide: Text.ElideRight
        font.pixelSize: panel.compact ? 13 : 15
        color: panel.statusOk ? "#3dff9a" : "#ff4d6d"
        text: panel.status
    }
}
