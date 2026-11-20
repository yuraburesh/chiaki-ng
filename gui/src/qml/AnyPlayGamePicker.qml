// AnyPlay: «У що граєш?» перед грою. Три квадратні логотипи (GTA VI, GTA V, інша гра) — розкладка клавіш під гру.
// Використання: AnyPlayGamePicker { id: picker; anchors.fill: parent; onPicked: (id) => грати() }, далі picker.open().
// «Запам'ятати вибір» вимикає Chiaki.settings.anyplayAskGame: наступного разу гра почнеться одразу.
import QtQuick
import org.streetpea.chiaking

Item {
    id: picker
    visible: false
    z: 100
    signal picked(string layoutId)
    signal dismissed()

    property string selected: ""
    property bool remember: true
    property var layouts: []

    AnyPlayStyle { id: ap }

    function open() {
        layouts = Chiaki.settings.anyplayLayouts();
        selected = Chiaki.settings.anyplayLayout();
        remember = true;
        visible = true;
        forceActiveFocus();
    }
    function dismiss() {
        if (!visible)
            return;
        visible = false;
        dismissed();
    }
    function play() {
        if (!visible || !selected)
            return;
        Chiaki.settings.setAnyplayLayout(selected);
        Chiaki.settings.anyplayAskGame = !remember;
        visible = false;
        picked(selected);
    }
    function move(step) {
        let i = 0;
        for (let j = 0; j < layouts.length; j++)
            if (layouts[j].id === selected) i = j;
        selected = layouts[(i + step + layouts.length) % layouts.length].id;
    }

    focus: visible
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Escape) dismiss();
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) play();
        else if (e.key === Qt.Key_Left) move(-1);
        else if (e.key === Qt.Key_Right || e.key === Qt.Key_Tab) move(1);
        else return;
        e.accepted = true;
    }

    // затемнення: клік повз вікно закриває вибір
    Rectangle {
        anchors.fill: parent
        color: "#cc0a0516"
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onClicked: picker.dismiss()
            onWheel: (w) => w.accepted = true
        }
    }

    Rectangle {
        id: dlg
        readonly property bool compact: width < 520
        width: Math.min(680, picker.width - 32)
        height: body.implicitHeight + 36
        anchors.centerIn: parent
        radius: 6
        color: "#f52a2639"
        border.width: 1
        border.color: "#33ffffff"
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }   // клік у вікні його не закриває

        Column {
            id: body
            x: 18; y: 18
            width: dlg.width - 36
            spacing: 12

            Text {
                text: qsTr("У що граєш?")
                color: ap.ink
                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 22; font.letterSpacing: 1.5
                font.capitalization: Font.AllUppercase
            }
            Text {
                width: parent.width
                text: qsTr("Обери розкладку клавіш під свою гру. Змінити її можна будь-коли, навіть під час гри.")
                wrapMode: Text.WordWrap
                color: "#c9c3d6"
                font.family: ap.body; font.pixelSize: 12
            }

            Row {
                id: cards
                width: parent.width
                spacing: dlg.compact ? 6 : 8
                readonly property real cardW: (width - 2 * spacing) / 3
                Repeater {
                    model: picker.layouts
                    Rectangle {
                        id: card
                        required property var modelData
                        readonly property bool cur: modelData.id === picker.selected
                        readonly property real pad: dlg.compact ? 6 : 10
                        width: cards.cardW
                        height: cardCol.implicitHeight + 2 * pad
                        radius: 4
                        color: cur ? "#1fffffff" : cardArea.containsMouse ? "#14ffffff" : "#0dffffff"
                        border.width: 1
                        border.color: cur ? "#ffffff" : cardArea.containsMouse ? "#80ffffff" : "#33ffffff"
                        Column {
                            id: cardCol
                            x: card.pad; y: card.pad
                            width: card.width - 2 * card.pad
                            spacing: 5
                            // логотип: квадрат, однаковий для всіх трьох
                            Rectangle {
                                width: parent.width; height: width
                                radius: 3
                                color: "#000000"
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: card.modelData.logo || ""
                                    fillMode: Image.PreserveAspectCrop
                                    smooth: true; mipmap: true
                                }
                            }
                            Item { width: 1; height: 1 }
                            Text {
                                width: parent.width
                                text: card.modelData.name
                                elide: Text.ElideRight
                                color: ap.ink
                                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: dlg.compact ? 14 : 18; font.letterSpacing: 1
                                font.capitalization: Font.AllUppercase
                            }
                            Text {
                                visible: !dlg.compact
                                width: parent.width
                                text: card.modelData.info
                                elide: Text.ElideRight
                                color: "#c9c3d6"
                                font.family: ap.body; font.pixelSize: 12
                            }
                        }
                        MouseArea {
                            id: cardArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            Accessible.name: card.modelData.name
                            onClicked: { picker.selected = card.modelData.id; picker.forceActiveFocus(); }
                            onDoubleClicked: { picker.selected = card.modelData.id; picker.play(); }
                        }
                    }
                }
            }

            // запам'ятати вибір
            Item {
                width: remRow.implicitWidth; height: 22
                Row {
                    id: remRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Rectangle {
                        width: 16; height: 16; radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: picker.remember ? "#ffffff" : "transparent"
                        border.width: 1
                        border.color: picker.remember || remArea.containsMouse ? "#ffffff" : "#80ffffff"
                        Text { anchors.centerIn: parent; visible: picker.remember; text: "✓"; color: ap.dark; font.family: ap.body; font.pixelSize: 12; font.weight: Font.DemiBold }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Запам'ятати вибір і більше не питати")
                        color: ap.ink
                        font.family: ap.body; font.weight: Font.DemiBold; font.pixelSize: 13
                    }
                }
                MouseArea {
                    id: remArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.name: qsTr("Запам'ятати вибір і більше не питати")
                    onClicked: { picker.remember = !picker.remember; picker.forceActiveFocus(); }
                }
            }

            // головна кнопка: біла, темний текст
            Item {
                width: parent.width
                height: playBtn.height
                Rectangle {
                    id: playBtn
                    anchors.right: parent.right
                    width: playText.implicitWidth + 36
                    height: playText.implicitHeight + 14
                    radius: ap.radius
                    color: playArea.pressed ? "#d9d5de" : playArea.containsMouse ? "#ffffff" : ap.ink
                    Text {
                        id: playText
                        anchors.centerIn: parent
                        text: qsTr("▶ Грати")
                        color: ap.dark
                        font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 18; font.letterSpacing: 2.4
                        font.capitalization: Font.AllUppercase
                    }
                    MouseArea {
                        id: playArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        Accessible.name: qsTr("Грати")
                        onClicked: picker.play()
                    }
                }
            }
        }
    }
}
