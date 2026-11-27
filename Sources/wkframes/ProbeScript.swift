/// `window.probe`, injected at document start. Everything a scenario uses: waiting, finding, clicking, pictures,
/// recordings and checks. Clicks are events made in the page – the real mouse and keyboard are never touched.
enum ProbeScript {
    static let source = """
    (() => {
      const native = (name) => window.webkit.messageHandlers[name];
      const P = window.probe = { checks: [], logs: [] };
      P.wait = (ms) => new Promise((r) => setTimeout(r, ms));
      P.$ = (sel, i = 0) => document.querySelectorAll(sel)[i] || null;
      P.$$ = (sel) => [...document.querySelectorAll(sel)];
      P.text = (sel, re) => [...document.querySelectorAll(sel)].find((e) => re.test(e.textContent || "")) || null;
      /** waits until fn() is truthy; resolves with its value, or null after ms */
      P.until = async (fn, ms = 5000, every = 50) => {
        const end = performance.now() + ms;
        for (;;) { const v = fn(); if (v) return v; if (performance.now() > end) return null; await P.wait(every); }
      };
      /** pointerdown, mousedown, pointerup, mouseup and click on the element's centre */
      P.click = (target, i = 0) => {
        const el = typeof target === "string" ? P.$(target, i) : target;
        if (!el) throw new Error("probe.click: nothing matches " + target);
        const r = el.getBoundingClientRect();
        const o = { bubbles: true, cancelable: true, composed: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0, pointerId: 1, pointerType: "mouse", isPrimary: true };
        el.dispatchEvent(new PointerEvent("pointerdown", o)); el.dispatchEvent(new MouseEvent("mousedown", o));
        el.dispatchEvent(new PointerEvent("pointerup", o)); el.dispatchEvent(new MouseEvent("mouseup", o));
        el.dispatchEvent(new MouseEvent("click", o));
      };
      /** keydown and keyup on the focused element */
      P.key = (key, opts = {}) => {
        const t = document.activeElement || document.body;
        for (const type of ["keydown", "keyup"]) t.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, cancelable: true, ...opts }));
      };
      /** one picture of the window as the screen shows it → resolves with its path */
      P.shot = (name) => native("wkframesShot").postMessage(String(name));
      /**
       * every new frame for ms → { dir, frames: [{ file, t, px }] }; t is ms since recording started.
       * The promise also has .started, which resolves once the first frame is in: act after it.
       * opts.points: [[x, y], …] in CSS pixels of the page – px gives each one's [r, g, b] in every frame,
       * for what the DOM can't tell you (a flash of the window behind the page, a layer drawn wrong).
       * opts.save: false keeps the pictures out of the out folder (pixels only).
       */
      P._started = {};
      P.rec = (name, ms, opts = {}) => {
        const started = new Promise((r) => { P._started[String(name)] = r; });
        const done = native("wkframesRec").postMessage({ name: String(name), ms, points: opts.points || [], save: opts.save !== false });
        // `await rec.started` before acting: the capture takes a moment to start, and a short glitch would be missed
        return Object.assign(done, { started });
      };
      /** a pass or fail line in the result; any fail makes the exit status 1 */
      P.check = (id, ok, what, detail = "") => { P.checks.push({ id, ok: !!ok, what, detail: String(detail) }); return !!ok; };
      P.log = (x) => { P.logs.push(x); return x; };
      /** relative luminance 0–255 of an [r, g, b] */
      P.lum = (px) => Math.round(0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]);
    })();
    """

    /// Runs the scenario once the first page has loaded, and posts what it returns.
    static func run(_ scenario: String) -> String {
        """
        (async () => {
          const probe = window.probe;
          const done = (x) => webkit.messageHandlers.wkframesDone.postMessage(JSON.stringify(x));
          try {
            const value = await (async () => {
        \(scenario)
            })();
            done({ value: value === undefined ? null : value, checks: probe.checks, logs: probe.logs });
          } catch (e) {
            done({ error: String(e), stack: String(e && e.stack || ""), checks: probe.checks, logs: probe.logs });
          }
        })();
        0
        """
    }
}
