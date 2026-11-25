// AnyPlay 116: QR-код посилання на трансляцію (сервер QR не дає — малюємо самі). Без бібліотек: байтовий режим,
// рівень корекції L, версії 1–5 (до 106 байтів — посилання watch.html?r=КОД влазить із запасом), маска 0.
// Алгоритм — за стандартом ISO/IEC 18004 (як у відкритій реалізації Nayuki). Малюється один раз на Canvas,
// перемальовується лише коли змінився текст або розмір. Чорні модулі на білому, тиха зона 2 модулі.
import QtQuick

Rectangle {
    id: qr
    property string text: ""
    readonly property var matrix: encode(text)
    readonly property bool valid: matrix.length > 0
    color: "#ffffff"
    radius: 6

    function gfMul(x, y) {
        let z = 0;
        for (let i = 7; i >= 0; i--) {
            z = (z << 1) ^ ((z >>> 7) * 0x11D);
            z ^= ((y >>> i) & 1) * x;
        }
        return z & 0xFF;
    }
    function rsDivisor(degree) {
        const r = [];
        for (let i = 0; i < degree - 1; i++) r.push(0);
        r.push(1);
        let root = 1;
        for (let i = 0; i < degree; i++) {
            for (let j = 0; j < r.length; j++) {
                r[j] = gfMul(r[j], root);
                if (j + 1 < r.length) r[j] ^= r[j + 1];
            }
            root = gfMul(root, 0x02);
        }
        return r;
    }
    function rsRemainder(data, divisor) {
        const r = divisor.map(() => 0);
        for (let k = 0; k < data.length; k++) {
            const factor = data[k] ^ r.shift();
            r.push(0);
            for (let i = 0; i < r.length; i++) r[i] ^= gfMul(divisor[i], factor);
        }
        return r;
    }
    function encode(s) {
        if (!s) return [];
        const utf8 = unescape(encodeURIComponent(s));
        const bytes = [];
        for (let i = 0; i < utf8.length; i++) bytes.push(utf8.charCodeAt(i) & 0xFF);
        const dataCw = [0, 19, 34, 55, 80, 108], ecCw = [0, 7, 10, 15, 20, 26];
        let ver = 0;
        for (let v = 1; v <= 5; v++) if (4 + 8 + 8 * bytes.length <= dataCw[v] * 8) { ver = v; break; }
        if (!ver) return [];
        // біти: режим 0100, довжина (8 біт), байти, кінець, доповнення
        const bits = [];
        const put = (val, n) => { for (let i = n - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
        put(4, 4); put(bytes.length, 8);
        for (let i = 0; i < bytes.length; i++) put(bytes[i], 8);
        const cap = dataCw[ver] * 8;
        put(0, Math.min(4, cap - bits.length));
        put(0, (8 - bits.length % 8) % 8);
        for (let pad = 0xEC; bits.length < cap; pad ^= 0xEC ^ 0x11) put(pad, 8);
        const data = [];
        for (let i = 0; i < bits.length; i += 8) {
            let b = 0;
            for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
            data.push(b);
        }
        const all = data.concat(rsRemainder(data, rsDivisor(ecCw[ver])));
        // матриця
        const size = ver * 4 + 17;
        const m = [], fn = [];
        for (let y = 0; y < size; y++) { m.push(new Array(size).fill(false)); fn.push(new Array(size).fill(false)); }
        const setF = (x, y, dark) => { m[y][x] = dark; fn[y][x] = true; };
        for (let i = 0; i < size; i++) { setF(6, i, i % 2 === 0); setF(i, 6, i % 2 === 0); }   // смуги синхронізації
        const finder = (cx, cy) => {
            for (let dy = -4; dy <= 4; dy++)
                for (let dx = -4; dx <= 4; dx++) {
                    const x = cx + dx, y = cy + dy;
                    if (x < 0 || y < 0 || x >= size || y >= size) continue;
                    const d = Math.max(Math.abs(dx), Math.abs(dy));
                    setF(x, y, d !== 2 && d !== 4);
                }
        };
        finder(3, 3); finder(size - 4, 3); finder(3, size - 4);
        if (ver >= 2) {   // один вирівнювальний знак (версії 2–6)
            const c = size - 7;
            for (let dy = -2; dy <= 2; dy++)
                for (let dx = -2; dx <= 2; dx++)
                    setF(c + dx, c + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }
        // формат: рівень L (01), маска 0
        const fmt = (1 << 3) | 0;
        let rem = fmt;
        for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
        const fb = ((fmt << 10) | rem) ^ 0x5412;
        const bit = (i) => ((fb >>> i) & 1) !== 0;
        for (let i = 0; i <= 5; i++) setF(8, i, bit(i));
        setF(8, 7, bit(6)); setF(8, 8, bit(7)); setF(7, 8, bit(8));
        for (let i = 9; i < 15; i++) setF(14 - i, 8, bit(i));
        for (let i = 0; i < 8; i++) setF(size - 1 - i, 8, bit(i));
        for (let i = 8; i < 15; i++) setF(8, size - 15 + i, bit(i));
        setF(8, size - 8, true);
        // дані змійкою знизу справа, з маскою 0 ((x + y) парне — інвертувати)
        let k = 0;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let vert = 0; vert < size; vert++)
                for (let j = 0; j < 2; j++) {
                    const x = right - j;
                    const up = ((right + 1) & 2) === 0;
                    const y = up ? size - 1 - vert : vert;
                    if (fn[y][x]) continue;
                    let dark = false;
                    if (k < all.length * 8) { dark = ((all[k >>> 3] >>> (7 - (k & 7))) & 1) !== 0; k++; }
                    m[y][x] = dark !== ((x + y) % 2 === 0);
                }
        }
        return m;
    }

    Canvas {
        id: cv
        anchors.fill: parent
        anchors.margins: 4
        renderStrategy: Canvas.Immediate
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const mx = qr.matrix;
            if (!mx.length) return;
            const n = mx.length + 4;   // тиха зона 2 модулі з кожного боку (плюс біле поле картки)
            const cell = Math.floor(Math.min(width, height) / n);
            const off = Math.floor((Math.min(width, height) - cell * n) / 2) + 2 * cell;
            ctx.fillStyle = "#000000";
            for (let y = 0; y < mx.length; y++)
                for (let x = 0; x < mx.length; x++)
                    if (mx[y][x]) ctx.fillRect(off + x * cell, off + y * cell, cell, cell);
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
    onMatrixChanged: cv.requestPaint()
}
