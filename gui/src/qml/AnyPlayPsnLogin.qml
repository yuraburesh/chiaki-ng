// AnyPlay: вхід у PSN (або реєстрація) через звичайний браузер.
// Пароль вводиться лише на сайті Sony. Після входу Sony показує сторінку «redirect» — програма сама
// бере її адресу з браузера (macOS, Windows); запасний шлях — скопіювати адресу, її теж підхопимо самі.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

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
    anyplay: true   // шапка й фон нового дизайну (DialogView малює їх на все вікно)

    function openSony(browser) { Chiaki.openPsnPage(dialog.create, browser || ""); }
    function openLogin() { Chiaki.openPsnPage(false, ""); }   // акаунт уже створено — лишився вхід
    function submit(text) {
        const t = String(text || "").trim();
        if (!t || phase === "check" || phase === "ok")
            return;
        if (!Chiaki.checkPsnRedirectURL(t)) {
            phase = "error";
            errorText = qsTr("Це не та адреса. Потрібна адреса сторінки, на якій написано лише слово «redirect»: вона починається з https://remoteplay.dl.playstation.net/…");
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
        AnyPlayStyle { id: ap }
        Flickable {
            id: flick
            anchors.fill: parent
            contentHeight: (col.implicitHeight + 60) * dialog.apZoom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" }
            }
            // на великих екранах усе пропорційно більше, як на головному екрані; лівий край — як у шапки
            Item {
                width: flick.width / dialog.apZoom
                height: col.implicitHeight + 60
                scale: dialog.apZoom
                transformOrigin: Item.TopLeft
                ColumnLayout {
                    id: col
                    x: dialog.apPadX
                    y: 28
                    width: Math.min(parent.width - 2 * dialog.apPadX, 760)
                    spacing: 0

                    ApText { role: "h2"; text: dialog.create ? qsTr("Реєстрація в PSN") : qsTr("Вхід у PSN") }
                    ApText {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.bottomMargin: 14
                        role: "hint"
                        text: qsTr("Пароль ти вводиш лише на офіційному сайті Sony у своєму браузері. Ні програма, ні ми його не бачимо.")
                    }

                    StepRow {
                        num: "1"
                        title: dialog.create ? qsTr("Створи акаунт на сайті Sony") : qsTr("Увійди на сайті Sony")
                        text: dialog.create
                            ? qsTr("У браузері відкрилась сторінка реєстрації Sony. Заповни її (2–3 хвилини, безкоштовно) і підтверди пошту. Якщо після реєстрації Sony не продовжила вхід сама, натисни «Акаунт уже створено».")
                            : qsTr("У браузері відкрилась сторінка Sony. Введи пошту й пароль свого акаунта PSN.")
                        Flow {
                            width: parent.width
                            spacing: 8
                            ApButton { small: true; text: qsTr("Відкрити сторінку Sony ще раз ↗"); onClicked: dialog.openSony() }
                            ApButton { small: true; ghost: true; visible: dialog.create; text: qsTr("Акаунт уже створено, увійти"); onClicked: dialog.openLogin() }
                        }
                        ApText {
                            width: parent.width
                            role: "small"
                            text: qsTr("Сторінка порожня або не відкривається? Спробуй інший браузер або скопіюй посилання й відкрий його сам.")
                        }
                        Flow {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: dialog.browsers
                                ApButton {
                                    required property string modelData
                                    small: true; ghost: true
                                    font.family: ap.body; font.capitalization: Font.MixedCase; font.letterSpacing: 0
                                    text: modelData
                                    onClicked: dialog.openSony(modelData)
                                }
                            }
                            ApButton {
                                small: true; ghost: true
                                font.family: ap.body; font.capitalization: Font.MixedCase; font.letterSpacing: 0
                                text: qsTr("Скопіювати посилання")
                                onClicked: {
                                    const link = Chiaki.psnPageUrl(dialog.create);
                                    dialog.lastClip = link;
                                    Chiaki.cloud.copyText(link);
                                }
                            }
                        }
                    }
                    StepRow {
                        num: "2"
                        visible: dialog.auto
                        title: qsTr("Більше нічого робити не треба")
                        text: Qt.platform.os === "osx"
                            ? qsTr("Після входу з'явиться майже порожня сторінка з одним словом «redirect», так і має бути. Програма сама це помітить і продовжить. Якщо Mac спитає, чи дозволити AnyPlay доступ до браузера, натисни «Дозволити»: програма читає лише адресу цієї сторінки.")
                            : qsTr("Після входу з'явиться майже порожня сторінка з одним словом «redirect», так і має бути. Програма сама це помітить і продовжить.")
                        ApButton {
                            small: true; ghost: true
                            visible: !dialog.manual
                            text: qsTr("Не спрацювало? Вставити адресу вручну")
                            onClicked: dialog.manual = true
                        }
                    }
                    StepRow {
                        num: dialog.auto ? "3" : "2"
                        visible: !dialog.auto || dialog.manual || dialog.waited >= 90 || dialog.phase === "error"
                        title: dialog.auto ? qsTr("Запасний спосіб: скопіюй адресу сторінки «redirect»") : qsTr("Скопіюй адресу сторінки «redirect»")
                        text: qsTr("На сторінці зі словом «redirect» клацни по адресному рядку браузера вгорі й натисни %1. Потім повернись у це вікно: програма сама підхопить скопійовану адресу. Якщо ні, встав її в поле нижче (%2).").arg(dialog.copyKey).arg(dialog.pasteKey)
                        RowLayout {
                            width: parent.width
                            spacing: 10
                            ApField {
                                id: urlField
                                Layout.fillWidth: true
                                placeholderText: qsTr("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…")
                                enabled: dialog.phase !== "check" && dialog.phase !== "ok"
                                onTextEdited: if (Chiaki.checkPsnRedirectURL(text.trim())) dialog.submit(text)
                                onAccepted: dialog.submit(text)
                            }
                            ApButton {
                                small: true
                                Layout.preferredHeight: urlField.implicitHeight   // одна висота з полем поруч
                                text: qsTr("Вставити")
                                enabled: dialog.phase !== "check" && dialog.phase !== "ok"
                                onClicked: { const t = Chiaki.clipboardText(); urlField.text = t; dialog.lastClip = t; dialog.submit(t); }
                            }
                        }
                    }

                    // ── стан: чекаємо / перевіряємо / готово / помилка ──
                    Rectangle {
                        id: stateBox
                        readonly property color tone: dialog.phase === "ok" ? ap.ok : (dialog.phase === "error" ? ap.bad : ap.cyan)
                        Layout.fillWidth: true
                        Layout.topMargin: 22
                        implicitHeight: stateLabel.implicitHeight + 24
                        radius: ap.radius
                        color: "#0dffffff"
                        border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.55)
                        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 3; color: stateBox.tone }
                        ApText {
                            id: stateLabel
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 14 }
                            font.weight: Font.Medium
                            font.pixelSize: 15
                            color: dialog.phase === "ok" ? ap.ok : (dialog.phase === "error" ? ap.bad : ap.ink)
                            text: dialog.phase === "ok" ? qsTr("✓ Вхід у PSN виконано! Повертаємось…")
                                : dialog.phase === "check" ? qsTr("Перевіряємо вхід у Sony…")
                                : dialog.phase === "error" ? dialog.errorText
                                : dialog.auto ? qsTr("Чекаємо, поки ти увійдеш у браузері. Далі програма продовжить сама.")
                                : qsTr("Чекаємо, поки ти увійдеш у браузері й скопіюєш адресу…")
                        }
                    }
                }
            }
        }
    }

    // крок: номер ліворуч, назва, пояснення і кнопки; тонка лінія знизу
    component StepRow: Item {
        id: sc
        property string num
        property string title
        property string text
        default property alias extra: scExtra.data
        Layout.fillWidth: true
        implicitHeight: scRow.implicitHeight + 32
        AnyPlayStyle { id: sap }
        RowLayout {
            id: scRow
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 16 }
            spacing: 18
            Text {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: 28
                text: sc.num
                font.family: sap.display; font.weight: Font.Medium; font.pixelSize: 30
                color: sap.cyan
            }
            Column {   // звичайний стовпець: висота сама стежить за текстом, що переноситься, і кнопками
                id: scExtra
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 8
                ApText { width: parent.width; font.weight: Font.DemiBold; font.pixelSize: 16; text: sc.title }
                ApText { width: parent.width; role: "lead"; text: sc.text }
            }
        }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: sap.hair }
    }
}
