// The AI page not signed in (Chat.auth "signin": no fleet endpoint, no Claude login in the image - the non-root build,
// 11-04): "Sign in to Claude" on the page, its button on screen; tapped, Claude Code's login in the page's terminal; the
// terminal's end asks the auth again; signed in ("login") the chat is back; the owner's endpoint never shows it.
const G = () => window.__gw;
const asked = () => window.__aiAuthAsked ?? 0;

/** [el] wholly on screen. */
function onScreen(el) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth;
}

/** The sign-in state's button: says what it is, on screen; tapped, the login terminal, whose end asks the auth again. */
async function buttonFails(label, go) {
  const fails = [];
  if (!/Sign in to Claude/.test(go.closest(".ai-signin")?.textContent ?? "")) fails.push(`${label}: the sign-in state doesn't say "Sign in to Claude"`);
  // The page slides in: settled first.
  await G().until(() => onScreen(go), 2000);
  const r = go.getBoundingClientRect();
  if (!onScreen(go)) fails.push(`${label}: the Sign in button is off screen (at ${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)} in ${innerWidth}x${innerHeight})`);
  const before = asked();
  go.click();
  if (!(await G().until(() => document.querySelector(".ai-screen .ai-signin-term"), 3000))) fails.push(`${label}: tapping Sign in opened no login terminal`);
  window.__mockEvents.emit("term.exit", { id: "claude-signin", run: 1, code: 0 });
  if (!(await G().until(() => asked() > before, 2000))) fails.push(`${label}: the login's end didn't ask the auth again`);
  return fails;
}

/** Signed in, then the owner's endpoint: no sign-in state, the chat back. */
async function afterFails(label, S) {
  const fails = [];
  S.chat.value = { busy: false, items: [], auth: "login" };
  const back = () => !document.querySelector(".ai-screen .ai-signin") && document.querySelector(".ai-screen .ai-empty");
  if (!(await G().until(back, 3000))) fails.push(`${label}: signed in ("login"), the chat didn't come back`);
  S.chat.value = { busy: false, items: [], auth: "endpoint" };
  await G().frames(4);
  if (document.querySelector(".ai-screen .ai-signin")) fails.push(`${label}: the owner's endpoint showed the sign-in state`);
  return fails;
}

/** The scene: its failures. */
export async function aiSigninFails(label) {
  const S = await G().mod("./state.ts");
  const was = S.chat.value;
  S.page.value = -1;
  S.aiScreen.value = "chat";
  S.chat.value = { busy: false, items: [], auth: "signin" };
  const sel = ".ai-screen .ai-signin-go";
  const go = (await G().until(() => document.querySelector(sel), 4000)) && document.querySelector(sel);
  const fails = go ? await buttonFails(label, go) : [`${label}: no Sign in button on the AI page with auth "signin"`];
  fails.push(...(await afterFails(label, S)));
  S.chat.value = was;
  return fails;
}
