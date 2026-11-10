// The native Claude sign-in (claudesignin.tsx; the user, 11-06: "it should detect when signin is missing or needs
// refresh and have a login button which opens the url and shows the code input box"). Pinned:
//  - the AI page, sign-in missing (auth "signin") and needs refresh (auth "relogin", the fleet tenant's): the sheet says
//    so ("Sign in to Claude" / "Claude sign-in needed - powback"), its Login button on screen;
//  - Login: the code box shows at once (optimistic, before the host answers), the link opens (the host's), a wrong
//    code comes back in the authority's words, the right one signs in and the chat is back;
//  - a terminal tile whose claude printed "run /login": the sheet on the tile, Login there too;
//  - the owner's working endpoint never shows it; no terminal runs /login.
const G = () => window.__gw;
const opened = () => window.__signinOpened ?? 0;

/** [el] wholly on screen. */
function onScreen(el) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth;
}

const loginButton = (root) => [...root.querySelectorAll(".signin-go")].find((b) => /Login/.test(b.textContent ?? ""));

/** Types [v] in the code box and taps Sign in; false when there's no box or button. */
async function typeCode(root, v) {
  await G().until(() => root.querySelector(".signin-code"), 2000);
  const input = root.querySelector(".signin-code");
  if (!input) return false;
  input.value = v;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  await G().frames(2);
  const send = [...root.querySelectorAll(".signin-go")].find((b) => /Sign in/.test(b.textContent ?? ""));
  send?.click();
  await G().frames(2);
  return !!send;
}

/** Login: the code box at once (optimistic), then the host's link opened. */
async function loginFails(label, root) {
  const go = loginButton(root);
  if (!go) return [`${label}: no Login button`];
  const fails = [];
  await G().until(() => onScreen(go), 2000);
  if (!onScreen(go)) fails.push(`${label}: the Login button is off screen`);
  const before = opened();
  go.click();
  await G().frames(2);
  if (!root.querySelector(".signin-code")) fails.push(`${label}: tapping Login didn't show the code box at once`);
  if (!(await G().until(() => opened() > before, 2000))) fails.push(`${label}: Login opened no sign-in link`);
  return fails;
}

/** A wrong code: "Signing in…" at once, then the authority's error. */
async function wrongCodeFails(label, root) {
  const fails = [];
  if (!(await typeCode(root, "wrong#code"))) fails.push(`${label}: no Sign in button under the code box`);
  if (!/Signing in/.test(root.textContent ?? "")) fails.push(`${label}: Sign in showed nothing at once (no "Signing in…")`);
  const err = () => /invalid code/.test(root.querySelector(".signin-err")?.textContent ?? "");
  if (!(await G().until(err, 2000))) fails.push(`${label}: a wrong code's error didn't come back`);
  return fails;
}

/** Login -> code box -> wrong code -> Login again -> right code: signed in. */
async function flowFails(label, root) {
  const fails = await loginFails(label, root);
  if (fails.some((f) => f.endsWith("no Login button"))) return fails;
  fails.push(...(await wrongCodeFails(label, root)));
  fails.push(...(await loginFails(`${label} (again)`, root)));
  await typeCode(root, "good#state");
  const done = () => /Signed in to Claude/.test(document.body.textContent ?? "") || !document.querySelector(".ai-screen .ai-signin");
  if (!(await G().until(done, 2000))) fails.push(`${label}: the right code didn't sign in`);
  return fails;
}

const fresh = (state, tenant = "powback", mode = "authority") => ({
  phase: "", url: "", error: "", mode, state, tenant, why: state === "refresh" ? "refresh token itself has expired" : "", canLogin: true,
});

async function pageFails(label, auth, signin, title) {
  window.__mockChat({ busy: false, items: [], auth, signin });
  await G().until(() => document.querySelector(".ai-screen .ai-signin"), 4000);
  const root = document.querySelector(".ai-screen .ai-signin");
  if (!root) return [`${label}: no sign-in sheet on the AI page with auth "${auth}"`];
  const fails = [];
  if (!(root.textContent ?? "").includes(title)) fails.push(`${label}: the sheet doesn't say "${title}" (${auth})`);
  if (root.querySelector(".term")) fails.push(`${label}: the sign-in is a terminal (no /login in terminals)`);
  fails.push(...(await flowFails(`${label} ${auth}`, root)));
  if (!(await G().until(() => !document.querySelector(".ai-screen .ai-signin") && document.querySelector(".ai-screen .ai-empty"), 3000)))
    fails.push(`${label}: signed in (${auth}), the chat didn't come back`);
  return fails;
}

