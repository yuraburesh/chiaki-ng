import QtQuick
import QtQuick.Shapes

// Оригінальна сцена AnyPlay для прикладів якості (власного авторства, без кадрів з ігор). У програму не входить:
// рендериться один раз у 1920×1080 (detail 2 і 3), з неї робляться q0–q3.jpg (540p і 720p справді зменшені й розтягнуті,
// q3 з підсиленням дрібних деталей, як ШІ-чіткість).
Item {
    id: sc
    property int detail: 2            // 0 — 540p м'яка, 1 — 720p, 2 — 1080p, 3 — 1080p і ШІ-чіткість
    readonly property real u: width / 320   // усе малюємо в умовних 320×180
    clip: true
    Rectangle {   // небо
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#1a1038" }
            GradientStop { position: 0.55; color: "#5a2a6e" }
            GradientStop { position: 0.72; color: "#ff5f8a" }
            GradientStop { position: 0.80; color: "#ff9a4a" }
        }
    }
    Rectangle {   // сонце зі смужками
        x: sc.width * 0.58 - width / 2; y: sc.height * 0.80 - height
        width: sc.u * 88; height: width; radius: width / 2
        gradient: Gradient { GradientStop { position: 0; color: "#ffe27a" } GradientStop { position: 1; color: "#ff5a7a" } }
        Column {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: sc.u * 4 }
            spacing: sc.u * 5
            Repeater { model: 5; Rectangle { required property int index; width: parent.width; height: sc.u * (1 + index * 0.6); color: "#5a2a6e" } }
        }
    }
    Row {   // місто вдалині
        anchors { left: parent.left; bottom: parent.bottom; bottomMargin: sc.height * 0.20 }
        spacing: sc.u * 3
        Repeater {
            model: [18, 30, 12, 40, 22, 52, 16, 34, 26, 44, 14, 36, 20, 28, 48, 10, 32, 24, 38, 16]
            Rectangle {
                id: bld
                required property int modelData
                required property int index
                width: sc.u * (8 + (index % 3) * 4); height: sc.u * modelData
                anchors.bottom: parent.bottom
                color: "#2a1446"
                Grid {   // вікна: дрібні деталі, які видно лише на чіткій картинці
                    visible: sc.detail >= 2
                    anchors { fill: parent; margins: sc.u * 1.5 }
                    columns: 2; spacing: sc.u * 1.5
                    Repeater {
                        model: Math.floor(bld.modelData / 5) * 2
                        Rectangle { required property int index; width: sc.u * (sc.detail >= 3 ? 1.8 : 2.2); height: sc.u * 1.2; color: (index * 7) % 5 === 0 ? "#ffd27a" : "#7fe6ff"; opacity: (index * 13) % 3 === 0 ? 0.9 : 0.35 }
                    }
                }
            }
        }
    }
    Rectangle {   // земля
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: sc.height * 0.20
        color: "#14092a"
    }
    Shape {   // дорога з перспективою
        anchors.fill: parent
        ShapePath {
            strokeWidth: 0; fillColor: "#2b2040"
            startX: sc.width * 0.36; startY: sc.height * 0.80
            PathLine { x: sc.width * 0.64; y: sc.height * 0.80 }
            PathLine { x: sc.width * 1.05; y: sc.height }
            PathLine { x: sc.width * -0.05; y: sc.height }
        }
        ShapePath {   // розмітка: тонка, видно чіткість
            strokeWidth: sc.u * 1.2; strokeColor: "#ffd27a"; fillColor: "transparent"
            strokeStyle: ShapePath.DashLine; dashPattern: [3, 3]
            startX: sc.width * 0.5; startY: sc.height * 0.80
            PathLine { x: sc.width * 0.5; y: sc.height }
        }
        ShapePath {   // неонові краї дороги
            strokeWidth: sc.u * 0.9; strokeColor: "#ff4f8b"; fillColor: "transparent"
            startX: sc.width * 0.36; startY: sc.height * 0.80
            PathLine { x: sc.width * -0.05; y: sc.height }
        }
        ShapePath {
            strokeWidth: sc.u * 0.9; strokeColor: "#ff4f8b"; fillColor: "transparent"
            startX: sc.width * 0.64; startY: sc.height * 0.80
            PathLine { x: sc.width * 1.05; y: sc.height }
        }
    }
    Repeater {   // пальми
        model: [{ x: 0.12, h: 0.42, s: 1.0 }, { x: 0.88, h: 0.5, s: 1.15 }]
        Item {
            id: palm
            required property var modelData
            x: sc.width * modelData.x; y: sc.height * (1 - modelData.h) - sc.u * 10
            Rectangle { x: -sc.u * 2; width: sc.u * 4; height: sc.height * palm.modelData.h; radius: sc.u * 2; color: "#0d0618" }
            Repeater {
                model: 7
                Rectangle {
                    required property int index
                    x: 0; y: 0
                    width: sc.u * 34 * palm.modelData.s; height: sc.u * 6
                    radius: height / 2
                    color: "#0d0618"
                    transformOrigin: Item.Left
                    rotation: -150 + index * 43
                    Rectangle { visible: sc.detail >= 3; anchors.centerIn: parent; width: parent.width * 0.8; height: 1; color: "#22ff8a3d" }
                }
            }
        }
    }
    Item {   // авто на дорозі
        x: sc.width * 0.5 - width / 2; y: sc.height * 0.80 - height * 0.15
        width: sc.u * 70; height: sc.u * 30
        Rectangle { x: parent.width * 0.18; y: 0; width: parent.width * 0.64; height: parent.height * 0.5; radius: sc.u * 5; color: "#f7f3fb"
            Rectangle { x: sc.u * 4; y: sc.u * 2; width: parent.width - sc.u * 8; height: parent.height * 0.6; radius: sc.u * 2; color: "#7fe6ff"; opacity: 0.8 } }
        Rectangle { y: parent.height * 0.4; width: parent.width; height: parent.height * 0.5; radius: sc.u * 6; color: "#ff4f8b"
            Rectangle { visible: sc.detail >= 3; x: sc.u * 6; y: sc.u * 2; width: parent.width - sc.u * 12; height: 1; color: "#80ffffff" } }
        Rectangle { x: sc.u * 4; y: parent.height * 0.52; width: sc.u * 8; height: sc.u * 5; radius: sc.u; color: "#ffe27a" }
        Rectangle { x: parent.width - sc.u * 12; y: parent.height * 0.52; width: sc.u * 8; height: sc.u * 5; radius: sc.u; color: "#ffe27a" }
        Rectangle { x: sc.u * 8; y: parent.height * 0.78; width: sc.u * 12; height: sc.u * 8; radius: sc.u * 4; color: "#0d0618" }
        Rectangle { x: parent.width - sc.u * 20; y: parent.height * 0.78; width: sc.u * 12; height: sc.u * 8; radius: sc.u * 4; color: "#0d0618" }
    }
}

