// AnyPlay: вхід у PSN (або реєстрація) через звичайний браузер — три зрозумілі кроки.
// Пароль вводиться лише на сайті Sony. Програма сама підхоплює адресу сторінки «redirect» з буфера обміну.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

DialogView {
    id: dialog
    property bool create: false          // true — клієнт ще не має акаунта PSN
    property string phase: "wait"        // wait | check | ok | error
    property string errorText: ""
    property string lastClip: ""
    readonly property string copyKey: Qt.platform.os === "osx" ? "Cmd+C" : "Ctrl+C"
    readonly property string pasteKey: Qt.platform.os === "osx" ? "Cmd+V" : "Ctrl+V"
    title: create ? qsTr("Реєстрація й вхід у PSN") : qsTr("Вхід у PSN")
    buttonVisible: false

    function openSony() { Chiaki.openPsnLink(); }
    function submit(text) {
        const t = String(text || "").trim();
        if (!t || phase === "check" || phase === "ok")
            return;
        if (!Chiaki.checkPsnRedirectURL(t)) {
            phase = "error";
            errorText = qsTr("Це не та адреса. Потрібна адреса сторінки, на якій написано лише слово «redirect» — вона починається з https://remoteplay.dl.playstation.net/…");
            return;
        }
        phase = "check";
        errorText = "";
        Chiaki.initPsnAuth(t, function(msg, ok, done) {
            if (!done)
                return;
            if (ok) {
                dialog.phase = "ok";
                okTimer.start();
            } else {
                dialog.phase = "error";
                dialog.errorText = qsTr("Sony не прийняла цей код — він одноразовий і діє лише кілька хвилин. Натисни «Відкрити сторінку Sony» і скопіюй адресу ще раз.");
                urlField.text = "";
            }
        });
    }

    StackView.onActivated: {
        // адресу, яка вже лежала в буфері (від минулого входу), не чіпаємо — чекаємо на нову
        lastClip = Chiaki.clipboardText();
        openSony();
    }

    // (DialogView приймає лише один вкладений елемент, тому таймери — властивостями)
    property Timer clipWatch: Timer {
        interval: 600; repeat: true
        running: dialog.phase === "wait" || dialog.phase === "error"
        onTriggered: {
            const t = Chiaki.clipboardText();
            if (!t || t === dialog.lastClip)
                return;
            dialog.lastClip = t;
            if (Chiaki.checkPsnRedirectURL(t)) {
                urlField.text = t;
                dialog.submit(t);
            }
        }
    }
    property Timer okTimer: Timer { interval: 1200; onTriggered: { Chiaki.settings.remotePlayAsk = false; root.showMainView(); } }

    Item {
        Flickable {
            anchors.fill: parent
            contentHeight: col.implicitHeight + 60
            clip: true
            ColumnLayout {
                id: col
                anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 30 }
                width: Math.min(parent.width - 60, 720)
                spacing: 14

                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    color: "#bfaed8"; font.pixelSize: 15
                    text: qsTr("🔒 Пароль ти вводиш лише на офіційному сайті Sony у своєму браузері — ні програма, ні ми його не бачимо.")
                }

                StepCard {
                    num: "1"
                    title: dialog.create ? qsTr("Створи акаунт на сайті Sony") : qsTr("Увійди на сайті Sony")
                    text: dialog.create
                        ? qsTr("У браузері відкрилась сторінка Sony. Натисни внизу «Create New Account» і пройди реєстрацію (2–3 хвилини, безкоштовно). Наприкінці Sony сама продовжить вхід.")
                        : qsTr("У браузері відкрилась сторінка Sony — введи пошту й пароль свого акаунта PSN.")
                    Button {
                        text: qsTr("Відкрити сторінку Sony ще раз ↗")
                        onClicked: dialog.openSony()
                    }
                }
                StepCard {
                    num: "2"
                    title: qsTr("Скопіюй адресу сторінки «redirect»")
                    text: qsTr("Після входу відкриється майже порожня біла сторінка з одним словом «redirect» — так і має бути. Клацни по адресному рядку браузера вгорі й натисни %1.").arg(dialog.copyKey)
                }
                StepCard {
                    num: "3"
                    title: qsTr("Повернись у це вікно")
                    text: qsTr("Програма сама підхопить скопійовану адресу. Якщо ні — встав її в поле нижче (%1).").arg(dialog.pasteKey)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        TextField {
                            id: urlField
                            Layout.fillWidth: true
                            placeholderText: qsTr("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…")
                            font.pixelSize: 14
                            enabled: dialog.phase !== "check" && dialog.phase !== "ok"
                            onTextEdited: if (Chiaki.checkPsnRedirectURL(text.trim())) dialog.submit(text)
                            onAccepted: dialog.submit(text)
                        }
                        Button {
                            text: qsTr("Вставити")
                            enabled: dialog.phase !== "check" && dialog.phase !== "ok"
                            onClicked: { const t = Chiaki.clipboardText(); urlField.text = t; dialog.lastClip = t; dialog.submit(t); }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: 14
                    implicitHeight: stateLabel.implicitHeight + 28
                    color: dialog.phase === "ok" ? "#143d2a" : (dialog.phase === "error" ? "#3d1420" : "#1f1240")
                    border.color: dialog.phase === "ok" ? "#3dff9a" : (dialog.phase === "error" ? "#ff4d6d" : "#33ffffff")
                    Label {
                        id: stateLabel
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                        wrapMode: Text.WordWrap
                        font.pixelSize: 16; font.bold: true
                        color: "white"
                        text: dialog.phase === "ok" ? qsTr("✅ Вхід у PSN виконано! Повертаємось…")
                            : dialog.phase === "check" ? qsTr("⏳ Перевіряємо вхід у Sony…")
                            : dialog.phase === "error" ? dialog.errorText
                            : qsTr("⏳ Чекаємо, поки ти увійдеш у браузері й скопіюєш адресу…")
                    }
                }
            }
        }
    }

    component StepCard: Rectangle {
        id: sc
        property string num
        property string title
        property string text
        default property alias extra: scExtra.data
        Layout.fillWidth: true
        radius: 16
        color: "#160d2b"
        border.color: "#33ffffff"
        implicitHeight: scRow.implicitHeight + 28
        RowLayout {
            id: scRow
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 14
            Rectangle {
                Layout.alignment: Qt.AlignTop
                width: 36; height: 36; radius: 18
                color: "#ff2e9a"
                Label { anchors.centerIn: parent; text: sc.num; color: "white"; font.bold: true; font.pixelSize: 17 }
            }
            ColumnLayout {
                id: scExtra
                Layout.fillWidth: true
                spacing: 8
                Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: sc.title; color: "white"; font.pixelSize: 18; font.bold: true }
                Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: sc.text; color: "#d8cdea"; font.pixelSize: 15 }
            }
        }
    }
}
