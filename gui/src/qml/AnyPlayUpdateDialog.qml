// AnyPlay: вікно оновлення програми (Windows і Mac).
// Показується саме, коли вийшла нова версія, але ніколи під час гри: лише після неї.
// Оновити → завантаження з прогресом → перевірка файлу → встановлення, і AnyPlay відкривається сам.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Item {
    id: dlg
    property var updater: Chiaki.updater
    readonly property string phase: updater ? updater.phase : "idle"
    readonly property bool busy: phase === "downloading" || phase === "verifying" || phase === "installing"
    // «Пізніше» і хрестик: лише коли оновлення не обов'язкове і нічого не відбувається
    readonly property bool canClose: !!updater && !busy && !updater.mandatory
    visible: !!updater && updater.prompt
    z: 550

    // ── кольори бренду (як на головному екрані) ──
    readonly property color cPink: "#ff2e9a"
    readonly property color cSun: "#ffd23f"
    readonly property color cCyan: "#22e4ff"
    readonly property color cDim: "#bfaed8"
    readonly property color cRed: "#ff6b81"

    // Esc із головного екрана
    function escape() { if (canClose) updater.later(); }

    function mb(bytes) { return Math.max(0, Math.round(bytes / 1048576)); }
    function speedText(bps) { return (Math.max(0, bps) / 1048576).toFixed(1).replace(".", ","); }

    // затемнення: кліки й прокрутка не проходять на головний екран
    Rectangle { anchors.fill: parent; color: "#c8080312" }
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        preventStealing: true
        onWheel: (wheel) => { wheel.accepted = true; }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.max(280, Math.min(dlg.width - 60, 600))
        height: Math.min(dlg.height - 40, col.implicitHeight + 64)
        radius: 24
        color: "#160d2b"
        border.color: dlg.updater && dlg.updater.mandatory ? dlg.cPink : "#44ffffff"
        border.width: dlg.updater && dlg.updater.mandatory ? 2 : 1
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        Rectangle {   // хрестик
            visible: dlg.canClose
            anchors { top: parent.top; right: parent.right; margins: 10 }
            width: 34; height: 34; radius: 17
            color: closeArea.containsMouse ? "#33ffffff" : "#18ffffff"
            Label { anchors.centerIn: parent; text: "✕"; color: "white"; font.pixelSize: 15; font.bold: true }
            MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.updater.later() }
        }

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 32 }
            spacing: 14

            Label {
                Layout.fillWidth: true
                font.pixelSize: 13; font.bold: true; font.letterSpacing: 2
                color: dlg.phase === "error" ? dlg.cRed : dlg.cCyan
                text: dlg.phase === "error" ? qsTr("ОНОВЛЕННЯ ANYPLAY") : qsTr("ВИЙШЛА НОВА ВЕРСІЯ")
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 28; font.bold: true
                color: "white"
                text: dlg.updater && dlg.updater.build > 0 ? qsTr("Доступна версія %1").arg(dlg.updater.build) : qsTr("Оновлення AnyPlay")
            }

            // ── пропозиція оновитись ──
            Label {
                visible: dlg.phase === "idle"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 16; color: dlg.cDim
                text: dlg.updater && dlg.updater.needsMove
                    ? qsTr("AnyPlay зараз запущено не з папки «Програми», тому оновитись сам він не може. Перенесемо його туди, це кілька секунд, і він відкриється знову. Вхід і броні збережуться.")
                    : qsTr("Щоб встановити оновлення, ми ненадовго закриємо AnyPlay і відкриємо знову. Вхід і броні збережуться.")
            }
            Rectangle {   // «Що нового»
                visible: dlg.phase === "idle" && !!dlg.updater && dlg.updater.notes !== ""
                Layout.fillWidth: true
                implicitHeight: notesLabel.implicitHeight + 24
                radius: 14
                color: "#1f1240"
                border.color: "#22ffffff"
                Label {
                    id: notesLabel
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                    wrapMode: Text.WordWrap
                    font.pixelSize: 15; color: "white"
                    text: qsTr("Що нового: %1").arg(dlg.updater ? dlg.updater.notes : "")
                }
            }
            Label {
                visible: dlg.phase === "idle" && !!dlg.updater && dlg.updater.mandatory
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 16; font.bold: true; color: dlg.cSun
                text: qsTr("Без цього оновлення грати не вийде.")
            }

            // ── завантаження, перевірка, встановлення ──
            Label {
                visible: dlg.busy
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 18; font.bold: true; color: "white"
                text: {
                    const u = dlg.updater;
                    if (!u) return "";
                    switch (dlg.phase) {
                    case "downloading":
                        return u.total > 0
                            ? qsTr("Завантаження… %1 з %2 МБ, %3 МБ/с").arg(dlg.mb(u.received)).arg(dlg.mb(u.total)).arg(dlg.speedText(u.speed))
                            : qsTr("Завантаження…");
                    case "verifying": return qsTr("Перевіряємо файл…");
                    case "installing": return u.moving ? qsTr("Переносимо в «Програми», AnyPlay відкриється сам") : qsTr("Встановлюємо, AnyPlay відкриється сам");
                    default: return "";
                    }
                }
            }
            Rectangle {   // смуга прогресу
                id: bar
                visible: dlg.busy
                Layout.fillWidth: true
                implicitHeight: 12
                radius: 6
                color: "#26ffffff"
                clip: true
                readonly property bool exact: dlg.phase === "downloading" && !!dlg.updater && dlg.updater.total > 0
                readonly property real value: exact ? Math.min(1, dlg.updater.received / dlg.updater.total) : 1
                property real slide
                // без точних чисел (перевірка, встановлення) смуга просто біжить
                NumberAnimation on slide {
                    running: dlg.visible && !bar.exact
                    loops: Animation.Infinite
                    from: -0.3; to: 1
                    duration: 1300
                    easing.type: Easing.InOutQuad
                }
                Rectangle {
                    height: parent.height
                    radius: 6
                    width: bar.exact ? parent.width * bar.value : parent.width * 0.3
                    x: bar.exact ? 0 : parent.width * bar.slide
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#ff9a3c" }
                        GradientStop { position: 0.5; color: "#ff2e9a" }
                        GradientStop { position: 1.0; color: "#7b2cff" }
                    }
                }
            }

            // ── помилка ──
            Label {
                visible: dlg.phase === "error"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 17; font.bold: true; color: "white"
                text: dlg.updater ? dlg.updater.error : ""
            }
            Label {
                visible: dlg.phase === "error" && !!dlg.updater && dlg.updater.mandatory
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 15; color: dlg.cSun
                text: qsTr("Без цього оновлення грати не вийде.")
            }

            Item { Layout.preferredHeight: 4 }

            // ── кнопки ──
            Flow {
                Layout.fillWidth: true
                spacing: 12
                layoutDirection: Qt.LeftToRight

                UpdateButton {   // головна дія
                    visible: dlg.phase === "idle" || dlg.phase === "error"
                    primary: true
                    text: {
                        const u = dlg.updater;
                        if (dlg.phase === "error")
                            return u && u.revealPath !== "" ? qsTr("Показати нову версію") : qsTr("Спробувати ще раз");
                        return u && u.needsMove ? qsTr("Перенести в Програми") : qsTr("Оновити");
                    }
                    onClicked: {
                        const u = dlg.updater;
                        if (dlg.phase === "error" && u.revealPath !== "")
                            u.revealNew();
                        else
                            u.start();
                    }
                }
                UpdateButton {
                    visible: dlg.phase === "error"
                    text: qsTr("Завантажити вручну")
                    onClicked: dlg.updater.openManual()
                }
                UpdateButton {
                    visible: dlg.phase === "downloading"
                    text: qsTr("Скасувати")
                    onClicked: dlg.updater.cancel()
                }
                UpdateButton {
                    visible: dlg.canClose
                    flat: true
                    text: qsTr("Пізніше")
                    onClicked: dlg.updater.later()
                }
            }
        }
    }

    // кнопка в стилі головного екрана AnyPlay
    component UpdateButton: Button {
        id: ub
        property bool primary: false
        focusPolicy: Qt.NoFocus
        font.bold: true
        font.pixelSize: primary ? 18 : 16
        padding: 14
        leftPadding: 26; rightPadding: 26
        contentItem: Label {
            text: ub.text; font: ub.font
            color: ub.enabled ? "white" : "#88ffffff"
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            implicitHeight: 52
            radius: ub.primary ? 18 : 14
            opacity: ub.enabled ? (ub.down ? 0.8 : 1) : 0.45
            color: ub.flat ? (ub.hovered ? "#22ffffff" : "transparent") : "#26ffffff"
            border.color: ub.flat ? "transparent" : "#22ffffff"
            gradient: ub.primary ? ubGradient : null
            Gradient {
                id: ubGradient
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#ff9a3c" }
                GradientStop { position: 0.5; color: "#ff2e9a" }
                GradientStop { position: 1.0; color: "#7b2cff" }
            }
        }
    }
}
