"use strict";
// Routes:
//   #/                              libraries
//   #/l/<lib>[/v/<view>]            library: years | months | days | all
//   #/l/<lib>/a/<n>                 album n
//   …/p/<uuid>                      viewer over whichever of the above

const $ = (s, el = document) => el.querySelector(s);
const app = $("#app");
const SIZES = [70, 100, 150, 220, 320];
const VIEWS = { years: "Years", months: "Months", days: "Days", all: "All Photos" };

let zoom = Number(store("zoom") ?? 2);
let libCount = 0;
let lib = null;       // library data + index: Map<uuid, asset>
let scope = null;     // { key, base, title, list, pos: Map<uuid, i>, view?, album? }
let pendingScroll = null;
let viewerPushed = false;
let viewing = null;

function store(k, v) {
  try { return v === undefined ? localStorage.getItem(k) : localStorage.setItem(k, v); }
  catch { return null; }
}
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") el.className = v;
    else if (k === "style") el.style.cssText = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) el.setAttribute(k, v === true ? "" : v);
  }
  el.append(...kids.flat().filter(k => k != null && k !== false));
  return el;
}
const ymd = d => [+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10) || 1];
const fmt = (d, o) => new Date(...ymd(d)).toLocaleDateString(undefined, o);
const fmtMonth = d => fmt(d, { month: "long", year: "numeric" });
const fmtDay = d => fmt(d, { weekday: "long", day: "numeric", month: "long", year: "numeric" });
const n = x => x.toLocaleString();
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function api(url) {
  const res = await fetch(url);
  if (res.status === 401) { location.href = "/login"; await new Promise(() => {}); }
  return res;
}

function groupBy(list, key) {
  const out = [];
  for (const a of list) {
    const k = key(a);
    if (!out.length || out.at(-1).key !== k) out.push({ key: k, items: [] });
    out.at(-1).items.push(a);
  }
  return out;
}
const cover = items => items.find(a => !a.m) || items[0];
const thumbUrl = a => `/thumb/${lib.id}/${a.u}`;

// ---------------------------------------------------------------- routing

function parseHash() {
  const parts = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  if (parts[0] !== "l" || !parts[1]) return null;
  const rest = parts.slice(2), p = rest.indexOf("p");
  return { id: parts[1], base: p >= 0 ? rest.slice(0, p) : rest, uuid: p >= 0 ? rest[p + 1] : null };
}
const baseHash = (base = scope.base) => `#/l/${lib.id}${base.length ? "/" + base.join("/") : ""}`;
const viewerHash = uuid => `${baseHash()}/p/${uuid}`;

async function route() {
  const r = parseHash();
  if (!r) { closeViewer(); lib = scope = null; return renderHome(); }
  if (!lib || lib.id !== r.id) {
    closeViewer();
    scope = null;
    if (!(await loadLibrary(r.id))) return;
  }
  const key = r.base.join("/");
  if (!scope || scope.key !== key) { closeViewer(); renderScope(r.base); }
  if (r.uuid) openViewer(r.uuid); else closeViewer();
}

// ---------------------------------------------------------------- home

async function renderHome() {
  document.title = "Photos";
  const libs = await (await api("/api/libraries")).json();
  libCount = libs.length;
  if (libs.length === 1) return location.replace(`#/l/${libs[0].id}`);
  app.replaceChildren(
    h("header", { class: "bar" }, h("h1", {}, "Libraries"), h("div", { class: "spacer" }),
      h("span", { class: "sub" }, `${libs.length} libraries`)),
    h("div", { class: "libs" }, libs.map(l => {
      const c = h("div", { class: "cover" }, l.cover ? null : "▢");
      if (l.cover) c.style.backgroundImage = `url("/thumb/${l.id}/${l.cover}")`;
      const years = l.first ? [l.first.slice(0, 4), l.last.slice(0, 4)] : null;
      const meta = !l.available ? "Drive not connected"
        : l.count ? `${n(l.count)} items` + (years ? ` · ${years[0] === years[1] ? years[0] : years.join("–")}` : "")
        : l.state === "opening" ? "Opening…" : "Tap to open";
      return h("a", { class: "lib" + (l.available ? "" : " off"), href: `#/l/${l.id}` }, c,
        h("div", { class: "name" }, l.name), h("div", { class: "meta" }, meta));
    })),
  );
}

// ---------------------------------------------------------------- library

