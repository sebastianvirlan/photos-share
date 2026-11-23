"use strict";
// Routes:
//   #/                              libraries
//   #/l/<lib>[/v/<view>]            library: years | months | days | all
//   #/l/<lib>/a/<n>                 album n
//   #/l/<lib>/m/<type>              favourites / media type (see MEDIA)
//   #/l/<lib>/people, /person/<n>   people, one person's photos
//   #/l/<lib>/places                map
//   #/l/<lib>/hidden                Photos' Hidden album (only if the share includes it)
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
const itemCount = count => `${n(count)} ${count === 1 ? "item" : "items"}`;
// Sidebar "Media Types" (plus Favourites), in Photos' order: [label, predicate]
const MEDIA = {
  favorites: ["Favourites", a => a.f],
  videos: ["Videos", a => a.m],
  selfies: ["Selfies", a => a.k?.includes("s")],
  live: ["Live Photos", a => a.l],
  portrait: ["Portrait", a => a.k?.includes("p")],
  panoramas: ["Panoramas", a => a.k?.includes("n")],
  slomo: ["Slo-mo", a => a.k?.includes("o")],
  timelapse: ["Time-lapse", a => a.k?.includes("t")],
  screenshots: ["Screenshots", a => a.ss],
};
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
        : l.count ? itemCount(l.count) + (years ? ` · ${years[0] === years[1] ? years[0] : years.join("–")}` : "")
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
      // Hidden photos (only sent when the share includes them) live apart, like in Photos.
      lib = { ...data, assets: data.assets.filter(a => !a.hd), hidden: data.assets.filter(a => a.hd),
              index: new Map(data.assets.map(a => [a.u, a])) };
      hideUpdate();
      pollForUpdates();
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

// ---------------------------------------------------------------- updates

// The server re-indexes a library when photos are added in Photos; offer to show them.
const POLL_MS = 60000;
let pollTimer = 0, updateBtn = null;

function pollForUpdates() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(checkForUpdates, POLL_MS);
}

async function checkForUpdates() {
  if (!lib) return;
  try {
    const me = (await (await api("/api/libraries")).json()).find(l => l.id === lib.id);
    if (me && me.rev > lib.rev) return showUpdate();
  } catch {}
  pollForUpdates();
}

function showUpdate() {
  if (updateBtn) return;
  updateBtn = h("button", { class: "update", onclick: async () => {
    hideUpdate();
    lib = null;          // force a fresh load; route() re-renders the current view
    await route();
  } }, "New photos · Show");
  document.body.append(updateBtn);
}

function hideUpdate() {
  updateBtn?.remove();
  updateBtn = null;
}

function simpleBar(title) {
  return h("header", { class: "bar" },
    libCount > 1 ? h("a", { class: "back", href: "#/" }, "‹ Libraries") : null,
    h("h1", {}, title || ""));
}

