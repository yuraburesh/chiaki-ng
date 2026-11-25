// AnyPlay 113: неблокуюча підказка під час гри — «Картинка просідає: радимо знизити якість» з кнопкою «Знизити».
// Показує StreamView за сигналом Chiaki.cloud.qualityHint() (кадри на екрані < 80% потоку 10 с поспіль, і спрощення
// обробки вже не допомагає). Не забирає фокус у гри: кнопка натискається мишею; клавіша ` відкриє меню, де те саме
// в «Зображенні». Сама зникає за 20 с. Не частіше ніж раз на 5 хв (лічить AnyPlayCloud).
import QtQuick
import QtQuick.Layouts

import org.streetpea.chiaking

Item {
    id: hint
    property bool shown: false
    signal lower()   // «Знизити»: рівень нижче з перепідключенням
    AnyPlayStyle { id: ap }
    readonly property string levelName: [qsTr("Економна"), qsTr("Оптимальна"), qsTr("Максимальна"), qsTr("Ультра")][Math.max(0, Chiaki.cloud.qualityLevel - 1)] || ""

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: ap.tHover + 30 } }   // 180 мс, як усі анімації 115
    implicitWidth: row.implicitWidth + 32
    implicitHeight: row.implicitHeight + 22
    width: implicitWidth; height: implicitHeight

    function show() { shown = true; hide.restart(); }
    function close() { shown = false; Chiaki.cloud.qualityHintDone(); }
    Timer { id: hide; interval: 20000; onTriggered: hint.close() }

    Rectangle { x: 4; y: 6; width: parent.width - 8; height: parent.height; radius: ap.cardRadius + 2; color: ap.shadow; opacity: 0.6 }
    Rectangle {
        anchors.fill: parent
        radius: ap.cardRadius
        color: ap.dialog
        border.width: 1; border.color: "#66ffd27a"
        Rectangle { x: 1; y: 1; width: parent.width - 2; height: 1; color: ap.cardTop }
    }
    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 14
        Column {
            spacing: 2
            Text {
                text: qsTr("Картинка просідає")
                color: ap.gold
                font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 15
                font.letterSpacing: 1.6; font.capitalization: Font.AllUppercase
            }
            Text {
                text: hint.levelName !== "" ? qsTr("Радимо знизити якість до «%1»: гра перепідключиться на кілька секунд.").arg(hint.levelName)
                                            : qsTr("Радимо знизити якість: гра перепідключиться на кілька секунд.")
                color: ap.ink
                font.family: ap.body; font.pixelSize: ap.fsBody
            }
        }
        ApButton { small: true; text: qsTr("Знизити"); focusPolicy: Qt.NoFocus; onClicked: { hint.close(); hint.lower(); } }
        ApButton { small: true; ghost: true; text: qsTr("Не зараз"); focusPolicy: Qt.NoFocus; onClicked: hint.close() }
    }
}
