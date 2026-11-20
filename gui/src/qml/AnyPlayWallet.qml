// AnyPlay: баланс (передоплата за гру) — спільна логіка для вкладки «Баланс», бронювання і продовження гри.
// Використання: AnyPlayWallet { id: wallet }, далі wallet.on, wallet.money(…), wallet.quote(…).
// Старий сервер без балансу або адмін: wallet.on — false, і весь інтерфейс балансу сховано.
import QtQuick

import org.streetpea.chiaking

QtObject {
    id: w
    property var cloud: Chiaki.cloud
    readonly property bool on: !!cloud && cloud.hasWallet === true && cloud.admin !== true
    readonly property var data: (cloud && cloud.wallet) || ({})
    readonly property var balances: data.balances || []
    // звична валюта клієнта (валюта останньої броні, інакше гривня)
    readonly property string primary: data.primary || (balances.length ? balances[0].currency : "UAH")
    readonly property var history: data.history || []
    readonly property var topup: data.topup || ({})
    readonly property var pending: data.pending || []
    readonly property real primaryAmount: balance(primary)
    readonly property string primaryText: money(primaryAmount, primary)
    // інші валюти, де щось є (наприклад, злоті поруч з гривнями)
    readonly property var others: balances.filter(b => b.currency !== primary && Number(b.amount) > 0)

    // валюта способу оплати: uah → UAH, pln → PLN, usdt → USDT
    function currencyOf(method) {
        const m = String(method || "").toUpperCase();
        return m === "UAH" || m === "PLN" || m === "USDT" ? m : primary;
    }
    function entry(cur) {
        for (let i = 0; i < balances.length; i++)
            if (balances[i].currency === cur)
                return balances[i];
        return null;
    }
    function balance(cur) { const e = entry(cur); return e ? (Number(e.amount) || 0) : 0; }
    function symbol(cur) {
        const e = entry(cur);
        if (e && e.symbol)
            return e.symbol;
        return cur === "UAH" ? "₴" : (cur === "PLN" ? "zł" : String(cur || ""));
    }
    // «320 ₴», «1 000 ₴», «500,37 ₴»; signed — зі знаком: «+500 ₴», «−75 ₴»
    function money(amount, cur, signed) {
        const n = Number(amount) || 0, cents = Math.round(Math.abs(n) * 100);
        let s = String(Math.floor(cents / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
        if (cents % 100)
            s += "," + String(cents % 100).padStart(2, "0");
        const sign = n < 0 && cents ? "−" : (signed && cents ? "+" : "");
        return sign + s + " " + symbol(cur);
    }
    // число з рядка ціни сервера: «250.00 ₴», «1 000 ₴», «200,41 zł» → 250, 1000, 200.41
    function parse(text) {
        if (typeof text === "number")
            return text;
        const m = String(text || "").replace(/[\s  ]/g, "").replace(",", ".").match(/\d+(\.\d+)?/);
        return m ? Number(m[0]) : NaN;
    }
    // ціна від сервера («250.00 грн», «22.00 zł») у тому ж вигляді, що й суми балансу: «250 ₴», «22 zł».
    // Без балансу (старий сервер) — як дав сервер
    function price(text) {
        const s = String(text === undefined || text === null ? "" : text);
        const m = s.replace(/[\u00a0\u202f]/g, " ").match(/^\s*(\d[\d ]*(?:[.,]\d+)?)\s*(грн|₴|zł|USDT)\s*$/i);
        if (!on || !m)
            return s;
        const cur = /zł/i.test(m[2]) ? "PLN" : (/usdt/i.test(m[2]) ? "USDT" : "UAH");
        return money(Number(m[1].replace(/ /g, "").replace(",", ".")), cur);
    }
    // скільки з балансу піде на ціну варіанта (тариф броні чи +N год продовження) у валюті способу оплати.
    // Сервер дає готову відповідь для кожного способу: walletBy[спосіб] = {walletOk, walletPart} (там уже враховано,
    // наприклад, резерв неоплаченого продовження, яке новий вибір замінить); інакше — walletOk / walletPart варіанта.
    function quote(o, priceText, method) {
        const cur = currencyOf(method);
        let bal = balance(cur);
        let price = parse(priceText);
        if (!(price > 0))
            price = 0;
        let ok = bal > 0 && price > 0 && bal + 0.004 >= price;
        let part = Math.min(bal, price);
        const by = o && o.walletBy ? o.walletBy[method] : null;
        if (by && typeof by.walletOk === "boolean") {
            ok = by.walletOk && price > 0;
            part = ok ? price : (by.walletPart ? Math.min(Number(by.walletPart.amount) || 0, price) : 0);
            bal = Math.max(bal, part);   // доступно для цієї оплати
        } else if (o) {
            // підказку беремо, лише якщо вона саме для цієї валюти: окремо для способу, з валютою в walletPart,
            // або без валюти взагалі — тоді сервер рахував у звичній валюті клієнта
            const perMethod = o.walletOk !== null && typeof o.walletOk === "object";
            let wp = o.walletPart;
            if (wp !== null && typeof wp === "object" && wp.amount === undefined)
                wp = wp[method];
            const hintCur = (wp && typeof wp === "object" && wp.currency) || o.walletCurrency || "";
            if (perMethod || (hintCur ? hintCur === cur : cur === primary)) {
                const wo = perMethod ? o.walletOk[method] : o.walletOk;
                if (typeof wo === "boolean")
                    ok = wo && price > 0;
                if (wp !== undefined && wp !== null) {
                    const v = typeof wp === "object" ? Number(wp.amount) : Number(wp);
                    if (v >= 0)
                        part = Math.min(v, price);
                }
            }
        }
        if (ok)
            part = price;
        return { currency: cur, balance: bal, price: price, ok: ok, part: part,
                 rest: Math.max(0, Math.round((price - part) * 100) / 100), after: Math.max(0, Math.round((bal - price) * 100) / 100) };
    }
    // чим доплачують решту: гривні й злоті карткою, USDT переказом
    function viaText(method) { return String(method) === "usdt" ? qsTr("переказом") : qsTr("карткою"); }
    function transferText(method) {
        return String(method) === "usdt" ? qsTr("уся сума переказом USDT") : qsTr("уся сума карткою, Apple Pay, Google Pay");
    }
    // дата для історії, якщо сервер не дав підпису: «сьогодні», «вчора» або «18.11»
    function dayText(ts) {
        if (!(ts > 0))
            return "";
        const d = new Date(ts * 1000), t = new Date();
        t.setHours(0, 0, 0, 0);
        const diff = Math.round((t - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 86400000);
        if (diff === 0) return qsTr("сьогодні");
        if (diff === 1) return qsTr("вчора");
        return d.getDate() + "." + String(d.getMonth() + 1).padStart(2, "0");
    }
}
