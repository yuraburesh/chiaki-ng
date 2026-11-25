// AnyPlay: вкладки єдиного дизайну 112 — великі літери, поточна на скляній підкладці з лінією заходу сонця знизу.
// model: [{ id: "home", text: "Гра", badge: 2 (необов'язково) }, …]; current — id поточної; activated(id) — натиснули.
// Відгук: наведення — підкладка й підйом, натиск — опускання. compact: вузьке вікно, менші відступи.
import QtQuick

Row {
    id: tabs
    property var model: []
    property string current: ""
    property bool compact: false
    property real fontSize: compact ? 15 : 17
    signal activated(string id)
    signal clickedTab(string id)         // натиснули мишкою (до activated): рамку фокусу після клацу не показуємо
    AnyPlayStyle { id: ap }
    spacing: compact ? 2 : 4

    Repeater {
        model: tabs.model
        Item {
            id: tab
            required property var modelData
            readonly property bool on: tabs.current === modelData.id
            readonly property bool hot: mouse.containsMouse && !mouse.pressed
            readonly property int badge: modelData.badge || 0
            property bool byMouse: false
            readonly property bool ring: activeFocus && !byMouse
            onActiveFocusChanged: if (!activeFocus) byMouse = false
            implicitWidth: label.implicitWidth + (badgeBox.visible ? badgeBox.width + 6 : 0) + (tabs.compact ? 20 : 30)
            implicitHeight: label.implicitHeight + 24
            activeFocusOnTab: true
            Keys.onPressed: (e) => { tab.byMouse = false; e.accepted = false; }
            Keys.onReturnPressed: tabs.activated(modelData.id)
            Keys.onSpacePressed: tabs.activated(modelData.id)

            Item {
                id: body
                anchors.fill: parent
                transform: Translate { y: mouse.pressed ? 1 : (tab.hot && !tab.on ? -1 : 0); Behavior on y { NumberAnimation { duration: ap.tHover } } }
                Rectangle {   // скляна підкладка: поточна, наведення (згасанням, без анімації кольору)
                    anchors { fill: parent; topMargin: 4; bottomMargin: 4 }
                    radius: ap.radiusSmall
                    color: tab.on ? ap.glassHi : ap.glass
                    border.width: tab.on ? 1 : 0
                    border.color: ap.edge
                    opacity: tab.on || tab.hot ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: ap.tHover } }
                }
                Rectangle {   // фокус з клавіатури чи геймпада
                    anchors { fill: parent; topMargin: 4; bottomMargin: 4 }
                    radius: ap.radiusSmall
                    visible: tab.ring
                    color: "transparent"
                    border.width: 2
                    border.color: ap.cyan
                }
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Text {
                        id: label
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.modelData.text
                        font.family: ap.display
                        font.weight: Font.DemiBold
                        font.pixelSize: tabs.fontSize
                        font.letterSpacing: 1.7
                        font.capitalization: Font.AllUppercase
                        color: ap.ink
                        opacity: tab.on || tab.hot || tab.ring ? 1 : 0.66
                        Behavior on opacity { NumberAnimation { duration: ap.tHover } }
                    }
                    Rectangle {
                        id: badgeBox
                        visible: tab.badge > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(20, badgeText.implicitWidth + 10); height: 20; radius: 10
                        gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                        Text { id: badgeText; anchors.centerIn: parent; text: tab.badge; color: ap.inkAccent; font.family: ap.body; font.weight: Font.Bold; font.pixelSize: 11 }
                    }
                }
                Rectangle {   // лінія заходу сонця під поточною вкладкою
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom }
                    width: parent.width - 16
                    height: 3; radius: 1.5
                    gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
                    // розгортається від середини: масштаб (transform), а не ширина — без перерахунку розмітки
                    transform: Scale { origin.x: (tab.width - 16) / 2; xScale: tab.on ? 1 : 0; Behavior on xScale { NumberAnimation { duration: ap.tPage; easing.type: Easing.OutCubic } } }
                }
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { tab.byMouse = true; tabs.clickedTab(tab.modelData.id); tabs.activated(tab.modelData.id); tab.byMouse = true; }
            }
        }
    }
}
