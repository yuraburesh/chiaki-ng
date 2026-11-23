// AnyPlay: тло єдиного дизайну 112 — нічне небо Vice City: градієнт під кутом 160° (глибока ніч → фіолетовий → маджента),
// м'яке світіння сонця біля обрію праворуч унизу і рожевий серпанок зліва вгорі. Нерухоме, легке для відеокарти.
import QtQuick
import QtQuick.Shapes

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
            GradientStop { position: 0.5; color: ap.bg2 }
            GradientStop { position: 1.0; color: ap.bg3 }
        }
    }
    // сонце біля обрію (праворуч унизу) і рожевий серпанок (ліворуч угорі): радіальні плями, що згасають до прозорого
    Shape {
        anchors.fill: parent
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: bg.width * 0.86; centerY: bg.height * 1.04
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(bg.width, bg.height) * 0.62
                GradientStop { position: 0.0; color: "#66ff7a45" }
                GradientStop { position: 0.35; color: "#33ff3d8b" }
                GradientStop { position: 1.0; color: "#00ff3d8b" }
            }
            startX: 0; startY: 0
            PathLine { x: bg.width; y: 0 }
            PathLine { x: bg.width; y: bg.height }
            PathLine { x: 0; y: bg.height }
            PathLine { x: 0; y: 0 }
        }
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: bg.width * 0.08; centerY: -bg.height * 0.1
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(bg.width, bg.height) * 0.5
                GradientStop { position: 0.0; color: "#33a24bff" }
                GradientStop { position: 1.0; color: "#00a24bff" }
            }
            startX: 0; startY: 0
            PathLine { x: bg.width; y: 0 }
            PathLine { x: bg.width; y: bg.height }
            PathLine { x: 0; y: bg.height }
            PathLine { x: 0; y: 0 }
        }
    }
}
