// AnyPlay: скляна панель (картка) єдиного дизайну 112 — групує вміст сторінки.
// Темне скло з тонким світлим краєм, світліша смужка вгорі (об'єм) і м'яка тінь.
// title — підпис розділу великими літерами (необов'язково); вміст кладемо всередину: ApCard { title: "Інструменти"; ApRow { … } }.
// Вміст — у колонці з відступами padding; ширина картки задається ззовні (Layout.fillWidth або width).
// hoverable: true — під наведенням край яскравіший (для карток, що натискаються; сигнал clicked()).
import QtQuick
import QtQuick.Layouts

Item {
    id: c
    property string title: ""
    property string trailingText: ""          // дрібний текст праворуч від заголовка (наприклад, «оновлено о 02:31»)
    property real padding: 22
    property real spacing: 10
    property bool hoverable: false
    property color accentEdge: "transparent"  // кольорова смужка зліва (наприклад, ap.ok для «картинка плавна»)
    default property alias content: col.data
    signal clicked()
    AnyPlayStyle { id: ap }

    implicitWidth: 360
    implicitHeight: col.implicitHeight + 2 * padding + (head.visible ? head.height + c.spacing : 0)
    Layout.fillWidth: true

    Rectangle {   // тінь
        anchors { fill: parent; topMargin: 6; bottomMargin: -6; leftMargin: 4; rightMargin: 4 }
        radius: ap.cardRadius + 2
        color: ap.shadow
        opacity: 0.45
    }
    Rectangle {
        id: face
        anchors.fill: parent
        radius: ap.cardRadius
        color: ap.card
        border.width: 1
        border.color: c.hoverable && mouse.containsMouse ? ap.edgeHi : ap.cardEdge
        Rectangle {   // світла смужка вгорі: скло
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
            height: Math.min(60, parent.height * 0.5)
            radius: ap.cardRadius - 1
            gradient: Gradient { GradientStop { position: 0; color: ap.cardTop } GradientStop { position: 1; color: "#00ffffff" } }
        }
        Rectangle {
            visible: c.accentEdge.a > 0
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 16; bottomMargin: 16 }
            width: 3; radius: 1.5
            color: c.accentEdge
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: c.hoverable
        hoverEnabled: true
        cursorShape: c.hoverable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: c.clicked()
    }
    RowLayout {
        id: head
        visible: c.title !== ""
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: c.padding; rightMargin: c.padding; topMargin: c.padding }
        ApText { role: "cap"; text: c.title; Layout.fillWidth: true; color: ap.mute }
        ApText { role: "small"; text: c.trailingText; visible: text !== "" }
    }
    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: head.visible ? head.bottom : parent.top
                  leftMargin: c.padding; rightMargin: c.padding; topMargin: head.visible ? c.spacing : c.padding }
        spacing: c.spacing
    }
}
