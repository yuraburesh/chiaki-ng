// AnyPlay: маленьке вікно в панелі адміна з тим, що зараз бачить клієнт.
// Поки це вікно відкрите, сервер просить програму клієнта надсилати зменшений кадр раз на ~1,5 с
// (з затримкою кілька секунд і простою якістю; на саму гру клієнта це не впливає).
// Перший кадр з'являється, коли програма клієнта наступного разу озветься до сервера (до 20 с).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: pv
    property var cloud: Chiaki.cloud
    property var bookingId: 0
    property bool watching: false
    property bool big: false
    property int tick: 0
    spacing: 8
    AnyPlayStyle { id: ap }

    readonly property bool fresh: cloud.previewAt > 0 && (Date.now() / 1000 + cloud.clockSkew) - cloud.previewAt < 12

    onBookingIdChanged: { cloud.clearPreview(); watching = false; big = false; }
    onVisibleChanged: if (!visible) watching = false

    Timer {
        interval: 1500; repeat: true; triggeredOnStart: true
        running: pv.visible && pv.watching && pv.bookingId > 0
        onTriggered: { pv.tick++; pv.cloud.loadPreview(pv.bookingId); }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 10
        ApText { role: "cap"; text: qsTr("Екран клієнта") }
        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
        ApButton {
            small: true; ghost: true
            text: pv.watching ? qsTr("Сховати") : qsTr("Дивитись")
            onClicked: { pv.watching = !pv.watching; if (!pv.watching) { pv.big = false; pv.cloud.clearPreview(); } }
        }
        ApButton {
            visible: pv.watching
            small: true; ghost: true
            text: pv.big ? qsTr("Менше") : qsTr("Збільшити")
            onClicked: pv.big = !pv.big
        }
    }
    Rectangle {
        visible: pv.watching
        Layout.fillWidth: true
        Layout.preferredHeight: width * 9 / 16
        Layout.maximumWidth: pv.big ? 100000 : 420
        color: "#40000000"
        border.width: 1
        border.color: ap.hair
        Image {
            anchors.fill: parent
            anchors.margins: 1
            fillMode: Image.PreserveAspectFit
            source: pv.cloud.previewImage
            cache: false
            smooth: true
        }
        ApText {
            anchors.centerIn: parent
            width: parent.width - 24
            horizontalAlignment: Text.AlignHCenter
            visible: pv.cloud.previewImage === ""
            role: "small"
            text: qsTr("Чекаю на картинку від програми клієнта (до 20 с). Клієнт має бути в грі зі збіркою 110 або новішою.")
        }
    }
    ApText {
        visible: pv.watching
        Layout.fillWidth: true
        role: "small"
        text: { pv.tick; return pv.cloud.previewImage !== "" && !pv.fresh
            ? qsTr("Картинка давно не оновлювалась: клієнт згорнув гру або зник зв'язок.")
            : qsTr("Затримка кілька секунд і проста якість: у клієнта картинка краща. На його гру це не впливає."); }
    }
}
