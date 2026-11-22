import QtQuick

import org.streetpea.chiaking

// AnyPlay: «віддача на екрані» для тих, хто грає клавіатурою й мишею. Коли гра вмикає вібрацію джойстика,
// краї картинки на мить темнішають і трохи «стискаються» до центру пропорційно силі вібрації.
// Саме відео не зсувається і центр екрана лишається чистим, тож цілитись це не заважає.
// Вмикається перемикачем «Віддача на екрані» (Chiaki.settings.anyplayHapticScreen, типово вимкнено);
// сила приходить із сесії готовою: Chiaki.session.rumbleLevel, 0..1, уже з плавним згасанням.
//
// Тут навмисно немає жодної анімації QML. Значення змінюється в програмі разом з кадром гри, тож край
// перемальовується тим самим проходом, що й кадр. Анімація (Behavior, NumberAnimation) малювала б екран
// ще й за власним таймером, а це зайві проходи малювання під час гри.
Item {
    id: edge

    readonly property real level: Chiaki.session && Chiaki.session.rumbleLevel !== undefined
        ? Math.max(0, Math.min(1, Chiaki.session.rumbleLevel)) : 0
    // смуга по краях: від 5% до 11% меншої сторони екрана
    readonly property int band: Math.round(Math.min(width, height) * (0.05 + 0.06 * level))
    // найтемніше на самому краю, до середини сходить нанівець
    readonly property color dark: Qt.rgba(0, 0, 0, 0.45 * level)
    readonly property color clear: Qt.rgba(0, 0, 0, 0)

    anchors.fill: parent
    visible: level > 0
    enabled: false   // мишки й клавіш не перехоплює

    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: edge.band
        gradient: Gradient {
            GradientStop { position: 0; color: edge.dark }
            GradientStop { position: 1; color: edge.clear }
        }
    }
    Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: edge.band
        gradient: Gradient {
            GradientStop { position: 0; color: edge.clear }
            GradientStop { position: 1; color: edge.dark }
        }
    }
    Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: edge.band
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: edge.dark }
            GradientStop { position: 1; color: edge.clear }
        }
    }
    Rectangle {
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
        width: edge.band
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: edge.clear }
            GradientStop { position: 1; color: edge.dark }
        }
    }
}
