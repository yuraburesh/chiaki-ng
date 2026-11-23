// AnyPlay: текст нового дизайну. Одна обгортка для всіх ролей, щоб розміри й шрифти були однакові всюди.
// role: cap — підпис розділу великими літерами; h2 — заголовок екрана; big — великий напис на головному;
// eyebrow — блакитний надпис над таймером; lead — пояснення під заголовком; hint — коротка підказка;
// body — звичайний текст; small — дрібний сірий текст; title — назва в рядку списку.
import QtQuick

Text {
    id: t
    property string role: "body"
    property bool rich: false          // true — можна <b>…</b> у тексті (лише для наших власних рядків)
    property real size: 0              // свій розмір (0 — за роллю)
    readonly property bool display: role === "cap" || role === "h2" || role === "big" || role === "eyebrow"
    AnyPlayStyle { id: ap }

    textFormat: rich ? Text.StyledText : Text.PlainText
    wrapMode: Text.WordWrap
    color: role === "eyebrow" ? ap.accent
         : (role === "lead" || role === "hint" || role === "cap") ? ap.mute
         : role === "small" ? ap.faint
         : ap.ink
    linkColor: ap.cyan
    lineHeight: role === "lead" ? 1.18 : (role === "big" ? 0.74 : 1.0)   // «big»: рядки щільно, як у макеті (у Oswald великий власний інтервал)
    font.family: display ? ap.display : ap.body
    font.capitalization: display ? Font.AllUppercase : Font.MixedCase
    font.pixelSize: size > 0 ? size
        : role === "cap" ? ap.fsCap
        : role === "h2" ? ap.fsH2
        : role === "big" ? ap.fsBig
        : role === "eyebrow" ? 15
        : role === "lead" ? ap.fsLead
        : role === "small" ? ap.fsSub
        : ap.fsBody
    font.weight: (role === "cap" || role === "h2" || role === "big") ? Font.DemiBold
        : (role === "eyebrow" || role === "title") ? Font.Medium
        : Font.Normal
    font.letterSpacing: role === "cap" ? ap.capSpacing : role === "eyebrow" ? 3 : (role === "h2" || role === "big") ? 1.6 : 0
}
