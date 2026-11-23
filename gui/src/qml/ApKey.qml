// AnyPlay: об'ємна клавіша («кейкап») єдиного дизайну 112 — для екрана клавіш і довідок.
// text — назва клавіші («Shift», «W», «ПКМ»); size — висота (ширина за текстом, не менша за висоту);
// active — підсвічена (натиснута зараз у перевірці чи вибрана для зміни); interactive — відгук на мишу (сигнал clicked()).
// Відгук: наведення — клавіша піднімається і край світиться; натиск — «вдавлюється» (бортик зникає, опускається на 2 px).
import QtQuick

Item {
    id: k
    property string text
    property real size: 30
    property bool active: false
    property bool interactive: true
    property bool empty: text === ""          // клавішу не призначено: пунктирний вигляд
    readonly property bool hot: interactive && mouse.containsMouse && !mouse.pressed
    readonly property bool pressedNow: mouse.pressed || active
    signal clicked()
    AnyPlayStyle { id: ap }

    implicitHeight: size + 3
    implicitWidth: Math.max(size, label.implicitWidth + size * 0.6)

    Rectangle {   // бортик (нижня грань клавіші) і тінь
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: k.size
        radius: Math.max(4, k.size * 0.2)
        color: k.active ? "#b0336f" : "#cc0c0718"
        opacity: k.empty ? 0.3 : 1
    }
    Rectangle {
        id: cap
        x: 0
        width: parent.width
        height: k.size
        y: k.pressedNow ? 3 : (k.hot ? -1 : 0)
        Behavior on y { NumberAnimation { duration: k.pressedNow ? ap.tPress : ap.tHover; easing.type: Easing.OutCubic } }
        radius: Math.max(4, k.size * 0.2)
        gradient: Gradient {
            GradientStop { position: 0; color: k.active ? ap.accentA : (k.hot ? "#5affffff" : (k.empty ? "#14ffffff" : "#40ffffff")) }
            GradientStop { position: 1; color: k.active ? ap.accentB : (k.hot ? "#2effffff" : (k.empty ? "#08ffffff" : "#1cffffff")) }
        }
        border.width: 1
        border.color: k.active ? "#ffc2d6" : (k.hot ? ap.edgeHi : ap.edge)
        Rectangle {   // відблиск угорі
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
            height: parent.height * 0.42
            radius: parent.radius - 1
            gradient: Gradient { GradientStop { position: 0; color: "#33ffffff" } GradientStop { position: 1; color: "#00ffffff" } }
        }
        Text {
            id: label
            anchors.centerIn: parent
            text: k.empty ? "—" : k.text
            font.family: ap.body
            font.weight: Font.DemiBold
            font.pixelSize: Math.max(10, k.size * (k.text.length > 3 ? 0.4 : 0.46))
            color: k.active ? ap.inkAccent : ap.ink
            opacity: k.empty ? 0.5 : 1
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: k.interactive
        hoverEnabled: true
        cursorShape: k.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: k.clicked()
    }
}
