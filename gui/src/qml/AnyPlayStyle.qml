import QtQuick

// AnyPlay 112: єдиний дизайн програми — «Vice City 2026».
// Нічне небо (глибокий фіолетовий → пурпур → маджента), теплий захід сонця як єдиний акцент головних дій
// (рожевий → помаранчевий), скляні панелі з тонким світлим краєм, об'ємні кнопки з тінню й відгуком на наведення і натиск.
// Oswald великими літерами — заголовки, вкладки, кнопки; Inter — увесь текст.
// Використання: AnyPlayStyle { id: ap } у будь-якому файлі, далі ap.ink, ap.display, ap.tHover тощо.
// Ніяких «своїх» кольорів у сторінках: лише ці токени й компоненти Ap*.qml (опис: scratchpad/team4/компоненти.md).
QtObject {
    // ── тло: нічне небо Vice City ──
    readonly property color bg1: "#1b1230"          // верх: глибока ніч
    readonly property color bg2: "#3a1d55"          // середина: фіолетовий
    readonly property color bg3: "#6e2557"          // низ: маджента над обрієм
    readonly property color glowSun: "#ff7a45"      // сонце біля обрію (м'яке світіння тла)
    readonly property color glowPink: "#ff3d8b"     // рожевий серпанок

    // ── акцент: захід сонця (головні дії, поточна вкладка, вибране) ──
    readonly property color accentA: "#ff4f8b"      // рожевий
    readonly property color accentB: "#ff8a3d"      // помаранчевий
    readonly property color accent: "#ff6a6a"       // середина градієнта (одним кольором: рамки, позначки)
    readonly property color inkAccent: "#ffffff"     // текст на акценті

    // ── текст ──
    readonly property color ink: "#f7f3fb"          // основний текст
    readonly property color mute: "#c2ffffff"       // другорядний текст
    readonly property color faint: "#8cffffff"      // підписи під рядками
    readonly property color dark: "#1d1430"         // текст на світлих кнопках

    // ── лінії, скло ──
    readonly property color hair: "#1affffff"       // тонкі лінії між рядками
    readonly property color edge: "#33ffffff"       // край скляних кнопок і фішок
    readonly property color edgeHi: "#66ffffff"     // край під наведенням
    readonly property color glass: "#14ffffff"      // скляна кнопка / поле
    readonly property color glassHi: "#24ffffff"    // скло під наведенням
    readonly property color card: "#26120a24"       // скляна панель (картка) на тлі
    readonly property color cardEdge: "#1fffffff"   // край картки
    readonly property color cardTop: "#0dffffff"    // світліша смужка вгорі картки (об'єм)
    readonly property color panel: "#0dffffff"      // ледь помітна підкладка (сумісність)
    readonly property color dialog: "#f21c1430"     // вікна поверх екрана
    readonly property color veil: "#cc0a0516"       // затемнення під вікнами
    readonly property color shadow: "#66000000"     // тінь під кнопками й картками

    // ── стани ──
    readonly property color cyan: "#7fe6ff"         // фокус з клавіатури, «йде гра», живе
    readonly property color gold: "#ffd27a"         // таймер гри, «чекає оплату»
    readonly property color ok: "#9ef0bf"           // «оплачено», «картинка плавна»
    readonly property color bad: "#ff8f8f"          // помилки, «вийти з гри», небезпечні дії

    readonly property string display: "Oswald"      // заголовки, вкладки, кнопки: великими літерами з розрядкою
    readonly property string body: "Inter"          // увесь інший текст

    // ── розміри ──
    readonly property int radius: 10                // кнопки, поля
    readonly property int radiusSmall: 7            // малі кнопки, вкладки
    readonly property int chipRadius: 6             // фішки статусів і клавіш
    readonly property int cardRadius: 14            // скляні панелі
    readonly property int rowHeight: 56             // рядок списку
    readonly property real capSpacing: 2.0          // розрядка для підписів великими літерами

    // ── шрифти (логічні пікселі) ──
    readonly property int fsBody: 15                // звичайний текст, назви рядків
    readonly property int fsSub: 13                 // підписи під рядками
    readonly property int fsCap: 13                 // підписи розділів великими літерами
    readonly property int fsLead: 16                // пояснення під заголовком
    readonly property int fsH2: 30                  // заголовок сторінки
    readonly property int fsBig: 52                 // великий напис (ім'я гравця, таймер)
    readonly property int fsButton: 17              // головна кнопка
    readonly property int fsButtonSmall: 14         // мала кнопка

    // ── рух: однаковий відгук усюди ──
    readonly property int tHover: 150               // наведення: підйом і світіння
    readonly property int tPress: 90                // натиск: опускання
    readonly property real lift: 2                  // на скільки піднімається під наведенням, px
    readonly property real pressScale: 0.97         // стискання під натиском
}
