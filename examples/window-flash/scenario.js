// A page switch with a 250 ms gap, in a window whose web view draws no background and whose colour is dark
// (left over from a dark sign-in screen, say). The DOM never sees it; the screen does.
//   wkframes examples/window-flash/index.html examples/window-flash/scenario.js --transparent-webview --window-bg "#16161a"
//   … add ?fixed to the page's address → PASS
const x = Math.round(innerWidth / 2), y = Math.round(innerHeight / 2);
const rec = probe.rec("switch", 1000, { points: [[x, y]] });
await rec.started;
probe.click("#next");
const { frames } = await rec;
const lums = frames.map((f) => probe.lum(f.px[0]));
const dark = frames.filter((f, i) => lums[i] < 100);
probe.check("W1", (await probe.until(() => probe.text("h1", /Settings/), 2000)) !== null, "the next page arrived");
probe.check("W2", dark.length === 0, "no flash of the window behind the page",
  dark.length ? `${dark.length} of ${frames.length} frames dark, ${Math.round(dark.at(-1).t - dark[0].t)} ms (first ${dark[0].file || "-"})` : `${frames.length} frames`);
