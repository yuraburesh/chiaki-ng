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
    spacing: compact ? 6 : 12

    function reload() { status = ""; cloud.loadExtend(); }
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
    Label {
        Layout.fillWidth: true
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
                Layout.preferredHeight: panel.compact ? 56 : 66
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
                Repeater {   // у меню гри — реквізити тим самим рядком
                    model: panel.compact && panel.pending ? panel.pending.requisites.slice(0, 1) : []
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
