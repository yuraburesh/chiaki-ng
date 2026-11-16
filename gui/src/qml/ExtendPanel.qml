// AnyPlay: продовження гри прямо з програми (і з головного екрана, і з меню під час гри).
// Слот одразу закривається для інших у боті, реквізити й «✅ Я оплатив» приходять у Telegram.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

ColumnLayout {
    id: panel
    property var cloud: Chiaki.cloud
    property bool compact: false          // у меню під час гри — менше тексту
    property int maxOptions: 3
    readonly property var info: cloud.extendInfo || ({})
    readonly property var pending: info.pending || null
    property string status: ""
    property bool statusOk: true
    spacing: compact ? 6 : 12

    function reload() { status = ""; cloud.loadExtend(); }
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
            return qsTr("Гра зараз до %1. Обери, на скільки продовжити — оплата в Telegram, гра не переривається.")
                .arg(panel.cloud.formatTime(i.end));
        }
    }
    RowLayout {
        visible: !!panel.info.active && !panel.info.closed
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
                onClicked: { panel.status = qsTr("Закріплюємо час…"); panel.statusOk = true; panel.cloud.extend(modelData.hours); }
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
                        text: opt.modelData.free ? opt.modelData.price : qsTr("зайнято")
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
    Label {
        Layout.fillWidth: true
        visible: !!panel.pending
        wrapMode: Text.WordWrap
        font.pixelSize: panel.compact ? 14 : 15; font.bold: true
        color: "#ffd23f"
        text: panel.pending
            ? (panel.pending.status === "pending_review"
                ? qsTr("⏳ Перевіряємо оплату продовження %1–%2…").arg(panel.cloud.formatTime(panel.pending.start)).arg(panel.cloud.formatTime(panel.pending.end))
                : qsTr("⏳ Чекаємо оплату: %1–%2 · %3. Реквізити — у Telegram, там натисни «✅ Я оплатив».")
                    .arg(panel.cloud.formatTime(panel.pending.start)).arg(panel.cloud.formatTime(panel.pending.end)).arg(panel.pending.price))
            : ""
    }
    Label {
        Layout.fillWidth: true
        visible: panel.status !== "" && !(panel.pending && panel.statusOk)
        wrapMode: Text.WordWrap
        font.pixelSize: panel.compact ? 14 : 15
        color: panel.statusOk ? "#3dff9a" : "#ff4d6d"
        text: panel.status
    }
}
