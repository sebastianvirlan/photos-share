"use strict";
// Routes: #/                 libraries
//         #/l/<lib>          library grid
//         #/l/<lib>/<uuid>   viewer over the grid

const $ = (s, el = document) => el.querySelector(s);
const app = $("#app");
const SIZES = [70, 100, 150, 220, 320];
let zoom = Number(store("zoom") ?? 2);
let lib = null;          // { id, name, assets, index: Map<uuid, i> }
let viewerPushed = false; // true when the viewer added its own history entry
let viewing = null;       // uuid currently in the viewer

function store(k, v) {
  try { return v === undefined ? localStorage.getItem(k) : localStorage.setItem(k, v); }
  catch { return null; }
}
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) el.setAttribute(k, v === true ? "" : v);
  }
  el.append(...kids.flat().filter(k => k != null));
  return el;
}
const fmtMonth = d => new Date(+d.slice(0, 4), +d.slice(5, 7) - 1)
  .toLocaleDateString(undefined, { month: "long", year: "numeric" });
const fmtDay = d => new Date(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10))
  .toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "long", year: "numeric" });
const fmtTime = d => d.slice(11, 16);
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- routing

async function route() {
  const [, page, id, uuid] = location.hash.split("/");
  if (page !== "l" || !id) { closeViewer(); lib = null; return renderHome(); }
  if (!lib || lib.id !== id) {
    closeViewer();
    if (!(await loadLibrary(id))) return;
  }
  if (uuid) openViewer(uuid); else closeViewer();
}

// ---------------------------------------------------------------- home

async function renderHome() {
  document.title = "Photos";
  const libs = await (await fetch("/api/libraries")).json();
  if (libs.length === 1) return location.replace(`#/l/${libs[0].id}`);
  app.replaceChildren(
    h("header", { class: "bar" }, h("h1", {}, "Libraries"), h("div", { class: "spacer" }),
      h("span", { class: "sub" }, `${libs.length} libraries`)),
    h("div", { class: "libs" }, libs.map(l => {
      const cover = h("div", { class: "cover" }, l.cover ? null : "▢");
      if (l.cover) cover.style.backgroundImage = `url("/thumb/${l.id}/${l.cover}")`;
      const years = l.first ? [l.first.slice(0, 4), l.last.slice(0, 4)] : null;
      const meta = l.count
        ? `${l.count.toLocaleString()} items · ${years[0] === years[1] ? years[0] : years.join("–")}`
        : l.state === "opening" ? "Opening…" : "Tap to open";
      return h("a", { class: "lib", href: `#/l/${l.id}` }, cover,
        h("div", { class: "name" }, l.name), h("div", { class: "meta" }, meta));
    })),
  );
}

// ---------------------------------------------------------------- library grid

async function loadLibrary(id) {
  const hash = location.hash;
  for (let first = true; ; first = false) {
    const res = await fetch(`/api/libraries/${id}`);
    if (location.hash !== hash && !location.hash.startsWith(`#/l/${id}/`)) return false;
    if (res.status === 404) { location.replace("#/"); return false; }
    const data = await res.json();
    if (res.ok && data.state === "ready") {
      lib = { ...data, index: new Map(data.assets.map((a, i) => [a.u, i])) };
      renderLibrary();
      return true;
    }
    if (data.state === "error") {
      app.replaceChildren(backBar(data.name), h("div", { class: "center" },
        h("div", {}, h("strong", {}, "Couldn’t open this library"), h("br"), data.error || "")));
      return false;
    }
    if (first) app.replaceChildren(backBar(data.name), h("div", { class: "center" },
      h("div", {}, h("div", { class: "spinner" }), "Opening library…", h("br"),
        h("small", {}, "The first time can take a minute."))));
    await sleep(1500);
  }
}

function backBar(title, ...extra) {
  return h("header", { class: "bar" },
    h("a", { class: "back", href: "#/", onclick: e => { e.preventDefault(); location.hash = "#/"; } },
      "‹ Libraries"),
    h("h1", {}, title || ""), h("div", { class: "spacer" }), ...extra);
}

