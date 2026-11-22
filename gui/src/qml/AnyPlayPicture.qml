// AnyPlay: «Картинка» — кольори під час гри. Діють одразу, зберігаються на цьому комп'ютері.
// Нуль на кожному повзунку — типові значення AnyPlay (трохи глибші середні тони й соковитіші кольори,
// ніж «як є», щоб картинка була ближчою до телевізора, підключеного до приставки напряму).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

ColumnLayout {
    id: pic
    property Item navLeft: null                       // куди йти клавішею ← (пункт меню ліворуч)
    readonly property Item firstControl: rows.count > 0 ? rows.itemAt(0).slider : null
    spacing: 0
    AnyPlayStyle { id: ap }

    readonly property var items: [
        { key: "picBrightness", name: qsTr("Яскравість"), lo: qsTr("темніше"), hi: qsTr("світліше"),
          hint: qsTr("Світлішають або темнішають середні тони. Біле лишається білим: небо й сонце від цього не пересвічуються.") },
        { key: "picContrast", name: qsTr("Контраст"), lo: qsTr("м'якше"), hi: qsTr("різкіше"),
          hint: qsTr("Більше — глибші тіні й яскравіші світлі місця. Якщо сонце сліпить, зменш контраст.") },
        { key: "picSaturation", name: qsTr("Насиченість"), lo: qsTr("блідіше"), hi: qsTr("соковитіше"), hint: "" },
        { key: "picWarmth", name: qsTr("Теплота"), lo: qsTr("холодніше"), hi: qsTr("тепліше"), hint: "" }
    ]
    function valueText(v) { return v === 0 ? qsTr("типово") : (v > 0 ? "+" : "") + v; }

    ApText { role: "cap"; text: qsTr("Картинка"); Layout.bottomMargin: 6 }
    ApText {
        Layout.fillWidth: true; Layout.maximumWidth: 620
        Layout.bottomMargin: 10
        role: "hint"
        text: qsTr("Змінюється одразу, гра не перепідключається. Налаштування запам'ятовуються на цьому комп'ютері.")
    }

    Repeater {
        id: rows
        model: pic.items
        ColumnLayout {
            id: row
            required property var modelData
            readonly property alias slider: sl
            Layout.fillWidth: true
            Layout.maximumWidth: 620
            Layout.bottomMargin: 14
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ApText { role: "title"; text: row.modelData.name; Layout.fillWidth: true }
                ApChip { text: pic.valueText(Math.round(sl.value)) }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ApText { role: "small"; color: ap.mute; text: row.modelData.lo; Layout.preferredWidth: 72 }
                Slider {
                    id: sl
                    Layout.fillWidth: true
                    from: -100; to: 100; stepSize: 5
                    value: Chiaki.window[row.modelData.key]
                    focusPolicy: Qt.StrongFocus
                    onMoved: Chiaki.window[row.modelData.key] = Math.round(value)
                    KeyNavigation.left: pic.navLeft
                    background: Rectangle {
                        x: sl.leftPadding
                        y: sl.topPadding + sl.availableHeight / 2 - height / 2
                        width: sl.availableWidth
                        height: 2
                        color: "#40ffffff"
                        Rectangle {   // від середини (типово) до повзунка
                            readonly property real mid: parent.width / 2
                            readonly property real pos: sl.visualPosition * parent.width
                            x: Math.min(mid, pos); width: Math.abs(pos - mid); height: parent.height
                            color: ap.ink
                        }
                        Rectangle { x: parent.width / 2 - 1; y: -4; width: 2; height: 10; color: "#80ffffff" }
                    }
                    handle: Rectangle {
                        x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
                        y: sl.topPadding + sl.availableHeight / 2 - height / 2
                        width: 14; height: 14; radius: 7
                        color: ap.ink
                        border.width: sl.visualFocus ? 2 : 0
                        border.color: ap.cyan
                    }
                }
                ApText { role: "small"; color: ap.mute; text: row.modelData.hi; Layout.preferredWidth: 72; horizontalAlignment: Text.AlignRight }
            }
            ApText {
                visible: row.modelData.hint !== ""
                Layout.fillWidth: true
                role: "hint"
                text: row.modelData.hint
            }
        }
    }

    ApButton {
        Layout.topMargin: 4
        small: true; ghost: true
        focusPolicy: Qt.StrongFocus
        enabled: !Chiaki.window.picIsDefault
        text: qsTr("Як було типово")
        onClicked: Chiaki.window.resetPicture()
        KeyNavigation.left: pic.navLeft
    }

    ApText {
        Layout.fillWidth: true; Layout.maximumWidth: 620
        Layout.topMargin: 16
        role: "hint"
        text: qsTr("Якщо небо чи сонце в грі зливаються в біле, це вже прийшло таким з приставки. Допомагає повзунок «Яскравість» у налаштуваннях самої гри (меню гри, «Зображення»): зменш його на кілька поділок.")
    }
}
