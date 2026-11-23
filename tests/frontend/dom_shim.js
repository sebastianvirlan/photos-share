// Minimal DOM/browser stand-in so app.js can run under JavaScriptCore (jsc).
// Not a browser: enough to catch runtime errors and check routing/rendering logic.
const LIBS = read(arguments[0]), LIB = read(arguments[1]);
const errors = [];
let scrolledTo = null;

class El {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.attrs = {}; this.hidden = true;
    this.textContent = ""; this.listeners = {}; this.dataset = {}; this.src = "";
    this.style = { setProperty() {}, set cssText(v) {} };
    const cl = new Set();
    this.classList = { add: c => cl.add(c), remove: c => cl.delete(c), has: c => cl.has(c),
      toggle: c => (cl.has(c) ? cl.delete(c) : cl.add(c)) };
  }
  set className(v) { this.attrs.class = v; }
  get className() { return this.attrs.class; }
  get isConnected() { return true; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(ev, f) { this.listeners[ev] = f; }
  append(...k) { this.children.push(...k); }
  replaceChildren(...k) { this.children = k; }
  remove() {} pause() {}
  scrollIntoView() { scrolledTo = this.attrs["data-key"]; }
  all() { return this.children.flatMap(c => (c instanceof El ? [c, ...c.all()] : [])); }
  text() { return this.children.map(c => (c instanceof El ? c.text() : String(c))).join(""); }
  byClass(cls) { return this.all().filter(e => e.attrs.class === cls); }
  querySelector(sel) {
    const m = sel.match(/data-key\^="(.*)"/);
    if (m) return this.all().find(e => (e.attrs["data-key"] || "").startsWith(m[1])) || null;
    const tag = sel.split(".")[0];
    return this.all().find(e => e.tagName === tag) || null;
  }
  querySelectorAll() { return []; }
}

const els = {};
var document = { querySelector: s => (els[s] ??= new El(s)), createElement: t => new El(t),
  documentElement: new El("html"), body: new El("body"), head: new El("head"), title: "",
  listeners: {}, addEventListener(ev, f) { this.listeners[ev] = f; } };
var HTMLImageElement = El;  // the shim's elements stand in for images too
let onHash = null;
const fireHash = () => onHash && Promise.resolve().then(onHash).catch(e => errors.push(String(e)));
var location = { _h: "", get hash() { return this._h; }, set hash(v) { this._h = v; fireHash(); },
  replace(v) { this._h = v; fireHash(); }, href: "" };
var addEventListener = (ev, f) => { if (ev === "hashchange") onHash = f; };
var history = { back() {}, replaceState(_, __, u) { location._h = u; } };
var localStorage = { s: {}, getItem(k) { return this.s[k] ?? null; }, setItem(k, v) { this.s[k] = String(v); } };
var scrollTo = () => {};
var Image = class { set src(v) {} };
var setTimeout = () => 0, clearTimeout = () => {};
var fetch = async url => ({ ok: true, status: 200,
  json: async () => JSON.parse(url === "/api/libraries" ? LIBS : LIB) });