function renderLibrary() {
  document.title = lib.name;
  const zoomOut = h("button", { "aria-label": "Smaller", onclick: () => setZoom(-1) }, "−");
  const zoomIn = h("button", { "aria-label": "Larger", onclick: () => setZoom(1) }, "+");
  const setZoom = (d) => {
    zoom = Math.max(0, Math.min(SIZES.length - 1, zoom + d));
    store("zoom", zoom);
    document.documentElement.style.setProperty("--tile-size", `${SIZES[zoom]}px`);
    zoomOut.disabled = zoom === 0; zoomIn.disabled = zoom === SIZES.length - 1;
  };
  setZoom(0);

  const months = [];
  for (const a of lib.assets) {
    const key = a.d.slice(0, 7);
    if (!months.length || months.at(-1).key !== key) months.push({ key, items: [] });
    months.at(-1).items.push(a);
  }
  app.replaceChildren(
    backBar(lib.name, h("span", { class: "sub" }, `${lib.assets.length.toLocaleString()} items`),
      h("div", { class: "zoom" }, zoomOut, zoomIn)),
    ...months.map(m => h("section", { class: "month" },
      h("h2", {}, fmtMonth(m.key), " ", h("span", {}, m.items.length)),
      h("div", { class: "grid" }, m.items.map(tile)))),
  );
  scrollTo(0, 0);
}

function tile(a) {
  return h("a", { class: "tile", href: `#/l/${lib.id}/${a.u}`, onclick: () => { viewerPushed = true; } },
    h("img", { src: `/thumb/${lib.id}/${a.u}`, loading: "lazy", decoding: "async", alt: "" }),
    a.m ? h("span", { class: "badge play" }, "▶") : null,
    a.l ? h("span", { class: "badge live" }, "LIVE") : null);
}

// ---------------------------------------------------------------- viewer

const viewer = $("#viewer"), stage = $("#v-stage"), liveBtn = $("#v-live");
const prevBtn = $("#v-prev"), nextBtn = $("#v-next");

function openViewer(uuid) {
  const i = lib.index.get(uuid);
  if (i === undefined) return location.replace(`#/l/${lib.id}`);
  viewing = uuid;
  const a = lib.assets[i];
  viewer.hidden = false;
  document.body.classList.add("noscroll");
  $("#v-date").textContent = fmtDay(a.d);
  $("#v-time").textContent = fmtTime(a.d) + (a.e ? " · Edited" : "");
  prevBtn.disabled = i === 0;
  nextBtn.disabled = i === lib.assets.length - 1;
  liveBtn.hidden = !a.l;
  liveBtn.classList.remove("on");

  const thumb = `/thumb/${lib.id}/${a.u}`;
  if (a.m) showVideo(a, thumb);
  else {
    const img = h("img", { src: thumb, alt: "" });
    stage.replaceChildren(img);
    const full = new Image();
    full.onload = () => { if (viewing === a.u) img.src = full.src; };
    full.src = `/photo/${lib.id}/${a.u}`;
  }
  // Warm the neighbours so arrowing through feels instant.
  for (const j of [i + 1, i - 1]) {
    const n = lib.assets[j];
    if (n && !n.m) new Image().src = `/photo/${lib.id}/${n.u}`;
  }
}

async function showVideo(a, poster) {
  stage.replaceChildren(h("img", { src: poster, alt: "" }));
  for (let shown = false; viewing === a.u; ) {
    const { state } = await (await fetch(`/video-status/${lib.id}/${a.u}`)).json();
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
  if (!viewing || liveBtn.hidden) return;
  stage.querySelector("video.live")?.remove();
  const v = h("video", { class: "live", src: `/live/${lib.id}/${viewing}`, autoplay: true,
    muted: true, playsinline: true });
  v.muted = true;
  liveBtn.classList.add("on");
  v.onended = v.onerror = () => { v.remove(); liveBtn.classList.remove("on"); };
  stage.append(v);
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
  const i = lib.index.get(viewing) + d;
  if (i >= 0 && i < lib.assets.length) location.replace(`#/l/${lib.id}/${lib.assets[i].u}`);
}

function exitViewer() {
  if (viewerPushed) { viewerPushed = false; history.back(); }
  else location.replace(`#/l/${lib.id}`);
}

$("#v-close").onclick = exitViewer;
prevBtn.onclick = () => step(-1);
nextBtn.onclick = () => step(1);
liveBtn.onclick = playLive;

addEventListener("keydown", e => {
  if (viewer.hidden) return;
  if (e.key === "ArrowLeft") step(-1);
  else if (e.key === "ArrowRight") step(1);
  else if (e.key === "Escape") exitViewer();
  else if (e.key === " " && !liveBtn.hidden) { e.preventDefault(); playLive(); }
});

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

// Start last: route() touches the viewer elements declared above.
addEventListener("hashchange", route);
route();
