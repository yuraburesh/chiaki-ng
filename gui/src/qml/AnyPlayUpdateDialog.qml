// AnyPlay: вікно оновлення програми (Windows і Mac).
// Показується саме, коли вийшла нова версія, але ніколи під час гри: лише після неї.
// Оновити → завантаження з прогресом → перевірка файлу → встановлення, і AnyPlay відкривається сам.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

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

    AnyPlayStyle { id: ap }

    // Esc із головного екрана
    function closeByEscape() { if (canClose) updater.later(); }   // (не «escape»: так зветься вбудована функція JS, старіші Qt не дозволяють)

    function mb(bytes) { return Math.max(0, Math.round(bytes / 1048576)); }
    function speedText(bps) { return (Math.max(0, bps) / 1048576).toFixed(1).replace(".", ","); }

    // затемнення: кліки й прокрутка не проходять на головний екран
    Rectangle { anchors.fill: parent; color: ap.veil }
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
        width: Math.max(280, Math.min(dlg.width - 40, 600))
        height: Math.min(dlg.height - 40, col.implicitHeight + 64)
        radius: 4
        color: ap.dialog
        border.color: dlg.updater && dlg.updater.mandatory ? "#80ffd9a0" : ap.edge
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        Rectangle {   // хрестик
            visible: dlg.canClose
            anchors { top: parent.top; right: parent.right; margins: 10 }
            width: 28; height: 28
            radius: ap.radius
            color: closeArea.containsMouse ? "#22ffffff" : "transparent"
            border.color: closeArea.containsMouse ? ap.edge : "transparent"
            Text { anchors.centerIn: parent; text: "✕"; color: ap.ink; font.family: ap.body; font.pixelSize: 14 }
            MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.updater.later() }
        }

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 32 }
            spacing: 12

            ApText {
                Layout.fillWidth: true
                role: "eyebrow"
                color: dlg.phase === "error" ? ap.bad : ap.cyan
                text: dlg.phase === "error" ? qsTr("Оновлення AnyPlay") : qsTr("Вийшла нова версія")
            }
            ApText {
                Layout.fillWidth: true
                role: "h2"
                text: dlg.updater && dlg.updater.build > 0 ? qsTr("Доступна версія %1").arg(dlg.updater.build) : qsTr("Оновлення AnyPlay")
            }

            // ── пропозиція оновитись ──
            ApText {
                visible: dlg.phase === "idle"
                Layout.fillWidth: true
                role: "lead"
                text: dlg.updater && dlg.updater.needsMove
                    ? qsTr("AnyPlay зараз запущено не з папки «Програми», тому оновитись сам він не може. Перенесемо його туди, це кілька секунд, і він відкриється знову. Вхід і броні збережуться.")
                    : qsTr("Щоб встановити оновлення, ми ненадовго закриємо AnyPlay і відкриємо знову. Вхід і броні збережуться.")
            }
            ColumnLayout {   // «Що нового»
                visible: dlg.phase === "idle" && !!dlg.updater && dlg.updater.notes !== ""
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 4
                ApText { role: "cap"; text: qsTr("Що нового") }
                ApText { Layout.fillWidth: true; text: dlg.updater ? dlg.updater.notes : "" }
            }
            ApText {
                visible: dlg.phase === "idle" && !!dlg.updater && dlg.updater.mandatory
                Layout.fillWidth: true
                font.weight: Font.DemiBold
                color: ap.gold
                text: qsTr("Без цього оновлення грати не вийде.")
            }

            // ── завантаження, перевірка, встановлення ──
            ApText {
                visible: dlg.busy
                Layout.fillWidth: true
                font.weight: Font.Medium
                font.pixelSize: 16
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
                implicitHeight: 3
                color: ap.hair
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
                    width: bar.exact ? parent.width * bar.value : parent.width * 0.3
                    x: bar.exact ? 0 : parent.width * bar.slide
                    color: ap.ink
                }
            }

            // ── помилка ──
            ApText {
                visible: dlg.phase === "error"
                Layout.fillWidth: true
                font.weight: Font.Medium
                font.pixelSize: 16
                text: dlg.updater ? dlg.updater.error : ""
            }
            ApText {
                visible: dlg.phase === "error" && !!dlg.updater && dlg.updater.mandatory
                Layout.fillWidth: true
                color: ap.gold
                text: qsTr("Без цього оновлення грати не вийде.")
            }

            Item { Layout.preferredHeight: 6 }

            // ── кнопки ──
            Flow {
                Layout.fillWidth: true
                spacing: 10

                ApButton {   // головна дія
                    id: mainBtn
                    visible: dlg.phase === "idle" || dlg.phase === "error"
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
                ApButton {
                    visible: dlg.phase === "error"
                    ghost: true
                    height: mainBtn.visible ? mainBtn.height : implicitHeight
                    text: qsTr("Завантажити вручну")
                    onClicked: dlg.updater.openManual()
                }
                ApButton {
                    visible: dlg.phase === "downloading"
                    ghost: true
                    text: qsTr("Скасувати")
                    onClicked: dlg.updater.cancel()
                }
                ApButton {
                    visible: dlg.canClose
                    ghost: true
                    height: mainBtn.visible ? mainBtn.height : implicitHeight
                    text: qsTr("Пізніше")
                    onClicked: dlg.updater.later()
                }
            }
        }
    }
}
