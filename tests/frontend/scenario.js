// Runs after dom_shim.js + app.js. Prints "ok <name>" / "FAIL <name>: why", then "DONE".
const tick = async (k = 30) => { for (let i = 0; i < k; i++) await Promise.resolve(); };
const root = els["#app"];
const check = (name, cond, why = "") => print(cond ? `ok ${name}` : `FAIL ${name}: ${why}`);
const tiles = () => root.byClass("tile").length;
const go = async h => { location.hash = h; await tick(); };

(async () => {
  try {
    await tick();
    const home = root.text();
    check("home lists libraries", home.includes("Test") && home.includes("Other"), home);
    check("home marks unplugged drive", home.includes("Drive not connected"), home);

    await go("#/l/abc");
    check("library defaults to All Photos", location.hash === "#/l/abc/v/all", location.hash);
    const side = root.byClass("sidebar")[0].text();
    for (const label of ["Photos", "Favourites", "People", "Places", "Videos", "Selfies",
                         "Live Photos", "Trip"]) {
      check(`sidebar has ${label}`, side.includes(label), side);
    }
    check("sidebar hides empty media types", !side.includes("Panoramas"), side);
    check("All Photos shows every item", tiles() === 6, tiles());

    await go("#/l/abc/v/years");
    check("years view has a card per year", root.byClass("card big").length === 2);
    root.byClass("card big")[0].listeners.click();
    await tick();
    check("year card drills into months", location.hash === "#/l/abc/v/months" && scrolledTo === "2024",
      `${location.hash} ${scrolledTo}`);

    await go("#/l/abc/v/days");
    check("days view groups by day", root.all().filter(e => e.tagName === "section").length === 6);

    await go("#/l/abc/m/favorites");
    check("favourites filter", tiles() === 2 && document.title.startsWith("Favourites"), tiles());
    await go("#/l/abc/m/videos");
    check("videos filter", tiles() === 1, tiles());
    await go("#/l/abc/m/nonsense");
    // Falls back to the last library view used (Days, from above), like a fresh visit would.
    check("unknown media type falls back to library", location.hash === "#/l/abc/v/days", location.hash);

    await go("#/l/abc/people");
    check("people page hides people with no photos", root.byClass("person").length === 1);
    await go("#/l/abc/person/0");
    check("person page lists their photos", tiles() === 2 && document.title.startsWith("Ana"), tiles());

    await go("#/l/abc/hidden");
    check("hidden photos only under Hidden", tiles() === 1 && document.title.startsWith("Hidden"), tiles());
    check("sidebar lists Hidden", root.byClass("sidebar")[0].text().includes("Hidden"));

    await go("#/l/abc/places");
    check("places renders a map", root.byClass("map").length === 1);

    await go("#/l/abc/a/0");
    check("album page", tiles() === 2 && document.title.startsWith("Trip"), tiles());

    const first = root.byClass("tile")[0];
    await go(first.attrs.href);
    check("viewer opens from album", els["#viewer"].hidden === false);
    check("viewer shows place and people", els["#v-time"].textContent.includes("Bucharest") &&
      els["#v-time"].textContent.includes("Ana"), els["#v-time"].textContent);
    check("download button shown when enabled", els["#v-download"].hidden === false);
    els["#v-next"].onclick();
    await tick();
    check("viewer steps within the album", location.hash.endsWith("/p/U2"), location.hash);
    els["#v-close"].onclick();
    await tick();

    // a thumbnail that fails is asked for again a few times, then left alone
    const img = new El("img");
    img.src = "/thumb/abc/U1";
    const later = setTimeout;
    setTimeout = f => { f(); return 0; };
    document.listeners.error({ target: img });
    check("failed image is retried", img.src === "/thumb/abc/U1?retry=1", img.src);
    for (let i = 0; i < 6; i++) document.listeners.error({ target: img });
    check("retries stop after a few tries", img.src === "/thumb/abc/U1?retry=4", img.src);
    setTimeout = later;

    await checkForUpdates();
    const pill = document.body.children.find(c => c.attrs?.class === "update");
    check("new photos pill appears when the server has a newer index", !!pill);
    await checkForUpdates();
    check("pill is not duplicated",
      document.body.children.filter(c => c.attrs?.class === "update").length === 1);
    pill.listeners.click();
    await tick();
    check("pill reloads the library", lib && lib.id === "abc" && updateBtn === null);
  } catch (e) {
    errors.push(String(e) + "\n" + e.stack);
  }
  check("no runtime errors", errors.length === 0, errors.join("\n"));
  print("DONE");
})();
