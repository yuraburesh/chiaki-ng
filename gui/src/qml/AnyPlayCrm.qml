// AnyPlay: повна CRM усередині програми (та сама сторінка, що в боті): броні й зайняті години, скасування й повернення,
// баланси, клієнти, завантаження програми, прибуток, адміни з правами, чати, тексти, оплата, розсилка, система.
// Вхід без Telegram: програма дає сторінці токен цього комп'ютера (window.AnyPlayApp), лише на адресі нашого сервера;
// сервер пускає за ним так само, як за входом з Telegram, і з тими самими правами адміна.
// Окремий профіль без збереження на диск: після закриття програми в браузері нічого не лишається.
// Посилання на інші сайти, t.me і tg:// відкриваються зовні (у браузері або в Telegram).
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: crm
    property var cloud: Chiaki.cloud
    property real contentWidth: width
    property var web: null
    property string failure: ""          // помилка завантаження сторінки
    readonly property bool available: cloud.webEngine && web !== null
    signal back()
    AnyPlayStyle { id: ap }

    function reload() {
        failure = "";
        if (web)
            web.reload();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: crm.contentWidth
            Layout.maximumWidth: crm.contentWidth
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 6
            Layout.bottomMargin: 8
            spacing: 12
            ApButton {
                small: true; ghost: true
                text: qsTr("← Панель")
                onClicked: crm.back()
            }
            ApText { role: "eyebrow"; text: qsTr("CRM") }
            ApText {
                Layout.fillWidth: true
                role: "small"
                elide: Text.ElideRight
                text: crm.web && crm.web.loading ? qsTr("завантажую…") : qsTr("усе, що в CRM у боті: броні, клієнти, баланси, адміни")
            }
            ApButton {
                visible: crm.available
                small: true; ghost: true
                text: qsTr("Оновити")
                onClicked: crm.reload()
            }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            color: "transparent"
            Rectangle {   // тонка смужка завантаження
                visible: !!crm.web && crm.web.loading
                height: parent.height
                width: parent.width * (crm.web ? crm.web.loadProgress : 0) / 100
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
        }
        Item {
            id: holder
            Layout.fillWidth: true
            Layout.fillHeight: true

            // без вбудованого браузера (або якщо він не запустився): CRM лишається в боті
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 520)
                visible: !crm.available || crm.failure !== ""
                spacing: 12
                ApText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    role: "lead"
                    text: crm.failure !== "" ? crm.failure
                        : qsTr("У цій збірці програми немає вбудованого браузера, тож CRM відкривається в боті: кнопка «CRM» внизу зліва.")
                }
                Flow {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 10
                    ApButton { visible: crm.failure !== ""; text: qsTr("Спробувати ще"); onClicked: crm.reload() }
                    ApButton { ghost: true; text: qsTr("Відкрити в боті"); onClicked: crm.cloud.openBot() }
                }
            }

            Component.onCompleted: {
                if (!crm.cloud.webEngine)
                    return;
                try {
                    crm.web = Qt.createQmlObject("
                        import QtQuick
                        import QtWebEngine
                        WebEngineView {
                            id: v
                            property var cloud
                            signal failed(string text)
                            profile: WebEngineProfile { offTheRecord: true }
                            settings.javascriptCanOpenWindows: true
                            settings.localStorageEnabled: true
                            backgroundColor: '#2b2740'
                            function start(code, address) {
                                const s = WebEngine.script();
                                s.name = 'anyplay-app';
                                s.sourceCode = code;
                                s.injectionPoint = WebEngineScript.DocumentCreation;
                                s.worldId = WebEngineScript.MainWorld;
                                s.runsOnSubFrames = false;
                                v.userScripts.insert(s);
                                v.url = address;
                            }
                            onContextMenuRequested: (request) => request.accepted = true
                            onNavigationRequested: (request) => {
                                if (v.cloud.isOwnUrl(request.url)) { request.accept(); return; }
                                request.reject();
                                if (request.isMainFrame)
                                    v.cloud.openExternal(request.url);
                            }
                            onNewWindowRequested: (request) => {
                                if (v.cloud.isOwnUrl(request.requestedUrl))
                                    v.url = request.requestedUrl;
                                else
                                    v.cloud.openExternal(request.requestedUrl);
                            }
                            onLoadingChanged: (info) => {
                                // 3 — сторінку не завантажено; -3 — завантаження перервали (новий перехід), це не помилка
                                if (info.status === 3 && info.errorCode !== -3)
                                    v.failed(qsTr('Не вдалося відкрити CRM: немає зв\\'язку з сервером.'));
                            }
                            onCertificateError: (error) => console.error(error.description)
                        }", holder, "anyplayCrm");
                    crm.web.cloud = crm.cloud;
                    crm.web.anchors.fill = holder;
                    crm.web.failed.connect((t) => crm.failure = t);
                    crm.web.visible = Qt.binding(() => crm.failure === "");
                    const code = crm.cloud.webAppScript();
                    if (!code) {
                        crm.failure = qsTr("Спершу увійди в програму через Telegram.");
                        return;
                    }
                    crm.web.start(code, crm.cloud.crmUrl());
                } catch (error) {
                    console.error("AnyPlay CRM: WebEngine view failed: " + error);
                    if (crm.web) { crm.web.destroy(); }
                    crm.web = null;
                }
            }
        }
    }
}