/** A terminal tile whose claude asks for a login: noticed across chunks, the sheet on the tile. */
async function terminalFails(label) {
  const T = await G().mod("./ui/claudesignin.tsx");
  window.__mockChat({ auth: "endpoint", signin: fresh("refresh") });
  T.watchTerminal("gate-term", "\x1b[31mInvalid API key\x1b[0m · Please run /lo");
  T.watchTerminal("gate-term", "gin\r\n");
  if (!T.loginAsked.value.has("gate-term")) return [`${label}: claude's "Please run /login" wasn't noticed`];
  const fails = [];
  T.watchTerminal("other-term", "ls -la\r\nlogin.txt  logins/\r\n");
  if (T.loginAsked.value.has("other-term")) fails.push(`${label}: plain output was taken for a login prompt`);
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:0;top:0;width:360px;height:300px;z-index:99999";
  document.body.append(host);
  const { h, render } = await G().mod("preact");
  render(h(T.TerminalLogin, { id: "gate-term" }), host);
  await G().frames(3);
  if (!host.querySelector(".term-signin .signin-go")) fails.push(`${label}: the terminal tile shows no Login button`);
  if (!/Claude sign-in needed - powback/.test(host.textContent ?? "")) fails.push(`${label}: the tile's sheet doesn't name the tenant`);
  render(null, host);
  host.remove();
  return fails;
}

/** Install Claude tapped: progress at once, the installer's line, then the sign-in. */
async function installTapFails(label, root, go) {
  const fails = [];
  await G().until(() => onScreen(go), 2000);
  if (!onScreen(go)) fails.push(`${label}: the Install Claude button is off screen`);
  go.click();
  await G().frames(2);
  if (!root.querySelector(".install-progress")) fails.push(`${label}: tapping Install Claude showed no progress at once`);
  const line = () => /Downloading Claude Code/.test(root.querySelector(".install-line")?.textContent ?? "");
  if (!(await G().until(line, 2000))) fails.push(`${label}: the installer's progress line never showed`);
  if (!(await G().until(() => document.querySelector(".ai-screen .ai-signin"), 3000)))
    fails.push(`${label}: installed, the page didn't move on to Sign in to Claude`);
  return fails;
}

/**
 * Claude not installed (auth "install"; the user, 11-10 razr: "it shouldnt say sign in to claude if claude is not
 * installed, it should show install claude"): Install Claude, never the sign-in; the tap shows progress at once, the
 * installer's lines live, then the sign-in.
 */
async function installFails(label) {
  window.__mockChat({ busy: false, items: [], auth: "install", install: { running: false, line: "", error: "" }, signin: fresh("missing", "", "direct") });
  await G().until(() => document.querySelector(".ai-screen .ai-install"), 4000);
  const root = document.querySelector(".ai-screen .ai-install");
  if (!root) return [`${label}: no Install Claude on the AI page with auth "install"`];
  const fails = [];
  if (/Sign in to Claude/.test(root.textContent ?? "")) fails.push(`${label}: Claude isn't installed but the page says Sign in to Claude`);
  const go = root.querySelector(".install-go");
  if (!go || !/Install Claude/.test(go.textContent ?? "")) return [...fails, `${label}: no Install Claude button`];
  fails.push(...(await installTapFails(label, root, go)));
  return fails;
}

/** The scene: its failures. */
export async function aiSigninFails(label) {
  const S = await G().mod("./state.ts");
  const was = S.chat.value;
  S.page.value = -1;
  S.aiScreen.value = "chat";
  const fails = [];
  fails.push(...(await pageFails(label, "relogin", fresh("refresh"), "Claude sign-in needed - powback")));
  fails.push(...(await pageFails(label, "signin", fresh("missing", "", "direct"), "Sign in to Claude")));
  window.__mockChat({ auth: "endpoint", signin: fresh("ok") });
  await G().frames(4);
  if (document.querySelector(".ai-screen .ai-signin")) fails.push(`${label}: the owner's working endpoint showed the sign-in`);
  fails.push(...(await terminalFails(label)));
  fails.push(...(await installFails(label)));
  window.__mockChat(was);
  return fails;
}
