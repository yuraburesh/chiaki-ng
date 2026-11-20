import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

Item {
    id: dialog
    property alias header: headerLabel.text
    property alias title: titleLabel.text
    property alias buttonText: okButton.text
    property alias buttonEnabled: okButton.enabled
    property alias buttonVisible: okButton.visible
    property Item restoreFocusItem
    default property Item mainItem: null
    // AnyPlay: шапка нового дизайну (як верхня смуга головного екрана: назва ліворуч, «Назад» праворуч, тонка лінія),
    // фон — вечірній градієнт на все вікно. Інші діалоги (сервісні налаштування) лишаються як були.
    property bool anyplay: false
    // ті самі поля й масштаб на великих екранах, що й на головному екрані AnyPlay
    readonly property real apZoom: Math.max(1, Math.min(2.2, Math.min(width / 1600, height / 1000)))
    readonly property real apPadX: { const w = width / apZoom; return Math.max(w < 1100 ? 20 : 28, (w - 1240) / 2); }

    signal accepted()
    signal rejected()

    function close() {
        root.closeDialog();
    }

    Keys.onEscapePressed: close()

    Keys.onMenuPressed: {
        if (okButton.enabled)
            okButton.clicked()
    }

    StackView.onDeactivating: {
        restoreFocusItem = Window.window.activeFocusItem;
    }

    StackView.onActivated: {
        if (!restoreFocusItem) {
            let item = mainItem.nextItemInFocusChain();
            if (item)
                item.forceActiveFocus(Qt.TabFocusReason);
        } else {
            restoreFocusItem.forceActiveFocus(Qt.TabFocusReason);
            restoreFocusItem = null;
        }
    }

    onMainItemChanged: {
        if (mainItem) {
            mainItem.parent = contentItem;
            mainItem.anchors.fill = contentItem;
        }
    }

    ApBackground {
        visible: dialog.anyplay
        anchors.fill: parent
    }

    Item {
        id: apHeader
        visible: dialog.anyplay
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: visible ? apHeaderInner.height * dialog.apZoom : 0
        AnyPlayStyle { id: ap }
        Item {
            id: apHeaderInner
            width: parent.width / dialog.apZoom
            height: apHeaderCol.implicitHeight + 16
            scale: dialog.apZoom
            transformOrigin: Item.TopLeft
            ColumnLayout {
                id: apHeaderCol
                x: dialog.apPadX
                y: 16
                width: parent.width - 2 * dialog.apPadX
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 28
                    ColumnLayout {
                        Layout.alignment: Qt.AlignBottom
                        Layout.bottomMargin: 10
                        spacing: 0
                        Text {
                            text: "ANYPLAY"
                            font.family: ap.display; font.weight: Font.DemiBold; font.pixelSize: 24; font.letterSpacing: 3
                            color: ap.ink
                        }
                        Text {
                            text: qsTr("ОРЕНДА PS5: GTA ТА ІНШІ ІГРИ")
                            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 11; font.letterSpacing: 2
                            color: ap.faint
                        }
                    }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }
                    Rectangle {   // «Назад»: як «Вийти» у смузі головного екрана
                        Layout.alignment: Qt.AlignBottom
                        Layout.bottomMargin: 12
                        implicitWidth: apBackText.implicitWidth + 22
                        implicitHeight: apBackText.implicitHeight + 10
                        radius: ap.radius
                        color: "#0affffff"
                        border.color: apBackArea.containsMouse ? ap.ink : ap.edge
                        Text {
                            id: apBackText
                            anchors.centerIn: parent
                            text: qsTr("← Назад")
                            font.family: ap.body; font.weight: Font.Medium; font.pixelSize: 13
                            color: ap.ink
                        }
                        MouseArea {
                            id: apBackArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                dialog.rejected();
                                dialog.close();
                            }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: ap.hair }
            }
        }
    }

    ToolBar {
        id: toolBar
        visible: !dialog.anyplay
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: visible ? 64 : 0
        // AnyPlay: темна шапка у кольорах бренду замість світлої панелі
        Material.primary: "#1f1240"
        Material.background: "#1f1240"
        Material.foreground: "white"

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 10
                rightMargin: 10
            }

            Button {
                Layout.fillHeight: true
                Layout.preferredWidth: 100
                flat: true
                text: "❮"
                focusPolicy: Qt.NoFocus
                Material.roundedScale: Material.SmallScale
                onClicked: {
                    dialog.rejected();
                    dialog.close();
                }
            }

            Item { Layout.fillWidth: true }

            Button {
                id: okButton
                Layout.fillHeight: true
                flat: true
                padding: 30
                font.pixelSize: 25
                focusPolicy: Qt.NoFocus
                Material.roundedScale: Material.SmallScale
                onClicked: dialog.accepted()
                icon.source: "qrc:/icons/options.svg";
                icon.width: 50
                icon.height: 50
            }
        }

        Label {
            id: titleLabel
            anchors.centerIn: parent
            horizontalAlignment: Qt.AlignHCenter
            verticalAlignment: Qt.AlignVCenter
            font.bold: true
            font.pixelSize: 22
        }

        Label {
            id: headerLabel
            anchors {
                top: parent.top
                left: titleLabel.right
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            horizontalAlignment: Qt.AlignHCenter
            verticalAlignment: Qt.AlignVCenter
            font.bold: true
            font.pixelSize: 14
        }
    }

    Item {
        id: contentItem
        anchors {
            top: dialog.anyplay ? apHeader.bottom : toolBar.bottom
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
    }
}
