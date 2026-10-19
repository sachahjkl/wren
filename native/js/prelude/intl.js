// A minimal ECMA-402 (Intl) for the engine, which has none: what sites use most (dates, numbers, plurals, relative
// times, lists, collation), with the conventions of English (United States) whatever locale is asked for, in the
// realm's own time zone (and UTC). Run once at pre-initialization; the browser's locale and time zone are read on first
// use through the native function it is given. Shapes and option names follow ECMA-402 so code written for real Intl
// runs; exotic options are accepted and approximated.
(function (host) {
  "use strict";
  const def = (o, name, value) => Object.defineProperty(o, name, { value, writable: true, configurable: true, enumerable: false });
  let info = null;
  const hostInfo = () => info || (info = host());   // { locale, timeZone }
  const LOCALE = () => "en-US";
  const toObject = (o) => (o === undefined ? Object.create(null) : Object(o));
  const getOpt = (o, name, values, fallback) => {
    let v = o[name];
    if (v === undefined) return fallback;
    v = typeof fallback === "boolean" ? Boolean(v) : String(v);
    if (values && !values.includes(v)) throw new RangeError(`Value ${v} out of range for Intl option ${name}`);
    return v;
  };
  const getNum = (o, name, min, max, fallback) => {
    let v = o[name];
    if (v === undefined) return fallback;
    v = Number(v);
    if (!(v >= min && v <= max)) throw new RangeError(`${name} value is out of range.`);
    return Math.floor(v);
  };
  const canonicalTag = (tag) => {
    if (typeof tag !== "string" && !(typeof tag === "object" && tag)) throw new TypeError("Language ID should be string or object.");
    const parts = String(tag).replace(/_/g, "-").split("-");
    if (!/^[A-Za-z]{2,8}$/.test(parts[0])) throw new RangeError(`Incorrect locale information provided`);
    return parts.map((p, i) => (i === 0 ? p.toLowerCase() : p.length === 2 ? p.toUpperCase() : p.length === 4 ? p[0].toUpperCase() + p.slice(1).toLowerCase() : p.toLowerCase())).join("-");
  };
  const getCanonicalLocales = (locales) => {
    if (locales === undefined) return [];
    const list = typeof locales === "string" ? [locales] : Array.from(locales);
    const out = [];
    for (const l of list) { const c = canonicalTag(l); if (!out.includes(c)) out.push(c); }
    return out;
  };
  const supportedLocalesOf = (locales) => getCanonicalLocales(locales).filter((l) => l === "en" || l.startsWith("en-"));

  // ---- numbers ----
  const group = (digits, sep) => digits.replace(/\B(?=(\d{3})+(?!\d))/g, sep);
  const CURRENCY_SYMBOLS = { USD: "$", EUR: "€", GBP: "£", JPY: "¥", CNY: "CN¥", INR: "₹", KRW: "₩", CAD: "CA$", AUD: "A$", CHF: "CHF", BRL: "R$", RUB: "RUB", MXN: "MX$" };
  const CURRENCY_DIGITS = { JPY: 0, KRW: 0, CLP: 0, VND: 0, ISK: 0, HUF: 2, BHD: 3, KWD: 3, JOD: 3, OMR: 3, TND: 3 };
  const UNITS = { byte: ["byte", "B"], kilobyte: ["kilobyte", "kB"], megabyte: ["megabyte", "MB"], gigabyte: ["gigabyte", "GB"], terabyte: ["terabyte", "TB"],
    bit: ["bit", "bit"], kilobit: ["kilobit", "kb"], megabit: ["megabit", "Mb"], percent: ["percent", "%"], second: ["second", "sec"], minute: ["minute", "min"],
    hour: ["hour", "hr"], day: ["day", "day"], week: ["week", "wk"], month: ["month", "mth"], year: ["year", "yr"], millisecond: ["millisecond", "ms"],
    meter: ["meter", "m"], kilometer: ["kilometer", "km"], centimeter: ["centimeter", "cm"], millimeter: ["millimeter", "mm"], mile: ["mile", "mi"],
    foot: ["foot", "ft"], inch: ["inch", "in"], kilogram: ["kilogram", "kg"], gram: ["gram", "g"], pound: ["pound", "lb"], liter: ["liter", "L"],
    celsius: ["degree Celsius", "°C"], fahrenheit: ["degree Fahrenheit", "°F"], "kilometer-per-hour": ["kilometer per hour", "km/h"], "mile-per-hour": ["mile per hour", "mph"] };

  function roundTo(x, minFrac, maxFrac, minSig, maxSig) {
    if (maxSig !== undefined) {
      if (x === 0) return minSig > 1 ? "0." + "0".repeat(minSig - 1) : "0";
      let s = Number(x.toPrecision(maxSig)).toString();
      if (/e/.test(s)) s = Number(s).toFixed(Math.max(0, maxSig - 1 - Math.floor(Math.log10(Math.abs(x)))));
      const sig = s.replace(/^0\.?0*|\./g, "").length;
      if (sig < minSig) s = Number(s).toPrecision(minSig);
      if (/e/.test(s)) s = Number(s).toFixed(20).replace(/0+$/, "").replace(/\.$/, "");
      return s;
    }
    let s = x.toFixed(Math.min(maxFrac, 100));
    if (maxFrac > minFrac && s.includes(".")) {
      s = s.replace(/0+$/, "");
      const frac = s.split(".")[1] || "";
      if (frac.length < minFrac) s = s.split(".")[0] + "." + frac.padEnd(minFrac, "0");
      s = s.replace(/\.$/, "");
    }
    return s;
  }

  function NumberFormat(locales, options) {
    if (!new.target) return new NumberFormat(locales, options);
    getCanonicalLocales(locales);
    const o = toObject(options);
    const style = getOpt(o, "style", ["decimal", "percent", "currency", "unit"], "decimal");
    const currency = o.currency === undefined ? undefined : String(o.currency).toUpperCase();
    if (style === "currency" && currency === undefined) throw new TypeError("Currency code is required with currency style.");
    const unit = o.unit === undefined ? undefined : String(o.unit);
    if (style === "unit" && unit === undefined) throw new TypeError("Unit is required with unit style.");
    const cdigits = currency in CURRENCY_DIGITS ? CURRENCY_DIGITS[currency] : 2;
    const minFracDefault = style === "currency" ? cdigits : 0;
    const maxFracDefault = style === "currency" ? cdigits : style === "percent" ? 0 : 3;
    const notation = getOpt(o, "notation", ["standard", "scientific", "engineering", "compact"], "standard");
    let minFrac = getNum(o, "minimumFractionDigits", 0, 100, undefined);
    let maxFrac = getNum(o, "maximumFractionDigits", 0, 100, undefined);
    if (minFrac === undefined) minFrac = Math.min(minFracDefault, maxFrac === undefined ? minFracDefault : maxFrac);
    if (maxFrac === undefined) maxFrac = Math.max(minFrac, notation === "compact" ? 0 : maxFracDefault);
    if (minFrac > maxFrac) throw new RangeError("maximumFractionDigits value is out of range.");
    const minSig = getNum(o, "minimumSignificantDigits", 1, 21, undefined);
    const maxSig = getNum(o, "maximumSignificantDigits", 1, 21, undefined);
    this._o = {
      locale: LOCALE(), numberingSystem: "latn", style, currency, currencyDisplay: getOpt(o, "currencyDisplay", ["symbol", "narrowSymbol", "code", "name"], "symbol"),
      unit, unitDisplay: getOpt(o, "unitDisplay", ["short", "narrow", "long"], "short"),
      minimumIntegerDigits: getNum(o, "minimumIntegerDigits", 1, 21, 1), minimumFractionDigits: minFrac, maximumFractionDigits: maxFrac,
      minimumSignificantDigits: maxSig !== undefined || minSig !== undefined ? (minSig || 1) : undefined,
      maximumSignificantDigits: maxSig !== undefined || minSig !== undefined ? (maxSig || 21) : undefined,
      useGrouping: o.useGrouping === undefined ? "auto" : o.useGrouping === false || o.useGrouping === "false" ? false : String(o.useGrouping) === "true" ? "always" : String(o.useGrouping),
      notation, compactDisplay: getOpt(o, "compactDisplay", ["short", "long"], "short"), signDisplay: getOpt(o, "signDisplay", ["auto", "never", "always", "exceptZero", "negative"], "auto"),
    };
    if (this._o.minimumSignificantDigits === undefined) { delete this._o.minimumSignificantDigits; delete this._o.maximumSignificantDigits; }
  }
  function numberParts(o, value) {
    const parts = [];
    let x = typeof value === "bigint" ? value : Number(value);
    const big = typeof x === "bigint";
    const negative = big ? x < 0n : x < 0 || Object.is(x, -0);
    if (big && negative) x = -x; else if (!big) x = Math.abs(x);
    const sign = o.signDisplay;
    const zero = big ? x === 0n : x === 0;
    if (negative && sign !== "never" && !(sign === "exceptZero" && zero)) parts.push({ type: "minusSign", value: "-" });
    else if (!negative && (sign === "always" || (sign === "exceptZero" && !zero))) parts.push({ type: "plusSign", value: "+" });
    let suffix = "";
    if (o.style === "percent" && !big) x *= 100;
    if (o.style === "currency") {
      const sym = o.currencyDisplay === "code" ? o.currency + "\u00a0" : o.currencyDisplay === "name" ? "" : (CURRENCY_SYMBOLS[o.currency] || o.currency + "\u00a0");
      if (sym) parts.push({ type: "currency", value: sym });
    }
    if (!big && !isFinite(x)) {
      parts.push(isNaN(x) ? { type: "nan", value: "NaN" } : { type: "infinity", value: "∞" });
    } else {
      let exp = 0;
      if (!big && o.notation !== "standard" && x !== 0) {
        if (o.notation === "compact") {
          const steps = [[1e12, "T", " trillion"], [1e9, "B", " billion"], [1e6, "M", " million"], [1e3, "K", " thousand"]];
          for (const [lim, short, long] of steps) {
            if (x >= lim) { x /= lim; suffix = o.compactDisplay === "long" ? long : short; break; }
          }
          if (o.maximumSignificantDigits === undefined && o.maximumFractionDigits === 0) {
            const s = x < 100 ? Number(x.toPrecision(2)) : Math.round(x);
            x = s;
          }
        } else {
          exp = Math.floor(Math.log10(x));
          if (o.notation === "engineering") exp = Math.floor(exp / 3) * 3;
          x /= Math.pow(10, exp);
        }
      }
      let digits = big ? x.toString() : roundTo(x, o.minimumFractionDigits, o.maximumFractionDigits, o.minimumSignificantDigits, o.maximumSignificantDigits);
      if (o.notation === "compact" && !big && o.maximumSignificantDigits === undefined && o.maximumFractionDigits === 0) digits = String(x);
      let [int, frac] = digits.split(".");
      int = int.padStart(o.minimumIntegerDigits, "0");
      const grouping = o.useGrouping === "always" || (o.useGrouping === "auto" || o.useGrouping === "min2" ? (o.useGrouping !== "min2" || int.length > 4) : false);
      const groups = grouping ? group(int, ",").split(",") : [int];
      groups.forEach((g, i) => { if (i) parts.push({ type: "group", value: "," }); parts.push({ type: "integer", value: g }); });
      if (frac) { parts.push({ type: "decimal", value: "." }); parts.push({ type: "fraction", value: frac }); }
      if (o.notation === "scientific" || o.notation === "engineering") {
        parts.push({ type: "exponentSeparator", value: "E" });
        if (exp < 0) parts.push({ type: "exponentMinusSign", value: "-" });
        parts.push({ type: "exponentInteger", value: String(Math.abs(exp)) });
      }
      if (suffix) parts.push({ type: "compact", value: suffix.trim() === suffix ? suffix : suffix.trim() }), suffix.startsWith(" ") && parts.splice(parts.length - 1, 0, { type: "literal", value: " " });
    }
    if (o.style === "percent") parts.push({ type: "percentSign", value: "%" });
    if (o.style === "currency" && o.currencyDisplay === "name") parts.push({ type: "literal", value: " " }, { type: "currency", value: o.currency });
    if (o.style === "unit") {
      const u = UNITS[o.unit] || [o.unit, o.unit];
      const n = Number(value);
      if (o.unitDisplay === "long") parts.push({ type: "literal", value: " " }, { type: "unit", value: u[0] + (Math.abs(n) === 1 ? "" : "s") });
      else parts.push({ type: "literal", value: o.unit === "percent" || o.unitDisplay === "narrow" ? "" : " " }, { type: "unit", value: u[1] });
    }
    return parts;
  }
  def(NumberFormat.prototype, "formatToParts", function (v) { return numberParts(this._o, v); });
  Object.defineProperty(NumberFormat.prototype, "format", {
    configurable: true,
    get() { const o = this._o; return (v) => numberParts(o, v).map((p) => p.value).join(""); },
  });
  def(NumberFormat.prototype, "formatRange", function (a, b) { return `${this.format(a)}–${this.format(b)}`; });
  def(NumberFormat.prototype, "resolvedOptions", function () { return Object.assign({}, this._o); });
  def(NumberFormat, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(NumberFormat.prototype, Symbol.toStringTag, { value: "Intl.NumberFormat", configurable: true });

  // ---- dates ----
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const UTC_NAMES = ["UTC", "Etc/UTC", "GMT", "Etc/GMT", "Etc/Universal", "Universal", "Zulu"];
  function DateTimeFormat(locales, options) {
    if (!new.target) return new DateTimeFormat(locales, options);
    getCanonicalLocales(locales);
    const o = toObject(options);
    const r = { locale: LOCALE(), calendar: "gregory", numberingSystem: "latn" };
    let tz = o.timeZone;
    if (tz !== undefined) {
      tz = String(tz);
      r.utc = UTC_NAMES.some((n) => n.toLowerCase() === tz.toLowerCase());
      r.timeZone = r.utc ? "UTC" : tz;
    } else {
      r.timeZone = hostInfo().timeZone;
      r.utc = r.timeZone === "UTC";
    }
    const fields = ["weekday", "era", "year", "month", "day", "dayPeriod", "hour", "minute", "second", "fractionalSecondDigits", "timeZoneName"];
    const allowed = { weekday: ["narrow", "short", "long"], era: ["narrow", "short", "long"], year: ["2-digit", "numeric"], month: ["2-digit", "numeric", "narrow", "short", "long"],
      day: ["2-digit", "numeric"], dayPeriod: ["narrow", "short", "long"], hour: ["2-digit", "numeric"], minute: ["2-digit", "numeric"], second: ["2-digit", "numeric"],
      timeZoneName: ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"] };
    let any = false;
    for (const f of fields) {
      if (f === "fractionalSecondDigits") { const v = getNum(o, f, 1, 3, undefined); if (v !== undefined) { r[f] = v; any = true; } continue; }
      const v = getOpt(o, f, allowed[f], undefined);
      if (v !== undefined) { r[f] = v; any = true; }
    }
    const dateStyle = getOpt(o, "dateStyle", ["full", "long", "medium", "short"], undefined);
    const timeStyle = getOpt(o, "timeStyle", ["full", "long", "medium", "short"], undefined);
    if ((dateStyle || timeStyle) && any) throw new TypeError("Can't set option dateStyle or timeStyle with other date-time options");
    if (dateStyle) r.dateStyle = dateStyle;
    if (timeStyle) r.timeStyle = timeStyle;
    const hour12 = o.hour12 === undefined ? undefined : Boolean(o.hour12);
    const hourCycle = getOpt(o, "hourCycle", ["h11", "h12", "h23", "h24"], undefined);
    r.hour12 = hour12 !== undefined ? hour12 : hourCycle ? hourCycle === "h11" || hourCycle === "h12" : true;
    r.hourCycle = hourCycle || (r.hour12 ? "h12" : "h23");
    this._defaults = !any && !dateStyle && !timeStyle;
    this._o = r;
  }
  function dateParts(o, date, need) {
    let d = date === undefined ? new Date() : new Date(typeof date === "object" && date !== null ? date.valueOf() : Number(date));
    const t = d.getTime();
    if (isNaN(t)) throw new RangeError("Invalid time value");
    const g = o.utc ? { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), w: d.getUTCDay(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds(), ms: d.getUTCMilliseconds() }
      : { y: d.getFullYear(), m: d.getMonth(), d: d.getDate(), w: d.getDay(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds(), ms: d.getMilliseconds() };
    let f = Object.assign({}, o);
    if (o.dateStyle || o.timeStyle) {
      f = Object.assign({}, o);
      if (o.dateStyle === "full") Object.assign(f, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
      if (o.dateStyle === "long") Object.assign(f, { month: "long", day: "numeric", year: "numeric" });
      if (o.dateStyle === "medium") Object.assign(f, { month: "short", day: "numeric", year: "numeric" });
      if (o.dateStyle === "short") Object.assign(f, { month: "numeric", day: "numeric", year: "2-digit" });
      if (o.timeStyle) Object.assign(f, { hour: "numeric", minute: "2-digit" });
      if (o.timeStyle === "medium" || o.timeStyle === "long" || o.timeStyle === "full") f.second = "2-digit";
      if (o.timeStyle === "long" || o.timeStyle === "full") f.timeZoneName = o.timeStyle === "full" ? "long" : "short";
    } else if (need) {
      const hasDate = f.weekday || f.year || f.month || f.day, hasTime = f.hour || f.minute || f.second || f.fractionalSecondDigits || f.dayPeriod;
      if (!hasDate && !hasTime) {
        if (need !== "time") Object.assign(f, { year: "numeric", month: "numeric", day: "numeric" });
        if (need !== "date") Object.assign(f, { hour: "numeric", minute: "2-digit", second: "2-digit" });
      }
    }
    const p2 = (n) => String(n).padStart(2, "0");
    const parts = [];
    const lit = (v) => parts.push({ type: "literal", value: v });
    const textMonth = f.month === "long" || f.month === "short" || f.month === "narrow";
    const monthText = f.month === "long" ? MONTHS[g.m] : f.month === "short" ? MONTHS[g.m].slice(0, 3) : f.month === "narrow" ? MONTHS[g.m][0] : f.month === "2-digit" ? p2(g.m + 1) : String(g.m + 1);
    const dayText = f.day === "2-digit" ? p2(g.d) : String(g.d);
    const yearText = f.year === "2-digit" ? p2(g.y % 100) : String(g.y);
    if (f.weekday) {
      parts.push({ type: "weekday", value: f.weekday === "long" ? DAYS[g.w] : f.weekday === "short" ? DAYS[g.w].slice(0, 3) : DAYS[g.w][0] });
      if (f.month || f.day || f.year) lit(", ");
    }
    if (textMonth) {
      if (f.month) parts.push({ type: "month", value: monthText });
      if (f.day) { if (f.month) lit(" "); parts.push({ type: "day", value: dayText }); }
      if (f.year) { if (f.day) lit(", "); else if (f.month) lit(" "); parts.push({ type: "year", value: yearText }); }
    } else {
      const seq = [];
      if (f.month) seq.push({ type: "month", value: monthText });
      if (f.day) seq.push({ type: "day", value: dayText });
      if (f.year) seq.push({ type: "year", value: yearText });
      seq.forEach((x, i) => { if (i) lit("/"); parts.push(x); });
    }
    if (f.era) { lit(" "); parts.push({ type: "era", value: g.y > 0 ? (f.era === "long" ? "Anno Domini" : f.era === "narrow" ? "A" : "AD") : (f.era === "long" ? "Before Christ" : f.era === "narrow" ? "B" : "BC") }); }
    const hasTime = f.hour || f.minute || f.second || f.fractionalSecondDigits;
    if (hasTime) {
      if (parts.length) lit(o.dateStyle === "full" || o.dateStyle === "long" ? " at " : ", ");
      const h12 = o.hourCycle === "h11" || o.hourCycle === "h12";
      let h = g.h;
      if (h12) { h = h % 12; if (h === 0 && o.hourCycle === "h12") h = 12; }
      else if (o.hourCycle === "h24" && h === 0) h = 24;
      const seq = [];
      if (f.hour) seq.push({ type: "hour", value: f.hour === "2-digit" || (!h12 && f.minute) ? p2(h) : String(h) });
      if (f.minute) seq.push({ type: "minute", value: f.hour || f.minute === "2-digit" ? p2(g.mi) : String(g.mi) });
      if (f.second) seq.push({ type: "second", value: f.minute || f.second === "2-digit" ? p2(g.s) : String(g.s) });
      seq.forEach((x, i) => { if (i) lit(":"); parts.push(x); });
      if (f.fractionalSecondDigits) { lit("."); parts.push({ type: "fractionalSecond", value: String(g.ms).padStart(3, "0").slice(0, f.fractionalSecondDigits) }); }
      if (h12 && f.hour) { lit(" "); parts.push({ type: "dayPeriod", value: g.h < 12 ? "AM" : "PM" }); }
    }
    if (f.timeZoneName) {
      lit(" ");
      let name;
      if (o.utc) name = f.timeZoneName === "long" ? "Coordinated Universal Time" : "UTC";
      else {
        const off = -d.getTimezoneOffset();
        const sign = off < 0 ? "-" : "+";
        const a = Math.abs(off);
        name = "GMT" + (off === 0 ? "" : sign + Math.floor(a / 60) + (a % 60 ? ":" + p2(a % 60) : ""));
      }
      parts.push({ type: "timeZoneName", value: name });
    }
    return parts;
  }
  def(DateTimeFormat.prototype, "formatToParts", function (d) { return dateParts(this._o, d, this._defaults ? "date" : ""); });
  Object.defineProperty(DateTimeFormat.prototype, "format", {
    configurable: true,
    get() { const o = this._o, need = this._defaults ? "date" : ""; return (d) => dateParts(o, d, need).map((p) => p.value).join(""); },
  });
  def(DateTimeFormat.prototype, "formatRange", function (a, b) { return `${this.format(a)} – ${this.format(b)}`; });
  def(DateTimeFormat.prototype, "formatRangeToParts", function (a, b) {
    return [...this.formatToParts(a).map((p) => Object.assign(p, { source: "startRange" })), { type: "literal", value: " – ", source: "shared" },
      ...this.formatToParts(b).map((p) => Object.assign(p, { source: "endRange" }))];
  });
  def(DateTimeFormat.prototype, "resolvedOptions", function () {
    const r = Object.assign({}, this._o);
    delete r.utc;
    if (this._defaults) Object.assign(r, { year: "numeric", month: "numeric", day: "numeric" });
    if (!(r.hour || r.timeStyle)) { delete r.hour12; delete r.hourCycle; }
    return r;
  });
  def(DateTimeFormat, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(DateTimeFormat.prototype, Symbol.toStringTag, { value: "Intl.DateTimeFormat", configurable: true });

  // ---- plurals, relative times, lists ----
  function PluralRules(locales, options) {
    if (!new.target) throw new TypeError("Constructor Intl.PluralRules requires 'new'");
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._type = getOpt(o, "type", ["cardinal", "ordinal"], "cardinal");
    this._nf = new NumberFormat("en", o);
  }
  def(PluralRules.prototype, "select", function (n) {
    n = Number(n);
    if (this._type === "ordinal") {
      const a = Math.abs(n), d = a % 10, h = a % 100;
      return d === 1 && h !== 11 ? "one" : d === 2 && h !== 12 ? "two" : d === 3 && h !== 13 ? "few" : "other";
    }
    const s = this._nf.format(Math.abs(n)).replace(/,/g, "");
    return s === "1" ? "one" : "other";
  });
  def(PluralRules.prototype, "selectRange", function (a, b) { return this.select(b); });
  def(PluralRules.prototype, "resolvedOptions", function () {
    return Object.assign({ locale: LOCALE(), type: this._type, pluralCategories: this._type === "ordinal" ? ["few", "one", "two", "other"] : ["one", "other"] }, this._nf.resolvedOptions());
  });
  def(PluralRules, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(PluralRules.prototype, Symbol.toStringTag, { value: "Intl.PluralRules", configurable: true });

  const RT_UNITS = ["year", "quarter", "month", "week", "day", "hour", "minute", "second"];
  function RelativeTimeFormat(locales, options) {
    if (!new.target) throw new TypeError("Constructor Intl.RelativeTimeFormat requires 'new'");
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._o = { locale: LOCALE(), style: getOpt(o, "style", ["long", "short", "narrow"], "long"), numeric: getOpt(o, "numeric", ["always", "auto"], "always"), numberingSystem: "latn" };
  }
  function rtParts(o, value, unit) {
    value = Number(value);
    if (!isFinite(value)) throw new RangeError("Invalid value");
    unit = String(unit).replace(/s$/, "");
    if (!RT_UNITS.includes(unit)) throw new RangeError(`Invalid unit argument for format() '${unit}'`);
    if (o.numeric === "auto") {
      const special = { day: { "-1": "yesterday", "0": "today", "1": "tomorrow" }, year: { "-1": "last year", "0": "this year", "1": "next year" },
        month: { "-1": "last month", "0": "this month", "1": "next month" }, week: { "-1": "last week", "0": "this week", "1": "next week" },
        quarter: { "-1": "last quarter", "0": "this quarter", "1": "next quarter" }, second: { "0": "now" }, minute: { "0": "this minute" }, hour: { "0": "this hour" } };
      const k = Object.is(value, -0) ? "0" : String(value);
      if (special[unit] && special[unit][k]) return [{ type: "literal", value: special[unit][k] }];
    }
    const a = Math.abs(value);
    const short = { year: "yr.", quarter: "qtr.", month: "mo.", week: "wk.", day: "day", hour: "hr.", minute: "min.", second: "sec." };
    const name = o.style === "long" ? unit + (a === 1 ? "" : "s") : short[unit] === "day" ? (a === 1 ? "day" : "days") : short[unit];
    const num = new NumberFormat("en").formatToParts(a).map((p) => Object.assign(p, { unit }));
    const past = value < 0 || Object.is(value, -0);
    return past ? [...num, { type: "literal", value: ` ${name} ago` }] : [{ type: "literal", value: "in " }, ...num, { type: "literal", value: ` ${name}` }];
  }
  def(RelativeTimeFormat.prototype, "format", function (v, u) { return rtParts(this._o, v, u).map((p) => p.value).join(""); });
  def(RelativeTimeFormat.prototype, "formatToParts", function (v, u) { return rtParts(this._o, v, u); });
  def(RelativeTimeFormat.prototype, "resolvedOptions", function () { return Object.assign({}, this._o); });
  def(RelativeTimeFormat, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(RelativeTimeFormat.prototype, Symbol.toStringTag, { value: "Intl.RelativeTimeFormat", configurable: true });

  function ListFormat(locales, options) {
    if (!new.target) throw new TypeError("Constructor Intl.ListFormat requires 'new'");
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._o = { locale: LOCALE(), type: getOpt(o, "type", ["conjunction", "disjunction", "unit"], "conjunction"), style: getOpt(o, "style", ["long", "short", "narrow"], "long") };
  }
  function listParts(o, list) {
    const items = Array.from(list, (x) => { if (typeof x !== "string") throw new TypeError("Iterable yielded a value that is not a string"); return x; });
    const word = o.type === "conjunction" ? (o.style === "long" ? "and" : "&") : o.type === "disjunction" ? "or" : "";
    const parts = [];
    items.forEach((x, i) => {
      if (i) {
        const last = i === items.length - 1;
        let sep = ", ";
        if (last && word) sep = items.length === 2 ? ` ${word} ` : `, ${word} `;
        if (o.type === "unit" && o.style === "narrow") sep = " ";
        parts.push({ type: "literal", value: sep });
      }
      parts.push({ type: "element", value: x });
    });
    return parts;
  }
  def(ListFormat.prototype, "format", function (l) { return listParts(this._o, l).map((p) => p.value).join(""); });
  def(ListFormat.prototype, "formatToParts", function (l) { return listParts(this._o, l); });
  def(ListFormat.prototype, "resolvedOptions", function () { return Object.assign({}, this._o); });
  def(ListFormat, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(ListFormat.prototype, Symbol.toStringTag, { value: "Intl.ListFormat", configurable: true });

  // ---- collation (root-like order: letters first by base, then accents, then case; numeric option) ----
  const fold = (s) => s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  function Collator(locales, options) {
    if (!new.target) return new Collator(locales, options);
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._o = { locale: LOCALE(), usage: getOpt(o, "usage", ["sort", "search"], "sort"), sensitivity: getOpt(o, "sensitivity", ["base", "accent", "case", "variant"], "variant"),
      ignorePunctuation: getOpt(o, "ignorePunctuation", null, false), collation: "default", numeric: getOpt(o, "numeric", null, false), caseFirst: getOpt(o, "caseFirst", ["upper", "lower", "false"], "false") };
  }
  function collate(o, a, b) {
    a = String(a); b = String(b);
    if (o.ignorePunctuation) { a = a.replace(/[\p{P}\s]/gu, ""); b = b.replace(/[\p{P}\s]/gu, ""); }
    const cmp = (x, y) => {
      if (o.numeric) {
        const re = /(\d+)|(\D+)/g;
        const xs = x.match(re) || [], ys = y.match(re) || [];
        for (let i = 0; i < Math.min(xs.length, ys.length); i++) {
          const p = xs[i], q = ys[i];
          if (/^\d/.test(p) && /^\d/.test(q)) { const d = Number(p) - Number(q); if (d) return d < 0 ? -1 : 1; continue; }
          if (p !== q) return p < q ? -1 : 1;
        }
        return xs.length === ys.length ? 0 : xs.length < ys.length ? -1 : 1;
      }
      return x === y ? 0 : x < y ? -1 : 1;
    };
    const base = cmp(fold(a), fold(b));
    if (base || o.sensitivity === "base") return base;
    const accents = cmp(a.normalize("NFD").toLowerCase(), b.normalize("NFD").toLowerCase());
    if (accents || o.sensitivity === "accent") return accents;
    if (a === b) return 0;
    // case: lower before upper by default
    for (let i = 0; i < Math.min(a.length, b.length); i++) {
      if (a[i] !== b[i]) { const al = a[i] === a[i].toLowerCase(); return (o.caseFirst === "upper" ? !al : al) ? -1 : 1; }
    }
    return a.length - b.length < 0 ? -1 : 1;
  }
  Object.defineProperty(Collator.prototype, "compare", { configurable: true, get() { const o = this._o; return (a, b) => collate(o, a, b); } });
  def(Collator.prototype, "resolvedOptions", function () { return Object.assign({}, this._o); });
  def(Collator, "supportedLocalesOf", supportedLocalesOf);
  Object.defineProperty(Collator.prototype, Symbol.toStringTag, { value: "Intl.Collator", configurable: true });

  // ---- locales, segments, display names ----
  function Locale(tag, options) {
    if (!new.target) throw new TypeError("Constructor Intl.Locale requires 'new'");
    const c = canonicalTag(tag instanceof Locale ? tag.toString() : tag);
    const parts = c.split("-");
    this._language = parts[0];
    this._script = parts.find((p, i) => i > 0 && p.length === 4);
    this._region = parts.find((p, i) => i > 0 && (p.length === 2 || /^\d{3}$/.test(p)));
    const o = toObject(options);
    if (o.region !== undefined) this._region = String(o.region).toUpperCase();
    if (o.language !== undefined) this._language = String(o.language).toLowerCase();
  }
  for (const [k, f] of [["language", "_language"], ["script", "_script"], ["region", "_region"]]) {
    Object.defineProperty(Locale.prototype, k, { configurable: true, get() { return this[f]; } });
  }
  Object.defineProperty(Locale.prototype, "baseName", { configurable: true, get() { return [this._language, this._script, this._region].filter(Boolean).join("-"); } });
  def(Locale.prototype, "toString", function () { return this.baseName; });
  def(Locale.prototype, "maximize", function () { return new Locale(this._language === "en" && !this._region ? "en-Latn-US" : this.baseName); });
  def(Locale.prototype, "minimize", function () { return new Locale(this._language); });
  Object.defineProperty(Locale.prototype, Symbol.toStringTag, { value: "Intl.Locale", configurable: true });

  function Segmenter(locales, options) {
    if (!new.target) throw new TypeError("Constructor Intl.Segmenter requires 'new'");
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._g = getOpt(o, "granularity", ["grapheme", "word", "sentence"], "grapheme");
  }
  def(Segmenter.prototype, "segment", function (input) {
    const s = String(input), g = this._g;
    const re = g === "word" ? /\w+|\s+|[^\w\s]/gu : g === "sentence" ? /[^.!?]+[.!?]*\s*/gu : /\P{M}\p{M}*|./gsu;
    const list = [];
    let m;
    while ((m = re.exec(s)) !== null) {
      const seg = { segment: m[0], index: m.index, input: s };
      if (g === "word") seg.isWordLike = /\w/.test(m[0]);
      list.push(seg);
      if (m[0] === "") re.lastIndex++;
    }
    return { [Symbol.iterator]() { return list[Symbol.iterator](); }, containing(i) { return list.find((x) => i >= x.index && i < x.index + x.segment.length); } };
  });
  def(Segmenter.prototype, "resolvedOptions", function () { return { locale: LOCALE(), granularity: this._g }; });
  def(Segmenter, "supportedLocalesOf", supportedLocalesOf);

  function DisplayNames(locales, options) {
    if (!new.target) throw new TypeError("Constructor Intl.DisplayNames requires 'new'");
    getCanonicalLocales(locales);
    const o = toObject(options);
    this._type = getOpt(o, "type", ["language", "region", "script", "currency", "calendar", "dateTimeField"], undefined);
    if (!this._type) throw new TypeError("type is required");
  }
  const NAMES = { language: { en: "English", fr: "French", de: "German", es: "Spanish", it: "Italian", ja: "Japanese", zh: "Chinese", pt: "Portuguese", ru: "Russian", nl: "Dutch", ko: "Korean", ar: "Arabic" },
    region: { US: "United States", GB: "United Kingdom", FR: "France", DE: "Germany", ES: "Spain", IT: "Italy", JP: "Japan", CN: "China", CA: "Canada", BR: "Brazil", IN: "India" },
    currency: { USD: "US Dollar", EUR: "Euro", GBP: "British Pound", JPY: "Japanese Yen" } };
  def(DisplayNames.prototype, "of", function (code) { const t = NAMES[this._type] || {}; return t[code] || t[String(code).split("-")[0]] || String(code); });
  def(DisplayNames.prototype, "resolvedOptions", function () { return { locale: LOCALE(), type: this._type, style: "long", fallback: "code" }; });

  const Intl = {};
  Object.defineProperty(Intl, Symbol.toStringTag, { value: "Intl", configurable: true });
  for (const [k, v] of Object.entries({ NumberFormat, DateTimeFormat, PluralRules, RelativeTimeFormat, ListFormat, Collator, Locale, Segmenter, DisplayNames })) def(Intl, k, v);
  def(Intl, "getCanonicalLocales", getCanonicalLocales);
  def(Intl, "supportedValuesOf", (key) => ({ calendar: ["gregory"], collation: ["default"], currency: Object.keys(CURRENCY_SYMBOLS).sort(), numberingSystem: ["latn"],
    timeZone: ["UTC"], unit: Object.keys(UNITS).sort() }[key] || (() => { throw new RangeError(`Invalid key : ${key}`); })()));
  def(globalThis, "Intl", Intl);

  // the locale-sensitive methods of the standard library, on top of it
  const dtf = (need, locales, options) => { const f = new DateTimeFormat(locales, options); return { f, need: f._defaults ? need : "" }; };
  def(Date.prototype, "toLocaleString", function (l, o) { const { f, need } = dtf("any", l, o); return dateParts(f._o, this, need).map((p) => p.value).join(""); });
  def(Date.prototype, "toLocaleDateString", function (l, o) { const { f, need } = dtf("date", l, o); return dateParts(f._o, this, need).map((p) => p.value).join(""); });
  def(Date.prototype, "toLocaleTimeString", function (l, o) { const { f, need } = dtf("time", l, o); return dateParts(f._o, this, need).map((p) => p.value).join(""); });
  def(Number.prototype, "toLocaleString", function (l, o) { return new NumberFormat(l, o).format(this.valueOf()); });
  def(BigInt.prototype, "toLocaleString", function (l, o) { return new NumberFormat(l, o).format(this.valueOf()); });
  def(String.prototype, "localeCompare", function (that, l, o) {
    if (this === undefined || this === null) throw new TypeError("String.prototype.localeCompare called on null or undefined");
    return collate(new Collator(l, o)._o, String(this), String(that));
  });
})(__wren_intl_host);
delete globalThis.__wren_intl_host;
