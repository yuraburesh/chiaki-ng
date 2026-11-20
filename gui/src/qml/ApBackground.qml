// AnyPlay: фон нового дизайну — вечірній градієнт під кутом 160° (з лівого верху вниз і трохи праворуч).
// Звичайний Gradient у QML лише вертикальний, тож повертаємо прямокутник з ним на −20°.
import QtQuick

Item {
    id: bg
    AnyPlayStyle { id: ap }
    clip: true
    // довжина лінії градієнта, як у CSS для кута 160°
    readonly property real span: width * 0.342 + height * 0.940

    Rectangle {
        anchors.fill: parent
        color: ap.bg1
    }
    Rectangle {
        width: bg.width + bg.height
        height: bg.span
        anchors.centerIn: parent
        rotation: -20
        gradient: Gradient {
            GradientStop { position: 0.0; color: ap.bg1 }
            GradientStop { position: 0.45; color: ap.bg2 }
            GradientStop { position: 1.0; color: ap.bg3 }
        }
    }
}