async function loadLibrary(id) {
  if (!libCount) libCount = (await (await api("/api/libraries")).json()).length;
  for (let shown = ""; ; ) {
    const res = await api(`/api/libraries/${id}`);
    if (parseHash()?.id !== id) return false;
    if (res.status === 404) { location.replace("#/"); return false; }
    const data = await res.json();
    if (res.ok && data.state === "ready") {
      lib = { ...data, index: new Map(data.assets.map(a => [a.u, a])) };
      return true;
    }
    const msg = {
      opening: ["Opening library…", "The first time can take a minute."],
      unavailable: ["This library’s drive isn’t connected.", "It will appear as soon as the drive is plugged in."],
      error: ["Couldn’t open this library", data.error || ""],
    }[data.state] || ["Loading…", ""];
    if (shown !== data.state) {
      shown = data.state;
      app.replaceChildren(simpleBar(data.name), h("div", { class: "center" }, h("div", {},
        data.state === "opening" ? h("div", { class: "spinner" }) : null,
        h("strong", {}, msg[0]), h("br"), h("small", {}, msg[1]))));
    }
    if (data.state === "error") return false;
    await sleep(data.state === "unavailable" ? 5000 : 1500);
  }
}

function simpleBar(title) {
  return h("header", { class: "bar" },
    libCount > 1 ? h("a", { class: "back", href: "#/" }, "‹ Libraries") : null,
    h("h1", {}, title || ""));
}

function renderScope(base) {
  if (base[0] === "a" && lib.albums[+base[1]]) {
    const al = lib.albums[+base[1]];
    const list = al.uuids.map(u => lib.index.get(u)).filter(Boolean);
    scope = { key: base.join("/"), base, title: al.title, list, album: +base[1] };
  } else {
    let view = base[0] === "v" && VIEWS[base[1]] ? base[1] : store("view") || "all";
    if (!VIEWS[view]) view = "all";
    store("view", view);
    base = ["v", view];
    scope = { key: base.join("/"), base, title: "Library", list: lib.assets, view };
    if (location.hash.split("/p/")[0] !== baseHash(base)) {
      const uuid = parseHash()?.uuid;
      history.replaceState(null, "", baseHash(base) + (uuid ? `/p/${uuid}` : ""));
    }
  }
  scope.pos = new Map(scope.list.map((a, i) => [a.u, i]));
  document.title = scope.album != null ? `${scope.title} – ${lib.name}` : lib.name;

  const content = h("div", { class: "content" });
  if (scope.view === "years") renderYears(content);
  else if (scope.view === "months") renderMonths(content);
  else if (scope.view === "days") renderGrouped(content, a => a.d.slice(0, 10), fmtDay);
  else if (scope.view === "all") renderGrouped(content, a => a.d.slice(0, 7), fmtMonth);
  else renderAlbum(content);

  app.replaceChildren(h("div", { class: "layout" }, sidebar(),
    h("div", { class: "scrim", onclick: () => document.body.classList.remove("drawer") }),
    h("div", { class: "main" }, toolbar(), lib.available ? null : h("div", { class: "notice" },
      "The drive is disconnected. Only photos viewed before will load."), content)));
  document.body.classList.remove("drawer");

  const target = pendingScroll && content.querySelector(`[data-key^="${pendingScroll}"]`);
  pendingScroll = null;
  if (target) target.scrollIntoView(); else scrollTo(0, 0);
}

function sidebar() {
  const item = (href, label, count, active) => h("a", { class: "nav" + (active ? " active" : ""), href },
    h("span", {}, label), count != null ? h("span", { class: "count" }, n(count)) : null);
  return h("aside", { class: "sidebar" },
    libCount > 1 ? h("a", { class: "back", href: "#/" }, "‹ Libraries") : null,
    h("div", { class: "lib-name" }, lib.name),
    h("div", { class: "section" }, "Library"),
    item(baseHash(["v", store("view") || "all"]), "Photos", lib.assets.length, scope.album == null),
    lib.albums.length ? h("div", { class: "section" }, "Albums") : null,
    lib.albums.map((al, i) => item(baseHash(["a", i]), al.title, al.uuids.length, scope.album === i)));
}

