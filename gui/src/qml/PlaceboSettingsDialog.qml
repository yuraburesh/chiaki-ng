import QtCore
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Dialogs

import org.streetpea.chiaking

import "controls" as C

DialogView {
    id: dialog
    property string options_url: ""
    title: qsTr("Налаштування рендерера Placebo")
    header: qsTr("* Стандартні значення вказані в дужках праворуч або позначені «(За замовчуванням)»")
    buttonVisible: false
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            bar.decrementCurrentIndex();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            bar.incrementCurrentIndex();
            event.accepted = true;
            break;
        }
    }

    Item {
        TabBar {
            id: bar
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                topMargin: 5
            }

            TabButton {
                text: qsTr("Конфігурація")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Масштабування")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Деінтерлейсинг")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Дебандинг")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Сигмоїдизація")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Колір")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Визначення піку")
                focusPolicy: Qt.NoFocus
            }

            TabButton {
                text: qsTr("Відображення кольорів")
                focusPolicy: Qt.NoFocus
            }
        }

        StackLayout {
            anchors {
                top: bar.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            currentIndex: bar.currentIndex
            onCurrentIndexChanged: nextItemInFocusChain().forceActiveFocus(Qt.TabFocusReason)

            Item {
                // Config
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 2
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        text: qsTr("Докладно про параметри рендерера libplacebo")
                        visible: !options_url
                    }

                    C.Button {
                        id: openwebpage
                        text: qsTr("Відкрити документацію")
                        onClicked: {
                            options_url = Chiaki.openPlaceboOptionsLink()
                        }
                        visible: !options_url
                    }

                    Label {
                        text: qsTr("Відкрити документацію в браузері (адресу скопійовано)")
                        visible: options_url
                    }

                    TextField {
                        id: openurl
                        echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                        text: options_url
                        visible: false
                        Layout.preferredWidth: 400
                    }

                    C.Button {
                        id: copyUrl
                        text: qsTr("Натисніть, щоб скопіювати адресу ще раз")
                        onClicked: {
                            openurl.selectAll()
                            openurl.copy()
                        }
                        visible: options_url
                    }

                    Label {
                        text: qsTr("Експортувати налаштування рендерингу у файл")
                    }

                    C.Button {
                        id: exportButton
                        text: qsTr("Експорт")
                        onClicked: {
                            Chiaki.settings.exportPlaceboSettings();
                        }
                        Material.roundedScale: Material.SmallScale
                        KeyNavigation.down: importButton
                        KeyNavigation.right: importButton
                    }

                    Label {
                        text: qsTr("Імпортувати налаштування рендерингу з файлу")
                    }

                    C.Button {
                        id: importButton
                        lastInFocusChain: true
                        text: qsTr("Імпорт")
                        onClicked: {
                            Chiaki.settings.importPlaceboSettings();
                        }
                        Material.roundedScale: Material.SmallScale
                        KeyNavigation.up: exportButton
                        KeyNavigation.left: exportButton
                    }
                }
            }

            Item {
                // Scaling
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Апскейлер:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        firstInFocusChain: true
                        model: [qsTr("Власний"), qsTr("Найближчий"), qsTr("Bilinear"), qsTr("Oversample"), qsTr("Bicubic"), qsTr("Gaussian"), qsTr("Catmull Rom"), qsTr("Lanczos"), qsTr("EwaLanczos"), qsTr("EwaLanczosSharp"), qsTr("EwaLanczosSharpest"), qsTr("FSR"), qsTr("FSRCNNX x2 8-0-4-1"), qsTr("FSRCNNX x2 16-0-4-1")]
                        currentIndex: Chiaki.settings.placeboUpscaler
                        onActivated: index => Chiaki.settings.placeboUpscaler = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(EwaLanczos)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Апскейлер площини:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        firstInFocusChain: true
                        model: [qsTr("Вибраний апскейлер"), qsTr("Найближчий"), qsTr("Bilinear"), qsTr("Oversample"), qsTr("Bicubic"), qsTr("Gaussian"), qsTr("Catmull Rom"), qsTr("Lanczos"), qsTr("EwaLanczos"), qsTr("EwaLanczosSharp"), qsTr("EwaLanczosSharpest")]
                        currentIndex: Chiaki.settings.placeboPlaneUpscaler
                        onActivated: index => Chiaki.settings.placeboPlaneUpscaler = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Вибраний апскейлер)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Даунскейлер:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        firstInFocusChain: true
                        model: [qsTr("Власний"), qsTr("Box"), qsTr("Hermite"), qsTr("Bilinear"), qsTr("Bicubic"), qsTr("Gaussian"), qsTr("Catmull Rom"), qsTr("Mitchell"), qsTr("Lanczos")]
                        currentIndex: Chiaki.settings.placeboDownscaler
                        onActivated: index => Chiaki.settings.placeboDownscaler = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Hermite)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Даунскейлер площини:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        firstInFocusChain: true
                        model: [qsTr("Вибраний даунскейлер"), qsTr("Box"), qsTr("Hermite"), qsTr("Bilinear"), qsTr("Bicubic"), qsTr("Gaussian"), qsTr("Catmull Rom"), qsTr("Mitchell"), qsTr("Lanczos")]
                        currentIndex: Chiaki.settings.placeboPlaneDownscaler
                        onActivated: index => Chiaki.settings.placeboPlaneDownscaler = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Вибраний даунскейлер)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Сила антиринґінгу:")
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.00
                        to: 1.00
                        stepSize: 0.01
                        value: Chiaki.settings.placeboAntiringingStrength
                        onMoved: Chiaki.settings.placeboAntiringingStrength = value

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(2))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(0.00)")
                    }
                }
            }

            Item {
                // Deinterlace
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Деінтерлейсинг:")
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.placeboDeinterlaceEnabled
                        onToggled: Chiaki.settings.placeboDeinterlaceEnabled = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(ні)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет:")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("За замовчуванням")]
                        currentIndex: Chiaki.settings.placeboDeinterlacePreset
                        enabled: Chiaki.settings.placeboDeinterlaceEnabled
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                        onActivated: index => Chiaki.settings.placeboDeinterlacePreset = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(За замовчуванням)")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Алгоритм:")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Weave"), qsTr("Bob"), qsTr("Yadif"), qsTr("Bwdif")]
                        currentIndex: Chiaki.settings.placeboDeinterlaceAlgorithm
                        enabled: Chiaki.settings.placeboDeinterlaceEnabled
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                        onActivated: index => Chiaki.settings.placeboDeinterlaceAlgorithm = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Yadif)")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пропустити просторову перевірку:")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.placeboDeinterlaceSkipSpatial
                        enabled: Chiaki.settings.placeboDeinterlaceEnabled
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                        onToggled: Chiaki.settings.placeboDeinterlaceSkipSpatial = checked
                        Material.roundedScale: Material.SmallScale
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(ні)")
                        visible: Chiaki.settings.placeboDeinterlaceEnabled
                    }
                }
            }

            Item {
                // Debanding
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Дебандинг:")
                    }

                    C.CheckBox {
                        text: qsTr("Увімкнути дебандинг")
                        checked: Chiaki.settings.placeboDebandEnabled
                        onToggled: Chiaki.settings.placeboDebandEnabled = checked
                    }


                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Увімкнено)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет дебандингу:")
                        visible: Chiaki.settings.placeboDebandEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Власний"), qsTr("За замовчуванням")]
                        currentIndex: Chiaki.settings.placeboDebandPreset
                        onActivated: index => Chiaki.settings.placeboDebandPreset = index
                        visible: Chiaki.settings.placeboDebandEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Власний)")
                        visible: Chiaki.settings.placeboDebandEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Ітерації дебандингу:")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0
                        to: 16
                        stepSize: 1
                        value: Chiaki.settings.placeboDebandIterations
                        onMoved: Chiaki.settings.placeboDebandIterations = value
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr("%1").arg(parent.value)
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1)")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Поріг дебандингу:")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 1000.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboDebandThreshold
                        onMoved: Chiaki.settings.placeboDebandThreshold = value
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(3.0)")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Радіус дебандингу:")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 1000.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboDebandRadius
                        onMoved: Chiaki.settings.placeboDebandRadius = value
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(16.0)")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Зерно дебандингу:")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 1000.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboDebandGrain
                        onMoved: Chiaki.settings.placeboDebandGrain = value
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(4.0)")
                        visible: Chiaki.settings.placeboDebandEnabled && (Chiaki.settings.placeboDebandPreset == 0)
                    }
                }
            }

            Item {
                // Sigmoidization
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Сигмоїдизація:")
                    }

                    C.CheckBox {
                        text: qsTr("Увімкнути сигмоїдизацію")
                        checked: Chiaki.settings.placeboSigmoidEnabled
                        onToggled: Chiaki.settings.placeboSigmoidEnabled = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Увімкнено)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет сигмоїди:")
                        visible: Chiaki.settings.placeboSigmoidEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Власний"), qsTr("За замовчуванням")]
                        currentIndex: Chiaki.settings.placeboSigmoidPreset
                        onActivated: index => Chiaki.settings.placeboSigmoidPreset = index
                        visible: Chiaki.settings.placeboSigmoidEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Власний)")
                        visible: Chiaki.settings.placeboSigmoidEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Центр сигмоїди:")
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.00
                        to: 1.00
                        stepSize: 0.01
                        value: Chiaki.settings.placeboSigmoidCenter
                        onMoved: Chiaki.settings.placeboSigmoidCenter = value
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(2))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(0.75)")
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Нахил сигмоїди:")
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 1.0
                        to: 20.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboSigmoidSlope
                        onMoved: Chiaki.settings.placeboSigmoidSlope = value
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(6.5)")
                        visible: Chiaki.settings.placeboSigmoidEnabled && (Chiaki.settings.placeboSigmoidPreset == 0)
                    }
                }
            }

            Item {
                // Color
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Корекція кольору:")
                    }

                    C.CheckBox {
                        text: qsTr("Увімкнути корекцію кольору")
                        checked: Chiaki.settings.placeboColorAdjustmentEnabled
                        onToggled: Chiaki.settings.placeboColorAdjustmentEnabled = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Увімкнено)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет корекції кольору:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Власний"), qsTr("Нейтральний")]
                        currentIndex: Chiaki.settings.placeboColorAdjustmentPreset
                        onActivated: index => Chiaki.settings.placeboColorAdjustmentPreset = index
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Власний)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Яскравість:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: -1.00
                        to: 1.00
                        stepSize: 0.01
                        value: Chiaki.settings.placeboColorAdjustmentBrightness
                        onMoved: Chiaki.settings.placeboColorAdjustmentBrightness = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(2))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(0.00)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Контраст:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboColorAdjustmentContrast
                        onMoved: Chiaki.settings.placeboColorAdjustmentContrast = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1.0)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Насиченість:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboColorAdjustmentSaturation
                        onMoved: Chiaki.settings.placeboColorAdjustmentSaturation = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1.0)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Відтінок:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.00
                        to: 6.28
                        stepSize: 0.01
                        value: Chiaki.settings.placeboColorAdjustmentHue
                        onMoved: Chiaki.settings.placeboColorAdjustmentHue = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(2))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(0.00)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Гамма:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboColorAdjustmentGamma
                        onMoved: Chiaki.settings.placeboColorAdjustmentGamma = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1.0)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Температура:")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: -1.143
                        to: 5.286
                        stepSize: 0.001
                        value: Chiaki.settings.placeboColorAdjustmentTemperature
                        onMoved: Chiaki.settings.placeboColorAdjustmentTemperature = value
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(3))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(0.000)")
                        visible: Chiaki.settings.placeboColorAdjustmentEnabled && (Chiaki.settings.placeboColorAdjustmentPreset == 0)
                    }
                }
            }

            Item {
                // Peak Detection
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Визначення піку HDR:")
                    }

                    C.CheckBox {
                        text: qsTr("Увімкнути визначення піку HDR")
                        checked: Chiaki.settings.placeboPeakDetectionEnabled
                        onToggled: Chiaki.settings.placeboPeakDetectionEnabled = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Увімкнено)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет визначення піку:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Власний"), qsTr("За замовчуванням"), qsTr("Висока якість")]
                        currentIndex: Chiaki.settings.placeboPeakDetectionPreset
                        onActivated: index => Chiaki.settings.placeboPeakDetectionPreset = index
                        visible: Chiaki.settings.placeboPeakDetectionEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Висока якість)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Період згладжування піку:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 1000.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboPeakDetectionPeakSmoothingPeriod
                        onMoved: Chiaki.settings.placeboPeakDetectionPeakSmoothingPeriod = value
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(20.0)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Нижній поріг сцени:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboPeakDetectionSceneThresholdLow
                        onMoved: Chiaki.settings.placeboPeakDetectionSceneThresholdLow = value
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1.0)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Верхній поріг сцени:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboPeakDetectionSceneThresholdHigh
                        onMoved: Chiaki.settings.placeboPeakDetectionSceneThresholdHigh = value
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(3.0)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Перцентиль піку:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.001
                        value: Chiaki.settings.placeboPeakDetectionPeakPercentile
                        onMoved: Chiaki.settings.placeboPeakDetectionPeakPercentile = value
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(3))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(99.995)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Відсікання чорного:")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    C.Slider {
                        Layout.preferredWidth: 250
                        from: 0.0
                        to: 100.0
                        stepSize: 0.1
                        value: Chiaki.settings.placeboPeakDetectionBlackCutoff
                        onMoved: Chiaki.settings.placeboPeakDetectionBlackCutoff = value
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: qsTr(parent.value.toFixed(1))
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(1.0)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("Дозволити відкладений пік:")
                    visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }   

                    C.CheckBox {
                        text: qsTr("Увімкнути пік із затримкою в 1 кадр")
                        checked: Chiaki.settings.placeboPeakDetectionAllowDelayedPeak
                        onToggled: Chiaki.settings.placeboPeakDetectionAllowDelayedPeak = checked
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Вимкнено)")
                        visible: Chiaki.settings.placeboPeakDetectionEnabled && (Chiaki.settings.placeboPeakDetectionPreset == 0)
                    }
                }
            }

            Item {
                // Color Mapping
                GridLayout {
                    anchors {
                        top: parent.top
                        horizontalCenter: parent.horizontalCenter
                        topMargin: 20
                    }
                    columns: 3
                    rowSpacing: 10
                    columnSpacing: 20

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Відображення кольорів:")
                    }

                    C.CheckBox {
                        text: qsTr("Використати налаштування відображення кольорів")
                        checked: Chiaki.settings.placeboColorMappingEnabled
                        onToggled: Chiaki.settings.placeboColorMappingEnabled = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Увімкнено)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Пресет відображення кольорів:")
                        visible: Chiaki.settings.placeboColorMappingEnabled
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Власний"), qsTr("За замовчуванням"), qsTr("Висока якість")]
                        currentIndex: Chiaki.settings.placeboColorMappingPreset
                        onActivated: index => Chiaki.settings.placeboColorMappingPreset = index
                        visible: Chiaki.settings.placeboColorMappingEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("(Висока якість)")
                        visible: Chiaki.settings.placeboColorMappingEnabled
                    }

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: qsTr("Налаштування відображення кольорів:")
                        visible: Chiaki.settings.placeboColorMappingEnabled && Chiaki.settings.placeboColorMappingPreset == 0
                    }

                    C.Button {
                        text: qsTr("Відкрити")
                        onClicked: root.showPlaceboColorMappingDialog()
                        visible: Chiaki.settings.placeboColorMappingEnabled && Chiaki.settings.placeboColorMappingPreset == 0
                        Material.roundedScale: Material.SmallScale
                    }
                }
            }
        }
    }
}
