// AnyPlay: бронювання й оплата прямо в програмі — день, тривалість, час, оплата. Без Telegram.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

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
    property bool choosing: false          // true — показуємо вибір часу, навіть якщо є неоплачена бронь
    property string status: ""
    property bool statusOk: true
    readonly property string curMethod: method !== "" ? method : (methods.length ? methods[0].code : "")
    readonly property var tariff: {
        for (let i = 0; i < tariffs.length; i++)
            if (tariffs[i].code === code)
                return tariffs[i];
        return null;
    }
    readonly property bool showPay: !!payItem && !choosing
    spacing: 12

    function reload() { status = ""; cloud.loadBook(); }
    function loadStarts() {
        start = 0;
        if (days.length > dayIndex && code !== "")
            cloud.loadBookStarts(days[dayIndex].date, code);
    }
    function dayLabel(i) {
        if (i === 0) return qsTr("Сьогодні");
        if (i === 1) return qsTr("Завтра");
        const d = new Date((days[i].start + 12 * 3600) * 1000);
        return [qsTr("Нд"), qsTr("Пн"), qsTr("Вт"), qsTr("Ср"), qsTr("Чт"), qsTr("Пт"), qsTr("Сб")][d.getDay()] + " " + d.getDate() + "." + String(d.getMonth() + 1).padStart(2, "0");
    }
    function hhmm(ts) {
        const d = new Date(ts * 1000);
        return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
    }
    function rangeText(a, b) {
        const d = new Date(a * 1000), now = new Date();
        const same = d.toDateString() === now.toDateString();
        const day = same ? qsTr("сьогодні") : (d.getDate() + "." + String(d.getMonth() + 1).padStart(2, "0"));
        return day + " · " + hhmm(a) + "–" + hhmm(b);
    }
    function statusText(s) {
        return s === "hold" ? qsTr("чекає оплату") : s === "pending_review" ? qsTr("перевіряємо оплату")
             : s === "active" ? qsTr("йде гра") : qsTr("оплачено ✅");
    }

    onVisibleChanged: if (visible) { choosing = false; reload(); }
    Component.onCompleted: if (visible) reload()
    onDayIndexChanged: loadStarts()
    onCodeChanged: loadStarts()
    onTariffsChanged: if (code === "" && tariffs.length) code = tariffs[0].code

    Connections {
        target: panel.cloud
        function onBookResult(ok, text) {
            panel.status = text; panel.statusOk = ok;
            if (ok) panel.choosing = false;
            panel.loadStarts();
        }
    }

    Label { text: qsTr("📅 Бронювання"); font.pixelSize: 24; font.bold: true; color: "white" }

    Label {
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        visible: !!panel.info.closed
        color: "#ffd23f"; font.pixelSize: 15
        text: qsTr("Зараз технічні роботи — бронювання тимчасово недоступне.")
    }

    // ───────── оплата закріпленого часу ─────────
    Rectangle {
        Layout.fillWidth: true
        visible: panel.showPay
        radius: 16; color: "#1f1240"; border.color: "#3322e4ff"
        implicitHeight: payCol.implicitHeight + 28
        ColumnLayout {
            id: payCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 8
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                color: "white"; font.pixelSize: 16; font.bold: true
                text: panel.payItem ? qsTr("%1 · %2").arg(panel.payItem.title).arg(panel.rangeText(panel.payItem.start, panel.payItem.end)) : ""
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                color: "#bfaed8"; font.pixelSize: 14
                text: qsTr("Час закріплено за тобою. Переказуй точну суму до копійки — так оплата знайдеться автоматично.")
            }
            RowLayout {
                spacing: 10
                Label { text: qsTr("Сума:"); color: "#bfaed8"; font.pixelSize: 16 }
                Label { text: panel.payItem ? panel.payItem.pending.price : ""; color: "#ffd23f"; font.bold: true; font.pixelSize: 26 }
                Button { text: qsTr("📋"); flat: true; onClicked: panel.cloud.copyText(panel.payItem.pending.amount) }
            }
            Button {
                visible: !!panel.payItem && !!panel.payItem.pending.payUrl
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                font.pixelSize: 18; font.bold: true
                text: qsTr("💳 Оплатити %1").arg(panel.payItem ? panel.payItem.pending.price : "")
                onClicked: Qt.openUrlExternally(panel.payItem.pending.payUrl)
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
            Repeater {
                model: panel.payItem ? panel.payItem.pending.requisites : []
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 10
                    Label { text: modelData.label + ":"; color: "#bfaed8"; font.pixelSize: 15; Layout.preferredWidth: 150 }
                    Label { Layout.fillWidth: true; text: modelData.value; color: "white"; font.pixelSize: 17; font.bold: true; elide: Text.ElideMiddle }
                    Button {
                        text: modelData.url ? qsTr("Відкрити") : qsTr("📋 Копіювати")
                        onClicked: modelData.url ? Qt.openUrlExternally(modelData.value) : panel.cloud.copyText(modelData.value)
                    }
                }
            }
            TextField {
                id: senderField
                Layout.fillWidth: true
                visible: !!panel.payItem && (panel.payItem.pending.method === "uah" || panel.payItem.pending.method === "pln")
                placeholderText: qsTr("Ім'я та прізвище відправника, як у банку (необов'язково)")
                font.pixelSize: 14
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Button {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 52
                    highlighted: true
                    Material.accent: "#ff2e9a"
                    enabled: !panel.cloud.busy
                    font.pixelSize: 17; font.bold: true
                    text: panel.cloud.busy ? qsTr("Надсилаємо…") : qsTr("✅ Я оплатив")
                    onClicked: panel.cloud.payBooking(panel.payItem.id, senderField.text)
                }
                Button {
                    Layout.preferredHeight: 52
                    flat: true
                    text: qsTr("Скасувати бронь")
                    onClicked: panel.cloud.cancelBooking(panel.payItem.id)
                }
            }
        }
    }

    // ───────── вибір часу ─────────
    ColumnLayout {
        Layout.fillWidth: true
        visible: !panel.showPay && !panel.info.closed
        spacing: 10

        Label { text: qsTr("1. День"); color: "#22e4ff"; font.pixelSize: 13; font.bold: true; font.letterSpacing: 2 }
        Flow {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: panel.days.length
                Chip {
                    required property int index
                    text: panel.dayLabel(index)
                    on: panel.dayIndex === index
                    onClicked: panel.dayIndex = index
                }
            }
        }

        Label { text: qsTr("2. Скільки грати"); color: "#22e4ff"; font.pixelSize: 13; font.bold: true; font.letterSpacing: 2; Layout.topMargin: 4 }
        Flow {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: panel.tariffs
                Chip {
                    required property var modelData
                    text: modelData.title
                    sub: modelData.prices[panel.curMethod] || ""
                    on: panel.code === modelData.code
                    onClicked: panel.code = modelData.code
                }
            }
        }

        Label { text: qsTr("3. Початок"); color: "#22e4ff"; font.pixelSize: 13; font.bold: true; font.letterSpacing: 2; Layout.topMargin: 4 }
        Label {
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            visible: panel.cloud.bookStartsLoading || panel.cloud.bookStarts.length === 0
            color: "#bfaed8"; font.pixelSize: 14
            text: panel.cloud.bookStartsLoading ? qsTr("Шукаємо вільний час…")
                : qsTr("На цей день для такої тривалості вільного часу немає — обери інший день або менше годин.")
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: panel.cloud.bookStarts
                Chip {
                    required property var modelData
                    small: true
                    text: panel.hhmm(modelData)
                    on: panel.start === modelData
                    onClicked: panel.start = modelData
                }
            }
        }
        Label {
            visible: panel.cloud.bookStarts.length > 0
            color: "#88ffffff"; font.pixelSize: 12
            text: qsTr("Час — за годинником твого комп'ютера.")
        }

        Label { visible: panel.methods.length > 1; text: qsTr("4. Оплата"); color: "#22e4ff"; font.pixelSize: 13; font.bold: true; font.letterSpacing: 2; Layout.topMargin: 4 }
        Flow {
            Layout.fillWidth: true
            visible: panel.methods.length > 1
            spacing: 8
            Repeater {
                model: panel.methods
                Chip {
                    required property var modelData
                    text: modelData.label
                    on: panel.curMethod === modelData.code
                    onClicked: panel.method = modelData.code
                }
            }
        }

        Button {
            Layout.fillWidth: true
            Layout.preferredHeight: 58
            Layout.topMargin: 6
            enabled: panel.start > 0 && !!panel.tariff && !panel.cloud.busy
            font.pixelSize: 19; font.bold: true
            text: panel.start > 0 && panel.tariff
                ? qsTr("Забронювати %1–%2 · %3").arg(panel.hhmm(panel.start)).arg(panel.hhmm(panel.start + panel.tariff.hours * 3600)).arg(panel.tariff.prices[panel.curMethod] || "")
                : qsTr("Обери час початку")
            onClicked: panel.cloud.book(panel.start, panel.code, panel.curMethod)
            contentItem: Label {
                text: parent.text; font: parent.font
                color: parent.enabled ? "white" : "#88ffffff"
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                radius: 16
                opacity: parent.enabled ? 1 : 0.4
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#ff9a3c" }
                    GradientStop { position: 0.5; color: "#ff2e9a" }
                    GradientStop { position: 1.0; color: "#7b2cff" }
                }
            }
        }
        Button {
            visible: !!panel.payItem
            flat: true
            text: qsTr("← Назад до оплати")
            onClicked: panel.choosing = false
        }
    }

    Label {
        Layout.fillWidth: true
        visible: panel.status !== ""
        wrapMode: Text.WordWrap
        font.pixelSize: 15
        color: panel.statusOk ? "#3dff9a" : "#ff4d6d"
        text: panel.status
    }

    // ───────── мої броні ─────────
    ColumnLayout {
        Layout.fillWidth: true
        visible: panel.mine.length > 0
        spacing: 6
        Label { text: qsTr("Мої броні"); color: "white"; font.pixelSize: 17; font.bold: true; Layout.topMargin: 6 }
        Repeater {
            model: panel.mine
            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: "white"; font.pixelSize: 15
                    text: qsTr("%1 · %2 · %3").arg(panel.rangeText(modelData.start, modelData.end)).arg(modelData.title).arg(modelData.price)
                }
                Label {
                    font.pixelSize: 14
                    color: modelData.status === "hold" ? "#ffd23f" : (modelData.status === "pending_review" ? "#22e4ff" : "#3dff9a")
                    text: panel.statusText(modelData.status)
                }
            }
        }
        Button {
            visible: panel.showPay && (panel.info.openCount || 0) < (panel.info.limit || 1)
            flat: true
            text: qsTr("+ Забронювати ще час")
            onClicked: panel.choosing = true
        }
    }

    component Chip: Rectangle {
        id: chip
        property string text
        property string sub: ""
        property bool on: false
        property bool small: false
        signal clicked()
        implicitWidth: chipCol.implicitWidth + (small ? 22 : 30)
        implicitHeight: chipCol.implicitHeight + (small ? 14 : 18)
        radius: 12
        color: on ? "#3a1a6e" : (chipMouse.containsMouse ? "#2a1650" : "#1f1240")
        border.color: on ? "#22e4ff" : "#22ffffff"
        border.width: on ? 2 : 1
        ColumnLayout {
            id: chipCol
            anchors.centerIn: parent
            spacing: 0
            Label { Layout.alignment: Qt.AlignHCenter; text: chip.text; color: "white"; font.pixelSize: chip.small ? 15 : 16; font.bold: true }
            Label { Layout.alignment: Qt.AlignHCenter; visible: chip.sub !== ""; text: chip.sub; color: "#ffe7f6"; font.pixelSize: 12 }
        }
        MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
    }
}