function toolbar() {
  const menu = h("button", { class: "menu", "aria-label": "Albums",
    onclick: () => document.body.classList.toggle("drawer") }, "☰");
  const grid = scope.view !== "years" && scope.view !== "months";
  let zoomEl = null;
  if (grid) {
    const out = h("button", { "aria-label": "Smaller", onclick: () => setZoom(-1) }, "−");
    const inn = h("button", { "aria-label": "Larger", onclick: () => setZoom(1) }, "+");
    const setZoom = d => {
      zoom = Math.max(0, Math.min(SIZES.length - 1, zoom + d));
      store("zoom", zoom);
      document.documentElement.style.setProperty("--tile-size", `${SIZES[zoom]}px`);
      out.disabled = zoom === 0; inn.disabled = zoom === SIZES.length - 1;
    };
    setZoom(0);
    zoomEl = h("div", { class: "zoom" }, out, inn);
  }
  const seg = scope.view ? h("nav", { class: "seg" }, Object.entries(VIEWS).map(([k, label]) =>
    h("a", { href: baseHash(["v", k]), class: k === scope.view ? "on" : "" }, label))) : null;
  return h("header", { class: "bar" }, menu,
    h("div", { class: "titles" }, h("h1", {}, scope.title),
      h("span", { class: "sub" }, `${n(scope.list.length)} items`)),
    h("div", { class: "spacer" }), seg, zoomEl);
}

function card(items, label, sub, onclick, cls) {
  const c = cover(items);
  return h("button", { class: `card ${cls}`, onclick, style: `background-image:url("${thumbUrl(c)}")` },
    h("span", { class: "card-label" }, h("strong", {}, label), h("small", {}, sub)));
}

function goTo(view, key) {
  pendingScroll = key;
  location.hash = baseHash(["v", view]);
}

function renderYears(el) {
  el.append(h("div", { class: "cards years" }, groupBy(scope.list, a => a.d.slice(0, 4)).map(g =>
    card(g.items, g.key, `${n(g.items.length)} items`, () => goTo("months", g.key), "big"))));
}

function renderMonths(el) {
  for (const y of groupBy(scope.list, a => a.d.slice(0, 4))) {
    el.append(h("section", { class: "group", "data-key": y.key }, h("h2", {}, y.key),
      h("div", { class: "cards months" }, groupBy(y.items, a => a.d.slice(0, 7)).map(m =>
        card(m.items, fmt(m.key, { month: "long" }), `${n(m.items.length)} items`,
          () => goTo("days", m.key), "")))));
  }
}

function renderGrouped(el, key, label) {
  for (const g of groupBy(scope.list, key)) {
    el.append(h("section", { class: "group month", "data-key": g.key },
      h("h2", {}, label(g.key), " ", h("span", {}, n(g.items.length))),
      h("div", { class: "grid" }, g.items.map(tile))));
  }
}

function renderAlbum(el) {
  // Chunk so content-visibility can skip off-screen work on big albums.
  for (let i = 0; i < scope.list.length; i += 300) {
    el.append(h("section", { class: "group month" },
      h("div", { class: "grid" }, scope.list.slice(i, i + 300).map(tile))));
  }
  if (!scope.list.length) el.append(h("div", { class: "center" }, "This album is empty."));
}

function tile(a) {
  return h("a", { class: "tile", href: viewerHash(a.u), onclick: () => { viewerPushed = true; } },
    h("img", { src: thumbUrl(a), loading: "lazy", decoding: "async", alt: "" }),
    a.m ? h("span", { class: "badge play" }, "▶") : null,
    a.l ? h("span", { class: "badge live" }, "LIVE") : null);
}

// ---------------------------------------------------------------- viewer

const viewer = $("#viewer"), stage = $("#v-stage"), liveBtn = $("#v-live");
const prevBtn = $("#v-prev"), nextBtn = $("#v-next"), dl = $("#v-download");

function openViewer(uuid) {
  const i = scope.pos.get(uuid);
  if (i === undefined) return location.replace(baseHash());
  viewing = uuid;
  const a = scope.list[i];
  viewer.hidden = false;
  document.body.classList.add("noscroll");
  $("#v-date").textContent = fmtDay(a.d);
  $("#v-time").textContent = a.d.slice(11, 16) + (a.e ? " · Edited" : "");
  prevBtn.disabled = i === 0;
  nextBtn.disabled = i === scope.list.length - 1;
  liveBtn.hidden = !a.l;
  liveBtn.classList.remove("on");
  dl.hidden = !lib.downloads;
  dl.href = `/original/${lib.id}/${a.u}`;

  if (a.m) showVideo(a, thumbUrl(a));
  else {
    const img = h("img", { src: thumbUrl(a), alt: "", draggable: "false" });
    stage.replaceChildren(img);
    const full = new Image();
    full.onload = () => { if (viewing === a.u) img.src = full.src; };
    full.src = `/photo/${lib.id}/${a.u}`;
  }
  for (const j of [i + 1, i - 1]) {
    const nb = scope.list[j];
    if (nb && !nb.m) new Image().src = `/photo/${lib.id}/${nb.u}`;
  }
}

