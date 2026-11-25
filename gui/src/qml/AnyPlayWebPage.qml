// AnyPlay 116: сторінка нашого сервера у вбудованому браузері — «Дивитись» трансляцію друга (watch.html: відео, голос,
// чат, керування для помічника) і подарунки та друзі (book.html#…). Той самий підхід, що в AnyPlayCrm:
// - програма дає сторінці токен цього комп'ютера (window.AnyPlayApp) лише на адресі нашого сервера;
// - окремий профіль без збереження на диск; інші сайти, t.me і tg:// відкриваються зовні;
// - мікрофон (голос у трансляції) дозволяємо лише нашій сторінці, і лише мікрофон (без камери й екрана).
// Без вбудованого браузера (або якщо він не запустився) — пояснення й «Відкрити в боті».
// Сторінку створюють, коли її відкрили, і знищують, коли закрили (Loader у AnyPlayFriends): відео й мікрофон
// зупиняються разом з нею.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

import org.streetpea.chiaking

Item {
    id: wp
    property var cloud: Chiaki.cloud
    property string url: ""
    property string title: ""                 // підпис зліва вгорі («Трансляція Андрія», «Подарунок»)
    property string backText: qsTr("← Друзі")
    property bool allowMic: false             // watch.html: голос у трансляції
    property bool showBack: true              // вкладка «Друзі» з book.html#friends: сторінка й є вкладкою, «назад» не треба
    property real contentWidth: width
    property var web: null
    property string failure: ""
    readonly property bool available: !!cloud && cloud.webEngine === true && web !== null
    signal back()
    signal moved(string address)              // сторінка перейшла на іншу адресу (book.html → watch.html?r=КОД і назад)
    AnyPlayStyle { id: ap }

    function reload() { failure = ""; if (web) web.reload(); }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: wp.contentWidth
            Layout.maximumWidth: wp.contentWidth
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 6
            Layout.bottomMargin: 8
            spacing: 12
            ApButton { visible: wp.showBack; small: true; ghost: true; text: wp.backText; onClicked: wp.back() }
            ApText { role: "eyebrow"; text: wp.title; elide: Text.ElideRight; Layout.maximumWidth: 420; wrapMode: Text.NoWrap }
            ApText {
                Layout.fillWidth: true
                role: "small"
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                text: wp.web && wp.web.loading ? qsTr("завантажую…") : ""
            }
            ApButton { visible: wp.available; small: true; ghost: true; text: qsTr("Оновити"); onClicked: wp.reload() }
        }
        Item {   // тонка смужка завантаження
            Layout.fillWidth: true
            Layout.preferredHeight: 2
            Rectangle {
                visible: !!wp.web && wp.web.loading
                height: parent.height
                width: parent.width * (wp.web ? wp.web.loadProgress : 0) / 100
                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: ap.accentA } GradientStop { position: 1; color: ap.accentB } }
            }
        }
        Item {
            id: holder
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 560)
                visible: !wp.available || wp.failure !== ""
                spacing: 12
                ApText {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    role: "lead"
                    text: wp.failure !== "" ? wp.failure
                        : qsTr("У цій збірці програми немає вбудованого браузера. Відкрий це в боті: там те саме.")
                }
                Flow {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 10
                    ApButton { visible: wp.failure !== ""; text: qsTr("Спробувати ще"); onClicked: wp.reload() }
                    ApButton { ghost: true; text: qsTr("Відкрити в боті"); onClicked: wp.cloud.openBot() }
                }
            }

            // Qt 6.8+: permissionRequested (WebEnginePermission); старіший Qt: featurePermissionRequested
            readonly property string viewHead: "
                import QtQuick
                import QtWebEngine
                WebEngineView {
                    id: v
                    property var cloud
                    property bool allowMic: false
                    signal failed(string text)
                    signal moved(string address)
                    onUrlChanged: v.moved(v.url.toString())
                    profile: WebEngineProfile { offTheRecord: true }
                    settings.javascriptCanOpenWindows: true
                    settings.localStorageEnabled: true
                    settings.playbackRequiresUserGesture: false
                    backgroundColor: '#1b1230'
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
                        if (info.status === 3 && info.errorCode !== -3)
                            v.failed(qsTr('Не вдалося відкрити сторінку: немає зв\\'язку з сервером.'));
                    }
                    onCertificateError: (error) => console.error(error.description)
            "
            readonly property string permNew: "
                    onPermissionRequested: (p) => {
                        const mic = p.permissionType === WebEnginePermission.PermissionType.MediaAudioCapture;
                        if (mic && v.allowMic && v.cloud.isOwnUrl(p.origin)) p.grant(); else p.deny();
                    }
                }"
            readonly property string permOld: "
                    onFeaturePermissionRequested: (origin, feature) => {
                        const ok = feature === WebEngineView.MediaAudioCapture && v.allowMic && v.cloud.isOwnUrl(origin);
                        v.grantFeaturePermission(origin, feature, ok);
                    }
                }"

            function create() {
                if (!wp.cloud || wp.cloud.webEngine !== true || wp.url === "")
                    return;
                const variants = [viewHead + permNew, viewHead + permOld];
                for (let i = 0; i < variants.length && !wp.web; i++) {
                    try {
                        wp.web = Qt.createQmlObject(variants[i], holder, "anyplayWeb");
                    } catch (error) {
                        if (i === variants.length - 1)
                            console.error("AnyPlay web page: WebEngine view failed: " + error);
                    }
                }
                if (!wp.web)
                    return;
                wp.web.cloud = wp.cloud;
                wp.web.allowMic = wp.allowMic;
                wp.web.anchors.fill = holder;
                wp.web.failed.connect((t) => wp.failure = t);
                wp.web.moved.connect((u) => wp.moved(u));
                wp.web.visible = Qt.binding(() => wp.failure === "");
                const code = wp.cloud.webAppScript();
                if (!code) {
                    wp.failure = qsTr("Спершу увійди в програму через Telegram.");
                    return;
                }
                wp.web.start(code, wp.url);
            }
            Component.onCompleted: create()
        }
    }
    onUrlChanged: if (web && url !== "") { failure = ""; web.url = url; }
}