function renderScope(base) {
  const key = base.join("/");
  if (base[0] === "a" && lib.albums[+base[1]]) {
    const al = lib.albums[+base[1]];
    const list = al.uuids.map(u => lib.index.get(u)).filter(a => a && !a.hd);
    scope = { key, base, title: al.title, list, album: +base[1], kind: "album" };
  } else if (base[0] === "m" && MEDIA[base[1]]) {
    const [label, pred] = MEDIA[base[1]];
    scope = { key, base, title: label, list: lib.assets.filter(pred), kind: "media", media: base[1] };
  } else if (base[0] === "people") {
    scope = { key, base, title: "People", list: [], kind: "people" };
  } else if (base[0] === "person" && lib.people[+base[1]]) {
    const i = +base[1];
    scope = { key, base, title: lib.people[i].name, list: lib.assets.filter(a => a.p?.includes(i)),
      kind: "person", person: i };
  } else if (base[0] === "hidden") {
    scope = { key, base, title: "Hidden", list: lib.hidden, kind: "media", media: "hidden" };
  } else if (base[0] === "places") {
    scope = { key, base, title: "Places", list: lib.assets.filter(a => a.g), kind: "places" };
  } else {
    let view = base[0] === "v" && VIEWS[base[1]] ? base[1] : store("view") || "all";
    if (!VIEWS[view]) view = "all";
    store("view", view);
    base = ["v", view];
    scope = { key: base.join("/"), base, title: "Library", list: lib.assets, view, kind: "library" };
    if (location.hash.split("/p/")[0] !== baseHash(base)) {
      const uuid = parseHash()?.uuid;
      history.replaceState(null, "", baseHash(base) + (uuid ? `/p/${uuid}` : ""));
    }
  }
  scope.pos = new Map(scope.list.map((a, i) => [a.u, i]));
  document.title = scope.kind !== "library" ? `${scope.title} – ${lib.name}` : lib.name;

  const content = h("div", { class: "content" });
  const byMonth = () => renderGrouped(content, a => a.d.slice(0, 7), fmtMonth);
  if (scope.view === "years") renderYears(content);
  else if (scope.view === "months") renderMonths(content);
  else if (scope.view === "days") renderGrouped(content, a => a.d.slice(0, 10), fmtDay);
  else if (scope.view === "all") byMonth();
  else if (scope.kind === "media" || scope.kind === "person") byMonth();
  else if (scope.kind === "people") renderPeople(content);
  else if (scope.kind === "places") renderPlaces(content);
  else renderAlbum(content);
  if (!scope.list.length && scope.kind !== "people" && scope.kind !== "album") {
    content.append(h("div", { class: "center" }, "Nothing here."));
  }

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
  const media = Object.entries(MEDIA).filter(([k]) => k !== "favorites")
    .map(([k, [label, pred]]) => [k, label, lib.assets.filter(pred).length]).filter(m => m[2]);
  const favs = lib.assets.filter(MEDIA.favorites[1]).length;
  const people = lib.people.filter(p => p.count).length;
  const places = lib.assets.filter(a => a.g).length;
  return h("aside", { class: "sidebar" },
    libCount > 1 ? h("a", { class: "back", href: "#/" }, "‹ Libraries") : null,
    h("div", { class: "lib-name" }, lib.name),
    h("div", { class: "section" }, "Library"),
    item(baseHash(["v", store("view") || "all"]), "Photos", lib.assets.length, scope.kind === "library"),
    favs ? item(baseHash(["m", "favorites"]), "♥ Favourites", favs, scope.media === "favorites") : null,
    people ? item(baseHash(["people"]), "People", people,
      scope.kind === "people" || scope.kind === "person") : null,
    places ? item(baseHash(["places"]), "Places", places, scope.kind === "places") : null,
    lib.hidden.length ? item(baseHash(["hidden"]), "Hidden", lib.hidden.length,
      scope.media === "hidden") : null,
    media.length ? h("div", { class: "section" }, "Media Types") : null,
    media.map(([k, label, c]) => item(baseHash(["m", k]), label, c, scope.media === k)),
    lib.albums.length ? h("div", { class: "section" }, "Albums") : null,
    lib.albums.map((al, i) => item(baseHash(["a", i]), al.title, al.uuids.length, scope.album === i)));
}

// ---------------------------------------------------------------- people

function renderPeople(el) {
  const people = lib.people.map((p, i) => ({ ...p, i })).filter(p => p.count);
  el.append(h("div", { class: "people" }, people.map(p =>
    h("a", { class: "person", href: baseHash(["person", p.i]) }, avatar(p),
      h("div", { class: "name" }, p.name), h("div", { class: "meta" }, itemCount(p.count))))));
}

// Crops the face out of a photo with CSS: an <img> scaled and offset inside a circle.
function avatar(p) {
  const box = h("div", { class: "avatar" });
  const f = p.face, a = f && lib.index.get(f.u);
  if (!a || !a.w || !a.h) { box.textContent = p.name.slice(0, 1); return box; }
  const side = Math.max(f.s * 1.7, 0.02) * Math.max(a.w, a.h); // face plus some margin, in px
  const w = a.w / side, hh = a.h / side;                       // image size in avatar widths
  const src = side / Math.max(a.w, a.h) * 640 >= 140 ? thumbUrl(a) : `/photo/${lib.id}/${a.u}`;
  box.append(h("img", { src, alt: "", loading: "lazy", style:
    `width:${w * 100}%;height:${hh * 100}%;left:${(0.5 - f.x * w) * 100}%;top:${(0.5 - f.y * hh) * 100}%` }));
  return box;
}

// ---------------------------------------------------------------- places

let leaflet = null;
function loadLeaflet() {
  const base = "https://cdnjs.cloudflare.com/ajax/libs";
  const css = href => document.head.append(h("link", { rel: "stylesheet", href }));
  const js = src => new Promise((ok, fail) =>
    document.head.append(h("script", { src, onload: ok, onerror: fail })));
  return leaflet ??= (async () => {
    css(`${base}/leaflet/1.9.4/leaflet.min.css`);
    css(`${base}/leaflet.markercluster/1.5.3/MarkerCluster.min.css`);
    await js(`${base}/leaflet/1.9.4/leaflet.min.js`);
    await js(`${base}/leaflet.markercluster/1.5.3/leaflet.markercluster.min.js`);
  })();
}