async function showVideo(a, poster) {
  stage.replaceChildren(h("img", { src: poster, alt: "" }));
  for (let shown = false; viewing === a.u; ) {
    let state = "error";
    try { ({ state } = await (await api(`/video-status/${lib.id}/${a.u}`)).json()); } catch {}
    if (viewing !== a.u) return;
    if (state === "ready") {
      stage.replaceChildren(h("video", { src: `/video/${lib.id}/${a.u}`, poster, controls: true,
        autoplay: true, playsinline: true }));
      return;
    }
    if (state === "error") {
      stage.append(h("div", { class: "v-msg" }, "This video isn’t available."));
      return;
    }
    if (!shown) {
      shown = true;
      stage.append(h("div", { class: "v-msg" }, h("div", { class: "spinner" }), "Preparing video…"));
    }
    await sleep(2000);
  }
}

function playLive() {
  if (!viewing || liveBtn.hidden || stage.querySelector("video.live")) return;
  const v = h("video", { class: "live", src: `/live/${lib.id}/${viewing}`, autoplay: true,
    muted: true, playsinline: true });
  v.muted = true;
  liveBtn.classList.add("on");
  v.onended = v.onerror = stopLive;
  stage.append(v);
}
function stopLive() {
  stage.querySelector("video.live")?.remove();
  liveBtn.classList.remove("on");
}

function closeViewer() {
  if (viewer.hidden) return;
  viewing = null;
  stage.querySelectorAll("video").forEach(v => v.pause());
  stage.replaceChildren();
  viewer.hidden = true;
  document.body.classList.remove("noscroll");
}

function step(d) {
  const i = scope.pos.get(viewing) + d;
  if (i >= 0 && i < scope.list.length) location.replace(viewerHash(scope.list[i].u));
}

function exitViewer() {
  if (viewerPushed) { viewerPushed = false; history.back(); }
  else location.replace(baseHash());
}

$("#v-close").onclick = exitViewer;
prevBtn.onclick = () => step(-1);
nextBtn.onclick = () => step(1);
liveBtn.onclick = playLive;
liveBtn.onmouseenter = playLive;

addEventListener("keydown", e => {
  if (viewer.hidden) return;
  if (e.key === "ArrowLeft") step(-1);
  else if (e.key === "ArrowRight") step(1);
  else if (e.key === "Escape") exitViewer();
  else if (e.key === " " && !liveBtn.hidden) { e.preventDefault(); playLive(); }
});

// Press and hold to play a Live Photo (like Photos on iPhone).
let hold = null;
stage.addEventListener("pointerdown", e => {
  if (liveBtn.hidden || e.button !== 0) return;
  hold = { x: e.clientX, y: e.clientY, t: setTimeout(() => { hold.on = true; playLive(); }, 250) };
});
stage.addEventListener("pointermove", e => {
  if (hold && !hold.on && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 10) {
    clearTimeout(hold.t); hold = null;
  }
});
for (const ev of ["pointerup", "pointercancel", "pointerleave"]) {
  stage.addEventListener(ev, () => {
    if (!hold) return;
    clearTimeout(hold.t);
    if (hold.on) stopLive();
    hold = null;
  });
}
stage.addEventListener("contextmenu", e => { if (!liveBtn.hidden) e.preventDefault(); });

// Swipe left/right to navigate, swipe down to close.
let touch = null;
stage.addEventListener("touchstart", e => {
  if (e.touches.length === 1) touch = { x: e.touches[0].clientX, y: e.touches[0].clientY };
}, { passive: true });
stage.addEventListener("touchend", e => {
  if (!touch) return;
  const dx = e.changedTouches[0].clientX - touch.x, dy = e.changedTouches[0].clientY - touch.y;
  touch = null;
  if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) step(dx < 0 ? 1 : -1);
  else if (dy > 90 && Math.abs(dy) > Math.abs(dx)) exitViewer();
});

// Start last: route() uses the viewer elements declared above.
addEventListener("hashchange", route);
route();
