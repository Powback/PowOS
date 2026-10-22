// Headless: a sideways swipe on home turns the page and one back returns (gesture.ts pages), the drawer stays shut.
(async () => {
  const S = await importShim("./state.ts");
  const raf = () => new Promise((r) => requestAnimationFrame(r));
  const H = innerHeight, W = innerWidth, y = H * 0.5;
  const tgt = document.elementFromPoint(W * 0.5, y);
  const fire = (type, x) => { const t = new Touch({ identifier: 11, target: tgt, clientX: x, clientY: y }); tgt.dispatchEvent(new TouchEvent(type, { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true })); };
  const swipe = async (from, to) => { fire("touchstart", from); await raf(); for (let i = 1; i <= 8; i++) { fire("touchmove", from + ((to - from) * i) / 8); await raf(); } fire("touchend", to); await new Promise((r) => setTimeout(r, 500)); };
  const p0 = S.page.value, pages = S.pages.value.length;
  await swipe(W * 0.8, W * 0.2);
  const p1 = S.page.value;
  await swipe(W * 0.2, W * 0.8);
  return { pages, p0, afterLeft: p1, afterRight: S.page.value, drawer: S.drawer.value };
})()