async function renderPlaces(el) {
  const box = h("div", { class: "map" });
  el.append(box);
  if (!scope.list.length) return;
  try { await loadLeaflet(); } catch {
    box.replaceChildren(h("div", { class: "center" }, "The map couldn’t load (no internet?)."));
    return;
  }
  if (!box.isConnected) return;
  const map = L.map(box, { worldCopyJump: true });
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' }).addTo(map);
  const pin = (a, count) => L.divIcon({ className: "pin", iconSize: [52, 52], iconAnchor: [26, 26],
    html: `<img src="${thumbUrl(a)}" alt="">` + (count > 1 ? `<span>${n(count)}</span>` : "") });
  const cluster = L.markerClusterGroup({ chunkedLoading: true, showCoverageOnHover: false,
    maxClusterRadius: 60, iconCreateFunction: c => {
      const ms = c.getAllChildMarkers();
      return pin(ms.reduce((best, m) => m.options.asset.d > best.d ? m.options.asset : best,
        ms[0].options.asset), c.getChildCount());
    } });
  cluster.addLayers(scope.list.map(a => L.marker(a.g, { icon: pin(a, 1), asset: a, title: a.pl || "" })
    .on("click", () => { viewerPushed = true; location.hash = viewerHash(a.u); })));
  map.addLayer(cluster);
  map.fitBounds(cluster.getBounds(), { padding: [30, 30], maxZoom: 12 });
}

function toolbar() {
  const menu = h("button", { class: "menu", "aria-label": "Albums",
    onclick: () => document.body.classList.toggle("drawer") }, "☰");
  const grid = scope.view !== "years" && scope.view !== "months" &&
    scope.kind !== "people" && scope.kind !== "places";
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
      h("span", { class: "sub" }, scope.kind === "people"
        ? `${n(lib.people.filter(p => p.count).length)} people` : itemCount(scope.list.length))),
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
    card(g.items, g.key, itemCount(g.items.length), () => goTo("months", g.key), "big"))));
}

function renderMonths(el) {
  for (const y of groupBy(scope.list, a => a.d.slice(0, 4))) {
    el.append(h("section", { class: "group", "data-key": y.key }, h("h2", {}, y.key),
      h("div", { class: "cards months" }, groupBy(y.items, a => a.d.slice(0, 7)).map(m =>
        card(m.items, fmt(m.key, { month: "long" }), itemCount(m.items.length),
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
    a.l ? h("span", { class: "badge live" }, "LIVE") : null,
    a.f ? h("span", { class: "badge fav" }, "♥") : null);
}

// ---------------------------------------------------------------- viewer

const viewer = $("#viewer"), stage = $("#v-stage"), liveBtn = $("#v-live");
const prevBtn = $("#v-prev"), nextBtn = $("#v-next"), dl = $("#v-download");
const dlOrig = $("#v-download-orig");

function openViewer(uuid) {
  const i = scope.pos.get(uuid);
  if (i === undefined) return location.replace(baseHash());
  viewing = uuid;
  const a = scope.list[i];
  viewer.hidden = false;
  document.body.classList.add("noscroll");
  $("#v-date").textContent = fmtDay(a.d);
  $("#v-time").textContent = [a.f ? "♥" : null, a.d.slice(11, 16), a.pl, a.e ? "Edited" : null,
    a.p?.length ? a.p.map(i => lib.people[i]?.name).filter(Boolean).join(", ") : null]
    .filter(Boolean).join(" · ");
  prevBtn.disabled = i === 0;
  nextBtn.disabled = i === scope.list.length - 1;
  liveBtn.hidden = !a.l;
  liveBtn.classList.remove("on");
  // ↓ gives the photo as shown (with its edits); edited ones also offer the original.
  dl.hidden = !lib.downloads || !!a.nf;
  dl.href = `/download/${lib.id}/${a.u}`;
  dl.title = a.e ? "Download with edits" : "Download";
  dlOrig.hidden = !lib.downloads || !a.e || !!a.no || !!a.nf;
  dlOrig.href = `/original/${lib.id}/${a.u}`;

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
// A thumbnail that fails (a slow first load timing out, a dropped connection) would stay
// broken: browsers never ask again. Retry a few times, waiting longer each time.
const RETRY_DELAYS = [1500, 4000, 10000, 20000];
document.addEventListener("error", e => {
  const img = e.target;
  if (!(img instanceof HTMLImageElement) || !img.isConnected) return;
  const tries = Number(img.dataset.tries || 0);
  if (tries >= RETRY_DELAYS.length) return;
  img.dataset.tries = tries + 1;
  const base = img.src.replace(/[?&]retry=\d+$/, "");
  setTimeout(() => {
    if (img.isConnected) img.src = `${base}${base.includes("?") ? "&" : "?"}retry=${tries + 1}`;
  }, RETRY_DELAYS[tries]);
}, true);  // capture: image errors don't bubble

route();
