// A "connected" toast that lives 2.2 s. Record the moment, measure it in the DOM and on the screen.
//   wkframes examples/toast-column/index.html examples/toast-column/scenario.js            → FAIL (a window-tall column)
//   wkframes "file://$PWD/examples/toast-column/index.html?fixed" examples/toast-column/scenario.js   → PASS
const heights = [];
let watching = true;
const watch = () => { const t = probe.$(".toast"); if (t) heights.push(Math.round(t.getBoundingClientRect().height)); if (watching) requestAnimationFrame(watch); };
requestAnimationFrame(watch);

// a point above the pill, where nothing dark should ever be
const x = Math.round(innerWidth / 2), y = 120;
const rec = probe.rec("connect", 1600, { points: [[x, y]] });
await rec.started;
probe.click("#connect");
const { frames } = await rec;
watching = false;

const tallest = Math.max(0, ...heights);
const darkest = Math.min(...frames.map((f) => probe.lum(f.px[0])));
probe.check("T1", heights.length > 0, "the toast showed", `${heights.length} samples`);
probe.check("T2", tallest <= 40, "the toast stays a pill (DOM)", `tallest ${tallest}px`);
probe.check("T3", darkest > 150, "nothing dark above it (screen)", `darkest ${darkest} of 255 at (${x}, ${y}) over ${frames.length} frames`);
