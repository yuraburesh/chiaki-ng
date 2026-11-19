import QtQuick

// Новий дизайн AnyPlay: стиль екрана налаштувань гри.
// Приглушений вечірній градієнт, Oswald великими літерами для заголовків і кнопок, Inter для тексту,
// тонкі лінії між рядками, білі суцільні кнопки з ледь заокругленими кутами, без яскравих рамок і «карток».
// Використання: AnyPlayStyle { id: ap } у будь-якому файлі, далі ap.ink, ap.display тощо.
QtObject {
    // фон: градієнт 160° від bg1 через bg2 до bg3
    readonly property color bg1: "#2b2740"
    readonly property color bg2: "#4a3558"
    readonly property color bg3: "#7a4a63"
    readonly property color ink: "#f5f3f7"          // основний текст, білі кнопки
    readonly property color mute: "#a6ffffff"       // другорядний текст
    readonly property color faint: "#6bffffff"      // підписи під рядками
    readonly property color hair: "#1fffffff"       // тонкі лінії між рядками
    readonly property color edge: "#40ffffff"       // рамки другорядних кнопок і фішок
    readonly property color panel: "#0dffffff"      // ледь помітна підкладка
    readonly property color dialog: "#f22a2639"     // вікна поверх екрана
    readonly property color dark: "#221d2e"         // текст на білих кнопках
    readonly property color cyan: "#8fe3ff"         // підсвітка, «йде гра», активне
    readonly property color gold: "#ffd9a0"         // таймер гри, «чекає оплату»
    readonly property color ok: "#c9f5d8"           // «оплачено»
    readonly property color bad: "#ff9a9a"          // помилки, «вийти з гри»
    readonly property color veil: "#cc0a0516"       // затемнення під вікнами

    readonly property string display: "Oswald"      // заголовки, вкладки, кнопки: великими літерами з розрядкою
    readonly property string body: "Inter"          // увесь інший текст

    // розміри
    readonly property int radius: 2                 // кнопки
    readonly property int chipRadius: 3             // фішки клавіш і статусів
    readonly property int rowHeight: 52             // рядок списку з тонкою лінією знизу
    readonly property real capSpacing: 1.8          // розрядка для підписів великими літерами
}
