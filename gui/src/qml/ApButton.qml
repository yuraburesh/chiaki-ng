// AnyPlay: кнопка єдиного дизайну 112.
// Головна (за замовчуванням): градієнт заходу сонця (рожевий → помаранчевий), білий текст, тінь, світіння під наведенням.
// ghost: скляна (напівпрозора) з тонким світлим краєм — другорядні дії. danger: червоний контур — небезпечні дії.
// small: менша, для рядків, фішок і вікон. Відгук однаковий усюди: наведення — підйом на ap.lift і яскравіший край;
// натиск — опускання, стискання до ap.pressScale, тінь коротшає. Фокус з клавіатури чи геймпада — блакитна рамка.
import QtQuick
import QtQuick.Controls

Button {
    id: b
    property bool ghost: false
    property bool small: false
    property bool danger: false          // червоний (наприклад, «Вийти з гри», «Закрити доступ усім»)
    property real minWidth: 0
    property bool wrap: false            // довгий напис у вузькій колонці — у два рядки замість «…»
    AnyPlayStyle { id: ap }

    readonly property bool primary: !ghost && !danger
    readonly property bool hot: hovered && enabled && !down
    readonly property real r: small ? ap.radiusSmall : ap.radius

    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    leftPadding: small ? 14 : (ghost || danger ? 22 : 32)
    rightPadding: leftPadding
    topPadding: small ? 7 : (ghost || danger ? 12 : 15)
    bottomPadding: topPadding
    implicitWidth: Math.max(minWidth, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: implicitContentHeight + topPadding + bottomPadding
    font.family: ap.display
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.pixelSize: small ? ap.fsButtonSmall : (ghost || danger ? 16 : ap.fsButton)
    font.letterSpacing: small ? 1.3 : (ghost || danger ? 1.7 : 2.4)
    opacity: enabled ? 1 : 0.45

    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()

    // підйом під наведенням і опускання під натиском — для вмісту й фону разом
    transform: Translate { y: b.down ? 1 : (b.hot ? -ap.lift : 0); Behavior on y { NumberAnimation { duration: b.down ? ap.tPress : ap.tHover; easing.type: Easing.OutCubic } } }
    scale: b.down ? ap.pressScale : 1
    Behavior on scale { NumberAnimation { duration: ap.tPress; easing.type: Easing.OutCubic } }

    contentItem: Text {
        text: b.text
        font: b.font
        color: b.primary ? ap.inkAccent : (b.danger ? ap.bad : ap.ink)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        wrapMode: b.wrap ? Text.Wrap : Text.NoWrap
        maximumLineCount: b.wrap ? 2 : 1
        style: b.primary ? Text.Raised : Text.Normal
        styleColor: "#40000000"
    }
    background: Item {
        implicitWidth: 80
        implicitHeight: b.small ? 30 : 44
        // тінь: два шари — звичайна і довша м'якша під наведенням; міняються згасанням (opacity), геометрія стала
        Rectangle {
            anchors { fill: parent; topMargin: 3; bottomMargin: -3; leftMargin: 2; rightMargin: 2 }
            radius: b.r + 2
            color: b.primary ? "#55a01c4a" : ap.shadow
            opacity: b.enabled ? (b.hot ? 0 : (b.down ? 0.35 : 0.55)) : 0
            Behavior on opacity { NumberAnimation { duration: ap.tHover } }
        }
        Rectangle {
            anchors { fill: parent; topMargin: 6; bottomMargin: -6; leftMargin: 2; rightMargin: 2 }
            radius: b.r + 2
            color: b.primary ? "#55a01c4a" : ap.shadow
            opacity: b.enabled && b.hot ? 0.85 : 0
            Behavior on opacity { NumberAnimation { duration: ap.tHover } }
        }
        // світіння акценту під наведенням (головна кнопка)
        Rectangle {
            visible: b.primary
            anchors { fill: parent; margins: -3 }
            radius: b.r + 3
            color: "transparent"
            border.width: 3
            border.color: "#66ff6a8a"
            opacity: b.hot ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: ap.tHover } }
        }
        Rectangle {
            id: face
            anchors.fill: parent
            radius: b.r
            gradient: Gradient {
                orientation: b.primary ? Gradient.Horizontal : Gradient.Vertical
                GradientStop { position: 0; color: b.primary ? (b.hot ? Qt.lighter(ap.accentA, 1.08) : ap.accentA)
                                                             : (b.danger ? "#26ff8f8f" : (b.hot ? "#2effffff" : "#1fffffff")) }
                GradientStop { position: 1; color: b.primary ? (b.hot ? Qt.lighter(ap.accentB, 1.08) : ap.accentB)
                                                             : (b.danger ? "#12ff8f8f" : (b.hot ? "#17ffffff" : "#0cffffff")) }
            }
            border.width: b.visualFocus ? 2 : (b.primary ? 0 : 1)
            border.color: b.visualFocus ? ap.cyan : (b.danger ? (b.hot ? ap.bad : "#99ff8f8f") : (b.hot ? ap.edgeHi : ap.edge))
        }
        // відблиск угорі: «скло» й об'єм
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 1 }
            height: Math.max(1, parent.height * 0.45)
            radius: b.r - 1
            gradient: Gradient {
                GradientStop { position: 0; color: b.primary ? "#40ffffff" : "#1affffff" }
                GradientStop { position: 1; color: "#00ffffff" }
            }
            opacity: b.down ? 0.4 : 1
        }
    }
}
