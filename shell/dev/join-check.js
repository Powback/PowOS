// "Join your PowStation" (ui/screens.tsx JoinScreen, PowStation.kt; the user, 11-09: "proper device management and
// onboarding so I can use all of my devices", "we just need to give it a tenant URL"). Pinned, on the mock host
// (screens-mock.ts, booted with ?join=choose = a first run that hasn't picked yet):
//  - the setup step opens by itself: Join your PowStation / Use PowOS on its own, both on screen;
//  - Join: "looking…" at once (optimistic), then the address field prefilled with powstation.pow (found on the LAN);
//  - an unreachable address comes back in words; the real one shows "asking…" at once, then the code, big;
//  - approved (the approver's Devices card, here window.__joinApprove): "Part of Mats's PowOS", the hub's Claude, the
//    home/dock import and theme offers;
//  - Leave asks once, then standalone again; Settings' PowStation tile says which.
const G = () => window.__gw;
const root = () => document.querySelector("[data-join-phase]");
const phase = () => root()?.dataset.joinPhase ?? "";
const text = () => root()?.textContent ?? "";

/** [el] wholly on screen. */
function onScreen(el) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth;
}

const button = (re) => [...(root()?.querySelectorAll("button") ?? [])].find((b) => re.test(b.textContent ?? ""));

async function type(v) {
  const input = root()?.querySelector(".scr-field input");
  if (!input) return false;
  input.value = v;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  await G().frames(2);
  return true;
}

/** 1. a first run: the setup step by itself, both choices on screen. */
async function firstRun(f) {
  if (!(await G().until(() => phase() === "choose", 5000))) return f(false, `a first run shows no setup step (phase "${phase()}")`), null;
  const join = root().querySelector('[data-join-choice="join"]');
  const alone = root().querySelector('[data-join-choice="standalone"]');
  if (!join || !alone) return f(false, "the setup step lacks Join your PowStation / Use PowOS on its own"), null;
  f(onScreen(join) && onScreen(alone), "a setup choice is off screen");
  f(/Join your PowStation/.test(join.textContent) && /Use PowOS on its own/.test(alone.textContent), `the choices say "${text().slice(0, 160)}"`);
  return join;
}

/** 2. Join: looking at once, then the field prefilled with the hub found on the LAN. */
async function findHub(f, join) {
  join.click();
  await G().frames(2);
  f(phase() === "finding", `tapping Join shows "${phase()}" first (want "finding" at once)`);
  await G().until(() => phase() === "ready", 2000);
  const input = root()?.querySelector(".scr-field input");
  f(input?.value === "powstation.pow", `the address field holds "${input?.value}" (want powstation.pow, found on the LAN)`);
  f(root()?.querySelector('[data-join-found="yes"]'), "the field doesn't say the hub was found here");
}

/** 3. an unreachable address in words, then the code, big, with this device's name. */
async function askCode(f) {
  await type("nowhere.pow");
  button(/ask to join/)?.click();
  await G().frames(2);
  f(phase() === "asking", `Ask shows "${phase()}" first (want "asking" at once)`);
  f(await G().until(() => root()?.querySelector("[data-join-error]"), 2000), "an unreachable hub shows no reason");
  f(/couldn't reach nowhere\.pow/.test(text()), `the reason reads "${text().slice(0, 200)}"`);
  await type("powstation.pow");
  button(/ask to join/)?.click();
  f(await G().until(() => phase() === "code", 2000), `no code after asking (phase "${phase()}")`);
  const code = root()?.querySelector("[data-join-code]");
  f(code?.textContent === "BCDF-GHJK", `the code shows "${code?.textContent}"`);
  const big = code ? parseFloat(getComputedStyle(code).fontSize) : 0;
  const body = parseFloat(getComputedStyle(document.body).fontSize);
  f(big >= body * 1.8, `the code is ${big}px on a ${body}px page - not big enough to match at a glance`);
  f(/PowOS phone/.test(text()) && /Approve/.test(text()), `the code step doesn't say this device's name and where to approve: "${text().slice(0, 200)}"`);
}

/** 4. approved on another device: whose PowOS, the hub's Claude, the import and theme offers. */
async function approved(f) {
  window.__joinApprove();
  f(await G().until(() => phase() === "joined", 2000), `approval didn't reach the screen (phase "${phase()}")`);
  f(/Part of Mats's PowOS/.test(text()), `joined reads "${text().slice(0, 200)}"`);
  f(/Claude: default/.test(text()), "joined doesn't say the hub's Claude subscription");
  f(button(/import home and dock/) && button(/pick a theme/), "joined offers no home/dock import or theme");
}

/** 5. Leave: asked once, then standalone again. */
async function leave(f) {
  button(/^leave$/)?.click();
  await G().frames(2);
  f(button(/tap again to leave/), "Leave didn't ask once");
  button(/tap again to leave/)?.click();
  await G().frames(2);
  f(phase() === "leaving", `Leave confirmed shows "${phase()}" (want "leaving" at once)`);
  f(await G().until(() => phase() === "standalone", 2000), `after Leave the phase is "${phase()}"`);
  f(root()?.querySelector('[data-join-choice="standalone"].on'), "standalone isn't marked as how it runs now");
}

export async function joinFails(label) {
  const fails = [];
  const f = (ok, why) => ok || fails.push(`${label}: ${why}`);
  const join = await firstRun(f);
  if (!join) return fails;
  await findHub(f, join);
  await askCode(f);
  await approved(f);
  await leave(f);
  return fails;
}
