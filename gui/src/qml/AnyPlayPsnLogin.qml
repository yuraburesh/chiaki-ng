// AnyPlay: вхід у PSN (або реєстрація) через звичайний браузер.
// Пароль вводиться лише на сайті Sony. Після входу Sony показує сторінку «redirect» — програма сама
// бере її адресу з браузера (macOS, Windows); запасний шлях — скопіювати адресу, її теж підхопимо самі.
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
    property bool manual: false          // показати ручний спосіб (копіювання адреси)
    property bool autoDenied: false      // система не дозволила програмі читати адресу з браузера
    property int waited: 0               // секунд у стані очікування
    readonly property bool auto: Chiaki.psnRedirectAuto() && !autoDenied
    readonly property var browsers: Chiaki.psnBrowsers()
    readonly property string copyKey: Qt.platform.os === "osx" ? "Cmd+C" : "Ctrl+C"
    readonly property string pasteKey: Qt.platform.os === "osx" ? "Cmd+V" : "Ctrl+V"
    title: create ? qsTr("Реєстрація й вхід у PSN") : qsTr("Вхід у PSN")
    buttonVisible: false

    function openSony(browser) { Chiaki.openPsnPage(dialog.create, browser || ""); }
    function openLogin() { Chiaki.openPsnPage(false, ""); }   // акаунт уже створено — лишився вхід
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
                dialog.errorText = qsTr("Sony не прийняла цей вхід: код одноразовий і діє лише кілька хвилин. Натисни «Відкрити сторінку Sony ще раз» і увійди знову.");
                urlField.text = "";
                Chiaki.watchPsnRedirect(true);
            }
        });
    }

    StackView.onActivated: {
        // адресу, яка вже лежала в буфері (від минулого входу), не чіпаємо — чекаємо на нову
        lastClip = Chiaki.clipboardText();
        openSony();
        Chiaki.watchPsnRedirect(true);
    }
    StackView.onDeactivated: Chiaki.watchPsnRedirect(false)
    Component.onDestruction: Chiaki.watchPsnRedirect(false)

    // сторінку «redirect» знайдено в браузері — далі все саме
    property Connections autoPick: Connections {
        target: Chiaki
        function onPsnRedirectFound(url) {
            if (dialog.phase === "check" || dialog.phase === "ok")
                return;
            Chiaki.activateWindow();
            urlField.text = url;
            dialog.lastClip = url;
            dialog.submit(url);
        }
        function onPsnRedirectDeniedChanged() { dialog.autoDenied = Chiaki.psnRedirectDenied(); dialog.manual = true; }
    }
    property Timer waitTick: Timer {
        interval: 1000; repeat: true
        running: dialog.phase === "wait"
        onTriggered: dialog.waited++
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
                        ? qsTr("У браузері відкрилась сторінка реєстрації Sony. Заповни її (2–3 хвилини, безкоштовно) і підтверди пошту. Якщо після реєстрації Sony не продовжила вхід сама, натисни «Акаунт уже створено».")
                        : qsTr("У браузері відкрилась сторінка Sony. Введи пошту й пароль свого акаунта PSN.")
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            text: qsTr("Відкрити сторінку Sony ще раз ↗")
                            onClicked: dialog.openSony()
                        }
                        Button {
                            visible: dialog.create
                            text: qsTr("Акаунт уже створено — увійти")
                            onClicked: dialog.openLogin()
                        }
                    }
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        color: "#bfaed8"; font.pixelSize: 13
                        text: qsTr("Сторінка порожня або не відкривається? Спробуй інший браузер або скопіюй посилання й відкрий його сам.")
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: dialog.browsers
                            Button {
                                required property string modelData
                                flat: true
                                text: modelData
                                onClicked: dialog.openSony(modelData)
                            }
                        }
                        Button {
                            flat: true
                            text: qsTr("Скопіювати посилання")
                            onClicked: {
                                const link = Chiaki.psnPageUrl(dialog.create);
                                dialog.lastClip = link;
                                Chiaki.cloud.copyText(link);
                            }
                        }
                    }
                }
                StepCard {
                    num: "2"
                    visible: dialog.auto
                    title: qsTr("Більше нічого робити не треба")
                    text: Qt.platform.os === "osx"
                        ? qsTr("Після входу з'явиться майже порожня сторінка з одним словом «redirect» — так і має бути. Програма сама це помітить і продовжить. Якщо Mac спитає, чи дозволити AnyPlay доступ до браузера, натисни «Дозволити»: програма читає лише адресу цієї сторінки.")
                        : qsTr("Після входу з'явиться майже порожня сторінка з одним словом «redirect» — так і має бути. Програма сама це помітить і продовжить.")
                    Button {
                        flat: true
                        visible: !dialog.manual
                        text: qsTr("Не спрацювало? Вставити адресу вручну")
                        onClicked: dialog.manual = true
                    }
                }
                StepCard {
                    num: dialog.auto ? "3" : "2"
                    visible: !dialog.auto || dialog.manual || dialog.waited >= 90 || dialog.phase === "error"
                    title: dialog.auto ? qsTr("Запасний спосіб: скопіюй адресу сторінки «redirect»") : qsTr("Скопіюй адресу сторінки «redirect»")
                    text: qsTr("На сторінці зі словом «redirect» клацни по адресному рядку браузера вгорі й натисни %1. Потім повернись у це вікно: програма сама підхопить скопійовану адресу. Якщо ні, встав її в поле нижче (%2).").arg(dialog.copyKey).arg(dialog.pasteKey)
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
                            : dialog.auto ? qsTr("⏳ Чекаємо, поки ти увійдеш у браузері. Далі програма продовжить сама.")
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
