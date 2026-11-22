// AnyPlay: чат з підтримкою просто в програмі (і поверх гри: гра йде далі).
// Повідомлення ті самі, що в боті й у CRM → «Чати»: адмін відповідає звідти, відповідь з'являється тут.
// Угорі «Картинка глючить?»: одним натиском шлемо журнал програми, і адмін бачить скаргу в «здоров'ї» картинки.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs

import org.streetpea.chiaking

Item {
    id: sup
    property var cloud: Chiaki.cloud
    property real contentWidth: width
    property string error: ""
    property bool reported: false
    property var images: ({})        // fileUrl → data:-адреса (фото вантажимо з входом, тож самі)
    property int imagesRev: 0
    AnyPlayStyle { id: ap }

    onVisibleChanged: if (visible) { error = ""; cloud.loadSupport(); }
    Component.onCompleted: if (visible) cloud.loadSupport()

    // поки чат відкритий, нові відповіді приходять самі
    Timer { interval: 4000; repeat: true; running: sup.visible; onTriggered: sup.cloud.loadSupport() }

    Connections {
        target: sup.cloud
        function onSupportResult(ok, text) {
            sup.error = ok ? "" : text;
            if (ok) input.text = "";
        }
        function onSupportImage(fileUrl, dataUrl) {
            const m = sup.images;
            m[fileUrl] = dataUrl;
            sup.images = m;
            sup.imagesRev++;
        }
        function onSupportChanged() {
            if (list.atYEnd || list.count < 3)
                Qt.callLater(() => list.positionViewAtEnd());
        }
    }

    function hhmm(ts) {
        const d = new Date(ts * 1000), t = new Date();
        const p = (n) => String(n).padStart(2, "0");
        const time = p(d.getHours()) + ":" + p(d.getMinutes());
        if (d.toDateString() === t.toDateString())
            return time;
        return d.getDate() + "." + p(d.getMonth() + 1) + ", " + time;
    }
    function send() {
        const t = input.text.trim();
        if (!t || sup.cloud.supportSending)
            return;
        sup.cloud.sendSupport(t);
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        width: sup.contentWidth
        height: parent.height
        spacing: 10

        ApText { role: "eyebrow"; text: qsTr("Підтримка"); Layout.topMargin: 8 }
        ApText {
            Layout.fillWidth: true
            role: "lead"
            text: sup.cloud.supportHours
                ? qsTr("Пиши прямо звідси, гра не зупиняється. Відповідаємо %1, відповідь з'явиться тут і в боті.").arg(sup.cloud.supportHours)
                : qsTr("Пиши прямо звідси, гра не зупиняється. Відповідь з'явиться тут і в боті.")
        }

        // скарга на картинку: журнал програми + позначка для адміна
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                ApText { role: "title"; text: qsTr("Картинка глючить?") }
                ApText {
                    Layout.fillWidth: true
                    role: "small"
                    text: sup.reported ? qsTr("Надіслано. Ми бачимо, що відбувалось у програмі, і напишемо тобі тут.")
                                       : qsTr("Блимає, гальмує, смикається: натисни, і ми отримаємо технічний журнал програми.")
                }
            }
            ApButton {
                small: true; ghost: true
                enabled: !sup.reported
                text: sup.reported ? qsTr("Надіслано") : qsTr("Надіслати журнал")
                onClicked: { sup.cloud.reportPicture(""); sup.reported = true; }
            }
        }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }

        // повідомлення
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 10
            model: sup.cloud.supportMessages
            boundsBehavior: Flickable.StopAtBounds
            onCountChanged: Qt.callLater(() => list.positionViewAtEnd())
            ScrollBar.vertical: ScrollBar { contentItem: Rectangle { implicitWidth: 4; radius: 2; color: "#55ffffff" } }
            header: Item { width: 1; height: 6 }
            footer: Item {
                width: list.width
                height: typingText.visible ? typingText.implicitHeight + 12 : 6
                ApText {
                    id: typingText
                    visible: sup.cloud.supportTyping
                    y: 6
                    role: "small"
                    text: qsTr("підтримка пише…")
                }
            }
            delegate: Item {
                id: msg
                required property var modelData
                readonly property bool mine: modelData.dir === "in"   // in — від клієнта (тобто від мене)
                readonly property bool photo: modelData.kind === "photo" && !!modelData.fileUrl
                readonly property string img: { sup.imagesRev; return photo ? (sup.images[modelData.fileUrl] || "") : ""; }
                width: list.width
                height: bubble.height
                Component.onCompleted: if (photo && !sup.images[modelData.fileUrl]) sup.cloud.loadSupportImage(modelData.fileUrl)
                Rectangle {
                    id: bubble
                    readonly property real maxW: Math.min(list.width * 0.78, 560)
                    anchors.right: msg.mine ? parent.right : undefined
                    anchors.left: msg.mine ? undefined : parent.left
                    anchors.rightMargin: 8
                    width: Math.max(timeText.implicitWidth + 24, Math.min(maxW, Math.max(bodyText.implicitWidth, msg.photo ? 240 : 0) + 24))
                    height: col.implicitHeight + 16
                    radius: 6
                    color: msg.mine ? "#26ffffff" : "#12ffffff"
                    border.width: msg.mine ? 0 : 1
                    border.color: ap.hair
                    ColumnLayout {
                        id: col
                        x: 12; y: 8
                        width: bubble.width - 24
                        spacing: 6
                        ApText {
                            visible: !msg.mine
                            role: "small"
                            color: ap.cyan
                            text: qsTr("Підтримка AnyPlay")
                        }
                        Image {
                            visible: msg.photo
                            Layout.preferredWidth: 240
                            Layout.preferredHeight: msg.img ? Math.min(320, 240 * implicitHeight / Math.max(1, implicitWidth)) : 60
                            fillMode: Image.PreserveAspectFit
                            source: msg.img
                            asynchronous: true
                            ApText {
                                anchors.centerIn: parent
                                visible: !msg.img
                                role: "small"
                                text: qsTr("фото завантажується…")
                            }
                        }
                        Text {
                            id: bodyText
                            visible: text !== ""
                            Layout.fillWidth: true
                            text: msg.modelData.text || (msg.photo ? "" : msg.modelData.kind && msg.modelData.kind !== "text" ? qsTr("вкладення") : "")
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            font.family: ap.body; font.pixelSize: 14
                            color: ap.ink
                        }
                        Text {
                            id: timeText
                            Layout.alignment: Qt.AlignRight
                            text: sup.hhmm(msg.modelData.ts || 0)
                            font.family: ap.body; font.pixelSize: 11
                            color: ap.faint
                        }
                    }
                }
            }
            ApText {
                anchors.centerIn: parent
                width: Math.min(parent.width, 420)
                horizontalAlignment: Text.AlignHCenter
                visible: list.count === 0
                role: "hint"
                text: !sup.cloud.supportLoaded && !sup.error ? qsTr("Завантажую чат…")
                    : qsTr("Тут поки порожньо. Напиши, що сталося або що хочеш дізнатись.")
            }
        }

        ApText {
            visible: sup.error !== ""
            Layout.fillWidth: true
            role: "small"
            color: ap.bad
            text: sup.error
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 16
            spacing: 10
            ApField {
                id: input
                Layout.fillWidth: true
                placeholderText: qsTr("Повідомлення для підтримки")
                maximumLength: 4000
                Keys.onReturnPressed: sup.send()
                Keys.onEnterPressed: sup.send()
            }
            ApButton {
                ghost: true
                height: input.height
                enabled: !sup.cloud.supportSending
                text: qsTr("Фото")
                onClicked: photoDialog.open()
            }
            ApButton {
                height: input.height
                enabled: input.text.trim() !== "" && !sup.cloud.supportSending
                text: sup.cloud.supportSending ? qsTr("Надсилаю…") : qsTr("Надіслати")
                onClicked: sup.send()
            }
        }
    }

    FileDialog {
        id: photoDialog
        title: qsTr("Фото для підтримки")
        nameFilters: [qsTr("Фото (*.jpg *.jpeg *.png *.webp *.heic)")]
        onAccepted: sup.cloud.sendSupportPhoto(selectedFile)
    }
}
