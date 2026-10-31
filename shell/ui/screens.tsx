/**
 * Settings and the screens it opens, full screen over home (screens.ts has which are open): style (the theme, its
 * backgrounds, icons, the terminal's font), the community themes, the widget store, Linux, coding agents, packages
 * (pacman and the AUR) and licenses - what the Compose launcher had as its own screens. Each draws the state the host
 * sends (ShellScreens.kt) and hands taps back to it; the work (installs, downloads, the theme) is the host's.
 *
 * Icon first: every screen, section and action is an icon (ui/icons.tsx) with a word, the settings hub a grid of them.
 */
import type { ComponentChildren, FunctionComponent } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import {
  act,
  closeScreen,
  type CodingAgent,
  type CodingState,
  type Job,
  type LicensesState,
  type LinuxScreenState,
  type LinuxStatus,
  openScreen,
  type PackagesState,
  type ScreenName,
  screens,
  screenTarget,
  setInnerBack,
  type SettingsState,
  type StoreState,
  type StoreWidget,
  type StyleState,
  type ThemesState,
  useScreen,
} from "../screens.ts";
import { Icon, type IconName } from "./icons.tsx";
import { mobileDockPlacement, unfoldedDockPlacement, desktopDockPlacement, validDockPosition, apps, ccV3, pullOverApps, pullPanels, separatePanels, speechEngine } from "../state.ts";
import { iconTint } from "./icontint.ts";
import { ALIGNS, alignChoice, type AlignMode, type AlignSurface } from "./align.ts";

/** "icon colours" options after "the apps'": theme hues, the accent. */
const TINTS = ["hue", "mono"];
import { drawerRecents } from "./drawer.tsx";
import { PetToggle } from "./pet.tsx";

/** Its touches are its own: home's swipes under it don't see them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

/** Search paths distinguish repeated controls such as left/right edge width. A disabled child reveals its parent. */
function settingElement(root: HTMLElement, target: string): HTMLElement | null {
  let current: HTMLElement | null = root;
  for (const part of target.split("/")) {
    const found: HTMLElement | undefined = [...current.querySelectorAll<HTMLElement>("[data-setting]")].find((e) => e.dataset.setting === part);
    if (!found) return current === root ? null : current;
    current = found;
  }
  return current;
}

/** A screen: back, its icon and title, [actions] at the far end; the body scrolls. */
function Frame({
  icon,
  title,
  actions,
  onBack,
  children,
}: {
  icon: IconName;
  title: string;
  actions?: ComponentChildren;
  /** What the back arrow closes, when not the screen (a page inside it). */
  onBack?: () => void;
  children: ComponentChildren;
}) {
  const body = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => body.current?.scrollTo(0, 0), [title]);
  useEffect(() => {
    const target = screenTarget.value;
    const root = body.current;
    if (!target || !root) return;
    let frame = 0;
    let highlighted: HTMLElement | null = null;
    const clear = () => { highlighted?.removeAttribute("data-search-highlight"); };
    const reveal = () => {
      const el = settingElement(root, target);
      if (!el) return;
      observer.disconnect();
      highlighted = el;
      el.dataset.searchHighlight = "true";
      const offset = el.getBoundingClientRect().top - root.getBoundingClientRect().top;
      root.scrollTop += offset - Math.max(0, (root.clientHeight - el.clientHeight) / 2);
      el.tabIndex = -1;
      el.focus({ preventScroll: true });
    };
    // Let child effects (theme strips, async settings state) finish before moving the settings scroller.
    const schedule = () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(() => { frame = requestAnimationFrame(reveal); }); };
    const observer = new MutationObserver(schedule);
    observer.observe(root, { childList: true, subtree: true });
    root.addEventListener("pointerdown", clear, { once: true });
    schedule();
    return () => { observer.disconnect(); cancelAnimationFrame(frame); root.removeEventListener("pointerdown", clear); clear(); };
  }, [title, screenTarget.value]);
  return (
    <div class="scr tile sheet" {...own}>
      <header class="scr-top">
        <button type="button" class="scr-back" aria-label="back" onClick={() => (onBack ? onBack() : closeScreen())}>
          <Icon name="chevronLeft" size={26} />
        </button>
        <Icon name={icon} size={20} class="scr-icon" />
        <span class="scr-title">{title}</span>
        {actions}
      </header>
      <div class="scr-body" ref={body}>
        {children}
      </div>
    </div>
  );
}

/** An icon alone, with its word for screen readers and a long press's tooltip. */
function IconButton({ icon, label, onClick, tone }: { icon: IconName; label: string; onClick: () => void; tone?: "danger" | "muted" }) {
  return (
    <button type="button" class={`scr-iconbtn ${tone ?? ""}`} aria-label={label} title={label} onClick={onClick}>
      <Icon name={icon} size={22} />
    </button>
  );
}

/** An icon and a word, as a pill: an action on a row. */
function Action({
  icon,
  label,
  onClick,
  tone,
  disabled,
}: {
  icon: IconName;
  label: string;
  onClick?: () => void;
  tone?: "danger" | "muted" | "primary";
  disabled?: boolean;
}) {
  return (
    <button type={onClick ? "button" : "submit"} class={`scr-act ${tone ?? ""}`} onClick={onClick} disabled={disabled}>
      <Icon name={icon} size={16} />
      <span>{label}</span>
    </button>
  );
}

function Section({ icon, title, actions, children }: { icon: IconName; title: string; actions?: ComponentChildren; children: ComponentChildren }) {
  return (
    <section class="scr-section" data-setting={title}>
      <h3 class="scr-heading">
        <Icon name={icon} size={16} />
        <span>{title}</span>
        {actions && <span class="scr-heading-actions">{actions}</span>}
      </h3>
      {children}
    </section>
  );
}

/** A job's last lines while it runs, or why it failed. */
function JobLog({ job, lines = 4 }: { job: Job; lines?: number }) {
  if (!job || !job.log.length) return null;
  const log = job.state === "failed" ? ["failed:", ...job.log] : job.log;
  return (
    <div class={`scr-log ${job.state === "failed" ? "failed" : ""}`}>
      {log.slice(-lines).map((l, i) => (
        <div key={i}>{l}</div>
      ))}
    </div>
  );
}

function Loading() {
  return <div class="scr-note muted">loading…</div>;
}

/** An on/off choice as a segmented control: the picked half fills with the accent. */
function Segmented({ options, picked, onPick }: { options: string[]; picked: number; onPick: (i: number) => void }) {
  return (
    <span class="scr-seg">
      {options.map((o, i) => (
        <button type="button" key={o} class={i === picked ? "on" : ""} onClick={() => onPick(i)}>
          {o}
        </button>
      ))}
    </span>
  );
}

/** One surface's alignment for one mode: top / middle / bottom. */
function AlignOption({ label, surface, mode }: { label: string; surface: AlignSurface; mode: AlignMode }) {
  const choice = alignChoice(surface, mode);
  return (
    <Option label={label}>
      <Segmented options={ALIGNS} picked={ALIGNS.indexOf(choice.value)} onPick={(i) => (choice.value = ALIGNS[i])} />
    </Option>
  );
}

/** A labeled option row: the label, then its control. */
function Option({ label, children }: { label: string; children: ComponentChildren }) {
  return (
    <div class="scr-option" data-setting={label}>
      <span class="scr-option-label muted">{label}</span>
      <div class="scr-option-control">{children}</div>
    </div>
  );
}

const DOCK_SIDES = ["bottom", "left", "right"];
/** One mode's dock placement (state.ts dockMode): folded, unfolded or the desktop shell, each its own choice. */
function DockOption({ label, placement, fallback }: { label: string; placement: { value: string }; fallback: string }) {
  return (
    <Option label={label}>
      <Segmented options={DOCK_SIDES} picked={DOCK_SIDES.indexOf(validDockPosition(placement.value, fallback))} onPick={(i) => (placement.value = DOCK_SIDES[i])} />
    </Option>
  );
}

/** A text field that brings the keyboard up (the page asks for it: the WebView doesn't on its own). */
function Field({
  value,
  onInput,
  placeholder,
  icon = "magnify",
  autofocus,
}: {
  value: string;
  onInput: (v: string) => void;
  placeholder: string;
  icon?: IconName;
  autofocus?: boolean;
}) {
  const el = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (autofocus) {
      el.current?.focus();
      powos.keyboard.show();
    }
  }, []);
  return (
    <label class="scr-field">
      <Icon name={icon} size={18} />
      <input
        ref={el}
        value={value}
        placeholder={placeholder}
        autocomplete="off"
        autocapitalize="off"
        spellcheck={false}
        onInput={(e) => onInput((e.currentTarget as HTMLInputElement).value)}
        onFocus={() => powos.keyboard.show()}
      />
      {value && (
        <button type="button" class="scr-field-clear" aria-label="clear" onClick={() => onInput("")}>
          <Icon name="close" size={16} />
        </button>
      )}
    </label>
  );
}

/** A question over the screen: what's about to happen, and the two answers. */
function Confirm({
  title,
  text,
  yes,
  icon,
  danger,
  onYes,
  onNo,
}: {
  title: string;
  text: string;
  yes: string;
  icon: IconName;
  danger?: boolean;
  onYes: () => void;
  onNo: () => void;
}) {
  useEffect(() => {
    setInnerBack(onNo);
    return () => setInnerBack(null);
  }, []);
  return (
    <div class="scr-scrim" onClick={(e) => e.target === e.currentTarget && onNo()}>
      <div class="scr-confirm tile sheet pop">
        <div class={`scr-confirm-title ${danger ? "danger" : ""}`}>{title}</div>
        <div class="scr-confirm-text muted">{text}</div>
        <div class="scr-confirm-do">
          <Action icon="close" label="cancel" tone="muted" onClick={onNo} />
          <Action icon={icon} label={yes} tone={danger ? "danger" : "primary"} onClick={onYes} />
        </div>
      </div>
    </div>
  );
}

const ago = (ms: number) => {
  const minutes = Math.floor((Date.now() - ms) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  if (minutes < 48 * 60) return `${Math.floor(minutes / 60)}h ago`;
  return `${Math.floor(minutes / (24 * 60))}d ago`;
};

const size = (bytes: number) => (bytes >= 2 ** 30 ? `${(bytes / 2 ** 30).toFixed(1)} GB` : `${Math.floor(bytes / 2 ** 20)} MB`);

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

// --- settings

/** Where Linux stands, in a line (the hub's tile, the screens that need it). */
function linuxLine(l: LinuxStatus | undefined, powosSession: boolean) {
  switch (l?.state) {
    case "installed":
      return "installed";
    case "installing":
      return `installing${l.progress != null ? ` ${Math.round(l.progress * 100)}%` : ""}`;
    case "failed":
      return "setup stopped · retry";
    case "removing":
      return "removing…";
    case "checking":
    case undefined:
      return "…";
    default:
      return powosSession ? "optional Arch, beside PowOS's own" : "not installed · Arch for terminal apps and agents";
  }
}

function Updates({ u }: { u: NonNullable<SettingsState["updates"]> }) {
  const working = u.job?.state === "working";
  const count = u.packages.length + u.tools.length;
  const status = working
    ? "updating…"
    : u.checking
      ? "checking…"
      : u.checked == null
        ? "not checked yet"
        : u.error
          ? u.error
          : count === 0
            ? `up to date · checked ${ago(u.checked)}`
            : [u.packages.length ? plural(u.packages.length, "package") : "", u.tools.join(", ")].filter(Boolean).join(" · ");
  return (
    <div class="scr-card tile" data-setting="system updates">
      <div class="scr-row">
        <Icon name="update" size={22} class="scr-row-icon" />
        <div class="scr-row-text">
          <div>system updates</div>
          <div class={`scr-sub ${count && !working ? "accent" : "muted"}`}>{status}</div>
        </div>
        {!working && !u.checking && (count > 0 ? <Action icon="trayArrowDown" label="update all" tone="primary" onClick={() => act("settings", "update")} /> : <Action icon="refresh" label="check" tone="muted" onClick={() => act("settings", "check")} />)}
      </div>
      <JobLog job={u.job} />
    </div>
  );
}

function SettingsScreen() {
  const s = useScreen<SettingsState>("settings");
  const installed = s?.linux.state === "installed";
  const needs = (name: ScreenName) => () => openScreen(installed ? name : "linux");
  const tiles: [IconName, string, string, () => void][] = [
    ["palette", "style", s?.theme ?? "theme, background, icons", () => openScreen("style")],
    ["storefrontOutline", "widget store", "widgets for home", () => openScreen("store")],
    ["penguin", "linux", linuxLine(s?.linux, s?.powos ?? false), () => openScreen("linux")],
    ["robotOutline", "coding agents", installed ? (s?.agent ? `default: ${s.agent}` : "Claude Code, OpenCode, …") : "needs linux", needs("coding")],
    ["packageVariant", "packages", installed ? "pacman and the AUR" : "needs linux", needs("aur")],
    ["cellphoneCog", "android settings", "the phone's own", () => act("settings", "android")],
    ["arrowLeft", "gestures", "edge gestures, quick tools", () => openScreen("gestures")],
    // Dictation's engine: a tap cycles it - streamed to the GPU voice agent (the default), stt.pow's requests, the
    // phone's own (GpuSpeech.kt SpeechEngines).
    [
      "microphoneOutline",
      "voice",
      speechEngine.value === "ondevice"
        ? "transcription: on the phone"
        : speechEngine.value === "gpu-http"
          ? "transcription: GPU (stt.pow requests)"
          : "transcription: GPU (streaming)",
      () =>
        (speechEngine.value =
          speechEngine.value === "ondevice" ? "gpu" : speechEngine.value === "gpu-http" ? "ondevice" : "gpu-http"),
    ],
    ["scaleBalance", "licenses", "open source in PowOS", () => openScreen("licenses")],
  ];
  return (
    <Frame icon="cogOutline" title="settings">
      {s?.setup && (
        <div class="scr-card tile">
          <div class="scr-row">
            <Icon name={s.setup.state === "failed" ? "alertCircleOutline" : "update"} size={22} class="scr-row-icon" />
            <div class="scr-row-text">{s.setup.state === "working" ? `updating the system: ${s.setup.action.toLowerCase()}…` : "a system update didn't finish"}</div>
            {s.setup.state === "failed" && <Action icon="refresh" label="retry" onClick={() => act("settings", "retryUpdates")} />}
          </div>
          <JobLog job={s.setup} />
        </div>
      )}
      {s?.updates && <Updates u={s.updates} />}
      <div class="scr-grid">
        {tiles.map(([icon, title, sub, open]) => (
          <button type="button" key={title} class="scr-tile tile" data-setting={title} onClick={open}>
            <Icon name={icon} size={30} class="scr-tile-icon" />
            <span class="scr-tile-title">{title}</span>
            <span class="scr-tile-sub muted">{sub}</span>
          </button>
        ))}
      </div>
      {s && <div class="scr-note muted">PowOS {s.version}</div>}
    </Frame>
  );
}

// --- style

function InstallStatus({ i, onClear }: { i: StyleState["installing"]; onClear: () => void }) {
  if (!i) return null;
  if (i.state === "running") return <div class="scr-note accent">installing {i.name}… {i.megabytes} MB</div>;
  return (
    <button type="button" class="scr-note danger" onClick={onClear}>
      install failed: {i.message} <Icon name="close" size={14} />
    </button>
  );
}

/** A strip that scrolls sideways, the picked item in view as it opens. */
function Strip({ children, picked }: { children: ComponentChildren; picked: string | null }) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    el.current?.querySelector<HTMLElement>(".on")?.scrollIntoView({ inline: "center", block: "nearest" });
  }, [picked]);
  return (
    <div class="scr-strip" ref={el}>
      {children}
    </div>
  );
}

function StyleScreen() {
  const s = useScreen<StyleState>("style");
  const [url, setUrl] = useState<string | null>(null);
  const [removing, setRemoving] = useState(false);
  if (!s) {
    return (
      <Frame icon="palette" title="style">
        <Loading />
      </Frame>
    );
  }
  const current = s.themes.find((t) => t.name === s.current);
  const install = (e: Event) => {
    e.preventDefault();
    if (!url?.trim()) return;
    act("style", "install", url.trim());
    setUrl(null);
    powos.keyboard.hide();
  };
  return (
    <Frame icon="palette" title="style">
      <Section
        icon="palette"
        title="theme"
        actions={
          <>
            <IconButton icon="web" label="community themes" onClick={() => openScreen("themes")} />
            <IconButton icon="github" label="install from GitHub" onClick={() => setUrl(url === null ? "" : null)} />
          </>
        }
      >
        {url !== null && (
          <form class="scr-inline" onSubmit={install}>
            <Field value={url} onInput={setUrl} placeholder="github.com/owner/repo" icon="github" autofocus />
            <Action icon="trayArrowDown" label="install" tone="primary" />
          </form>
        )}
        {url !== null && <div class="scr-note muted">A theme's GitHub repo. It replaces an installed theme of the same name.</div>}
        <InstallStatus i={s.installing} onClear={() => act("style", "clearError")} />
        {!s.complete && (
          <div class="scr-card tile">
            <div class="scr-row">
              <Icon name="trayArrowDown" size={22} class="scr-row-icon" />
              <div class="scr-row-text scr-sub">
                {s.download.partial ? "Omarchy's other themes are downloading from github.com/omacom/omarchy (~70 MB)." : "Omarchy's themes aren't here yet: github.com/omacom/omarchy (~70 MB)."}
              </div>
              {s.download.state === "running" ? (
                <span class="accent scr-sub">{s.download.megabytes} MB</span>
              ) : (
                <Action icon={s.download.state === "failed" ? "refresh" : "trayArrowDown"} label={s.download.state === "failed" ? "retry" : "download"} onClick={() => act("style", "download")} />
              )}
            </div>
            {s.download.state === "failed" && <div class="scr-log failed">{s.download.message}</div>}
          </div>
        )}
        <Strip picked={s.current}>
          {s.themes.map((t) => (
            <button
              type="button"
              key={t.name}
              class={`scr-theme ${t.name === s.current ? "on" : ""}`}
              style={{ background: t.colors.background, color: t.colors.foreground }}
              onClick={() => act("style", "apply", t.name)}
            >
              <img src={t.preview} alt="" loading="lazy" />
              <span class="scr-theme-name">
                <span>{t.title}</span>
                <span class="scr-dots">
                  {["accent", "red", "green", "yellow"].map((k) => (
                    <i key={k} style={{ background: t.colors[k] ?? "gray" }} />
                  ))}
                </span>
              </span>
            </button>
          ))}
        </Strip>
        {s.own && current && (
          <div class="scr-row">
            <Icon name={s.source ? "github" : "pencilOutline"} size={18} class="muted" />
            <span class="scr-row-text muted scr-ellipsis">{s.source ?? "your own theme"}</span>
            {s.source && <IconButton icon="update" label="update" onClick={() => act("style", "update", current.name)} />}
            <IconButton icon="deleteOutline" label="remove" tone="danger" onClick={() => setRemoving(true)} />
          </div>
        )}
      </Section>
      {current && (
        <Section icon="wallpaper" title="background">
          <Strip picked={s.background}>
            {s.backgrounds.map((b) => (
              <button type="button" key={b.name} class={`scr-thumb ${b.name === s.background ? "on" : ""}`} onClick={() => act("style", "background", b.name)}>
                <img src={b.image} alt="" loading="lazy" />
              </button>
            ))}
            <button type="button" class="scr-thumb add" aria-label="add an image" onClick={() => act("style", "addImage")}>
              <Icon name="imagePlusOutline" size={28} />
            </button>
          </Strip>
          <button type="button" class={`scr-row scr-wallpaper ${s.liveWallpaper ? "done" : ""}`} disabled={s.liveWallpaper} onClick={() => act("style", "liveWallpaper")}>
            <Icon name={s.liveWallpaper ? "checkCircleOutline" : "cellphoneCog"} size={20} class="scr-row-icon" />
            <span class="scr-row-text scr-sub">
              {s.liveWallpaper ? "Android's wallpaper and system colors follow the theme (system colors after the screen turns off)" : "use as Android's wallpaper and system colors"}
            </span>
          </button>
        </Section>
      )}
      <Section icon="apps" title="home">
        <DockOption label="folded dock position" placement={mobileDockPlacement} fallback="bottom" />
        <DockOption label="unfolded dock position" placement={unfoldedDockPlacement} fallback="bottom" />
        <DockOption label="desktop dock position" placement={desktopDockPlacement} fallback="left" />
        <Option label="swipe up from the left: PowOS AI">
          <Segmented options={["on", "off"]} picked={pullPanels.value === "on" ? 0 : 1} onPick={(i) => (pullPanels.value = i === 0 ? "on" : "off")} />
        </Option>
        <Option label="swipe up from a bottom corner over apps: apps, PowOS AI">
          <Segmented options={["on", "off"]} picked={pullOverApps.value === "on" ? 0 : 1} onPick={(i) => (pullOverApps.value = i === 0 ? "on" : "off")} />
        </Option>
        <Option label="recent apps in the drawer">
          <Segmented options={["on", "off"]} picked={drawerRecents.value === "on" ? 0 : 1} onPick={(i) => (drawerRecents.value = i === 0 ? "on" : "")} />
        </Option>
        <Option label="separate notifications & controls">
          <Segmented options={["on", "off"]} picked={separatePanels.value === "on" ? 0 : 1} onPick={(i) => (separatePanels.value = i === 0 ? "on" : "off")} />
        </Option>
        <Option label="control center">
          <Segmented options={["simple", "classic"]} picked={ccV3.value === "v3" ? 0 : 1} onPick={(i) => (ccV3.value = i === 0 ? "v3" : "classic")} />
        </Option>
        {/* The pet (ui/pet.tsx; also `powos pet on|off`): off by default - off, it shows and runs nothing. */}
        <PetToggle
          render={(on, set) => (
            <Option label="pet">
              <Segmented options={["on", "off"]} picked={on ? 0 : 1} onPick={(i) => set(i === 0)} />
            </Option>
          )}
        />
      </Section>
      {/* The theme's alignment (ui/align.ts): each surface top / middle / bottom, folded and unfolded, applied at once. */}
      <Section icon="tuneVariant" title="alignment">
        {(["unfolded", "folded"] as AlignMode[]).flatMap((m) =>
          ([["launcher", "launcher"], ["shade", "notifications"], ["control", "control center"]] as [AlignSurface, string][]).map(([sf, name]) => (
            <AlignOption key={`${sf}.${m}`} label={`${m} ${name}`} surface={sf} mode={m} />
          )),
        )}
      </Section>
      <Section icon="apps" title="icons">
        {/* The page's own (ui/icontint.ts): each icon redrawn once - its hues the theme's, all the accent - or as drawn. */}
        <Option label="icon colours">
          <Segmented options={["the apps'", "theme hues", "accent"]} picked={TINTS.indexOf(iconTint.value) + 1} onPick={(i) => (iconTint.value = TINTS[i - 1] ?? "")} />
        </Option>
        {s.flags.map((f) => (
          <Option key={f.key} label={f.label}>
            <Segmented options={[f.on, f.off]} picked={f.value ? 0 : 1} onPick={(i) => act("style", "flag", [f.key, i === 0])} />
          </Option>
        ))}
      </Section>
      {s.terminal && (
        <Section icon="console" title="terminal">
          <Option label="font">
            <span class="scr-chips">
              {s.terminal.families.map((f) => (
                <button type="button" key={f} class={`scr-chip ${f === s.terminal!.family ? "on" : ""}`} onClick={() => act("style", "font", f)}>
                  {f}
                </button>
              ))}
            </span>
          </Option>
          <Option label="text">
            <Segmented options={s.terminal.presets.map((p) => p.label)} picked={s.terminal.presets.findIndex((p) => p.value === s.terminal!.text)} onPick={(i) => act("style", "text", s.terminal!.presets[i].value)} />
          </Option>
          <div class="scr-note muted">
            terminals opened from now on · {s.terminal.size} pt · {s.terminal.columns} columns in portrait
          </div>
        </Section>
      )}
      <div class="scr-note muted">more, like the bar's colors: {s.styleFile}</div>
      {removing && current && (
        <Confirm
          title={`remove ${current.title.toLowerCase()}?`}
          text={s.builtIn ? "Your changes to it go; Omarchy's version stays." : "It's deleted from the phone and from Linux."}
          yes="remove"
          icon="deleteOutline"
          danger
          onNo={() => setRemoving(false)}
          onYes={() => {
            setRemoving(false);
            act("style", "remove", current.name);
          }}
        />
      )}
    </Frame>
  );
}

// --- community themes

function ThemesScreen() {
  const s = useScreen<ThemesState>("themes");
  const [q, setQ] = useState("");
  const [confirm, setConfirm] = useState<ThemesState["entries"][number] | null>(null);
  const query = q.trim().toLowerCase();
  const shown = (s?.entries ?? []).filter((e) => !query || e.title.toLowerCase().includes(query) || e.repo.toLowerCase().includes(query));
  const running = s?.installing?.state === "running";
  return (
    <Frame icon="web" title="community themes" actions={<IconButton icon="refresh" label="refresh" onClick={() => act("themes", "refresh")} />}>
      <Field value={q} onInput={setQ} placeholder={`search ${s?.entries.length ?? ""} themes`} />
      <button type="button" class="scr-note muted scr-link" onClick={() => act("themes", "page")}>
        made by the community, listed on omarchy.org/themes · installed from GitHub <Icon name="openInNew" size={12} />
      </button>
      {s && <InstallStatus i={s.installing} onClear={() => act("style", "clearError")} />}
      {!s || (s.loading && !s.entries.length) ? (
        <Loading />
      ) : s.error && !s.entries.length ? (
        <div class="scr-note danger">{s.error}</div>
      ) : (
        s.entries.length > 0 && !shown.length && <div class="scr-note muted">nothing matches "{q.trim()}"</div>
      )}
      <div class="scr-cards">
        {shown.map((e) => (
          <button
            type="button"
            key={e.repo}
            class={`scr-card-pick tile ${e.inUse ? "on" : ""}`}
            onClick={() => {
              if (e.installedAs) act("style", "apply", e.installedAs);
              else if (!running) setConfirm(e);
            }}
          >
            <img src={e.image} alt="" loading="lazy" class="scr-shot" />
            <span class="scr-card-name">{e.title}</span>
            <span class={`scr-sub ${e.running ? "accent" : e.installedAs ? "green" : "muted"} scr-ellipsis`}>
              {e.running ? "installing…" : e.inUse ? "✓ in use" : e.installedAs ? "✓ installed" : e.repo.replace("github.com/", "")}
            </span>
          </button>
        ))}
      </div>
      {confirm && (
        <Confirm
          title={`install ${confirm.title.toLowerCase()}?`}
          text={
            `From ${confirm.repo}. Linux gets its colors and wallpapers, not its scripts or terminal configs.` +
            (confirm.replaces?.startsWith("own:")
              ? ` It replaces your ${confirm.replaces.slice(4)}.`
              : confirm.replaces
                ? ` It goes over Omarchy's ${confirm.replaces.slice(8)}; removing it brings that back.`
                : "")
          }
          yes="install"
          icon="trayArrowDown"
          onNo={() => setConfirm(null)}
          onYes={() => {
            setConfirm(null);
            act("themes", "install", confirm.url);
          }}
        />
      )}
    </Frame>
  );
}

// --- widget store

const ALL = "all";
const OTHER = "other";
const INSTALLED = "installed";

function widgetStatus(e: StoreWidget, linux: boolean): [string, string] {
  if (e.busy) return [e.busy, "accent"];
  if (e.update) return ["update available", "accent"];
  if (e.installed) return ["✓ installed", "green"];
  if (!e.supported) return ["needs a newer launcher", "danger"];
  if (!linux && e.needsLinux) return ["needs linux", "muted"];
  return [`${e.category ?? OTHER}${e.size ? ` · ${e.size}` : ""}`, "muted"];
}

function WidgetPage({ s, e, onBack }: { s: StoreState; e: StoreWidget; onBack: () => void }) {
  useEffect(() => {
    setInnerBack(onBack);
    return () => setInnerBack(null);
  }, [e.id]);
  const message = s.message?.id === e.id ? s.message.text : null;
  return (
    <Frame icon="storefrontOutline" title={e.name} onBack={onBack}>
      {e.preview && <img class="scr-preview" src={e.preview} alt="" />}
      <div class="scr-sub muted">
        {e.category ?? OTHER} · {e.author} · v{e.version} · {e.license}
        {e.size ? ` · ${e.size}` : ""}
      </div>
      <div class="scr-text">{e.description}</div>
      <div class="scr-row">
        {e.busy ? (
          <span class="accent">{e.busy}</span>
        ) : !e.supported ? (
          <span class="danger scr-sub">needs a newer launcher (owl {e.owl}); update PowOS to install it</span>
        ) : e.update ? (
          <Action icon="update" label={`update ${e.installed} → ${e.version}`} tone="primary" onClick={() => act("store", "install", e.id)} />
        ) : e.installed ? (
          <span class="green">✓ on your home screen</span>
        ) : (
          <Action icon="plus" label={`add to page ${s.page}`} tone="primary" onClick={() => act("store", "install", e.id)} />
        )}
      </div>
      {message && <div class="scr-note danger">{message}</div>}
      {!s.linux && e.needsLinux && <div class="scr-note muted">needs Linux: it runs commands in Arch, so it waits as a placeholder until you install Linux in settings</div>}
      <div class="scr-sub">installs packages: {e.requires || "none"}</div>
      {e.changed && <div class="scr-sub danger">its commands or packages changed since the version you approved</div>}
      <div class="scr-sub">{e.commands.length ? "runs these commands in Arch:" : "runs no commands"}</div>
      {e.commands.map((c, i) => (
        <pre key={i} class="scr-code">
          {c}
        </pre>
      ))}
    </Frame>
  );
}

function StoreScreen() {
  const s = useScreen<StoreState>("store");
  const [q, setQ] = useState("");
  const [tab, setTab] = useState(ALL);
  const [open, setOpen] = useState<string | null>(null);
  const page = s && open ? s.entries.find((e) => e.id === open) : null;
  if (s && page) return <WidgetPage s={s} e={page} onBack={() => setOpen(null)} />;
  const entries = s?.entries ?? [];
  const installed = entries.filter((e) => e.installed);
  const updates = installed.filter((e) => e.update).length;
  const tabs: [string, number][] = [[ALL, entries.length]];
  for (const c of s?.categories ?? []) {
    const n = entries.filter((e) => e.category === c).length;
    if (n) tabs.push([c, n]);
  }
  const others = entries.filter((e) => !e.category).length;
  if (others) tabs.push([OTHER, others]);
  if (installed.length) tabs.push([INSTALLED, installed.length]);
  const query = q.trim().toLowerCase();
  const shown = entries
    .filter((e) => (tab === ALL ? true : tab === INSTALLED ? !!e.installed : tab === OTHER ? !e.category : e.category === tab))
    .filter((e) => !query || [e.name, e.description, e.author, e.category ?? ""].some((t) => t.toLowerCase().includes(query)));
  return (
    <Frame icon="storefrontOutline" title="widget store" actions={<IconButton icon="refresh" label="refresh" onClick={() => act("store", "refresh")} />}>
      <Field value={q} onInput={setQ} placeholder={`search ${entries.length} widgets`} />
      <div class="scr-chips scroll">
        {tabs.map(([name, n]) => (
          <button type="button" key={name} class={`scr-chip ${tab === name ? "on" : ""}`} onClick={() => setTab(name)}>
            {name} {n}
            {name === INSTALLED && updates > 0 ? ` · ${updates}↑` : ""}
          </button>
        ))}
      </div>
      {s && tab === ALL && !query && (
        <Section icon="console" title="built in">
          <button type="button" class="scr-card tile scr-builtin" onClick={() => act("store", "terminal").then(() => closeScreen("store"))}>
            <div class="scr-row">
              <Icon name="console" size={22} class="scr-row-icon" />
              <div class="scr-row-text">
                <div>terminal</div>
                <div class="scr-sub muted">6x4 · a shell in ~ · add as many as you like; tap one to type</div>
              </div>
              <Icon name="plus" size={20} class="accent" />
            </div>
          </button>
          {s.builtIn.map((a) => (
            <button type="button" key={a.bin} class="scr-card tile scr-builtin" disabled={a.added} onClick={() => act("store", "agent", a.bin).then(() => closeScreen("store"))}>
              <div class="scr-row">
                <Icon name="robotOutline" size={22} class="scr-row-icon" />
                <div class="scr-row-text">
                  <div>{a.name}</div>
                  <div class="scr-sub muted">6x6 · runs {a.bin} in ~ · {a.description}</div>
                </div>
                {a.added ? <span class="scr-sub muted">on home</span> : <Icon name="plus" size={20} class="accent" />}
              </div>
            </button>
          ))}
        </Section>
      )}
      <div class="scr-note muted">reviewed widgets from github.com/{s?.repo ?? ""}</div>
      {!s || (s.loading && !entries.length) ? (
        <Loading />
      ) : s.error && !entries.length ? (
        <div class="scr-note danger">{s.error}</div>
      ) : !entries.length ? (
        <div class="scr-note muted">no widgets yet</div>
      ) : (
        !shown.length && <div class="scr-note muted">nothing matches "{q.trim()}"</div>
      )}
      <div class="scr-cards">
        {shown.map((e) => {
          const [status, tone] = widgetStatus(e, s!.linux);
          return (
            <button type="button" key={e.id} class="scr-card-pick tile" onClick={() => setOpen(e.id)}>
              {e.preview ? <img src={e.preview} alt="" loading="lazy" class="scr-widget" /> : <span class="scr-widget empty muted">{e.name}</span>}
              <span class="scr-card-name scr-ellipsis">{e.name}</span>
              <span class={`scr-sub ${tone} scr-ellipsis`}>{status}</span>
            </button>
          );
        })}
      </div>
    </Frame>
  );
}

// --- linux

function LinuxProgress({ s }: { s: LinuxScreenState }) {
  const l = s.linux;
  const failed = l.state === "failed";
  const current = l.stage ?? 0;
  return (
    <>
      <div class={`scr-big ${failed ? "danger" : ""}`}>{failed ? "setup stopped" : "setting up linux"}</div>
      <div class="scr-stages">
        {s.stages.map((label, i) => {
          // The agents stage is left out of [stages] without agents to install; it's the last either way.
          const status = i < current ? "done" : i > current ? "pending" : failed ? "failed" : "running";
          return (
            <div key={label} class={`scr-stage ${status}`}>
              <Icon name={status === "done" ? "check" : status === "failed" ? "alertCircleOutline" : status === "running" ? "refresh" : "minusCircleOutline"} size={18} />
              <div>
                <div>{label}</div>
                {i === current && l.step && <div class="scr-sub muted">{l.step}</div>}
                {i === current && l.progress != null && (
                  <div class="scr-bar">
                    <i style={{ width: `${Math.round(l.progress * 100)}%` }} />
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>
      {failed && <Action icon="refresh" label="try again" tone="primary" onClick={() => act("linux", "retry")} />}
      <JobLog job={{ state: failed ? "failed" : "working", action: "", log: l.log ?? [] }} lines={6} />
      {!failed && <div class="scr-note muted">You can close this; setup keeps going in the background.</div>}
    </>
  );
}

function LinuxOffer({ s }: { s: LinuxScreenState }) {
  const [picked, setPicked] = useState<string[]>(s.agents.length ? [s.agents[0].bin] : []);
  const toggle = (bin: string) => setPicked(picked.includes(bin) ? picked.filter((b) => b !== bin) : [...picked, bin]);
  return (
    <>
      <div class="scr-big">arch linux, optional</div>
      <div class="scr-text muted">
        {s.powos ? "PowOS's own Linux runs your PowOS apps already. This is a separate Arch inside the app: " : ""}
        Linux apps, terminal widgets, coding agents, pacman and Files. About 1 GB to download; installs in the background.
      </div>
      <Action icon="trayArrowDown" label={picked.length ? `install linux and ${plural(picked.length, "agent")}` : "install linux"} tone="primary" onClick={() => act("linux", "install", picked)} />
      <Section icon="robotOutline" title="coding agents to install with it">
        {s.agents.map((a) => (
          <button type="button" key={a.bin} class={`scr-card tile scr-pick ${picked.includes(a.bin) ? "on" : ""}`} onClick={() => toggle(a.bin)}>
            <div class="scr-row">
              <Icon name={picked.includes(a.bin) ? "checkCircleOutline" : "minusCircleOutline"} size={20} class="scr-row-icon" />
              <div class="scr-row-text">
                <div>{a.name}</div>
                <div class="scr-sub muted">{a.description}</div>
              </div>
            </div>
          </button>
        ))}
      </Section>
    </>
  );
}

function LinuxScreen() {
  const s = useScreen<LinuxScreenState>("linux");
  const [confirm, setConfirm] = useState(false);
  let body: ComponentChildren;
  switch (s?.linux.state) {
    case undefined:
    case "checking":
      body = <Loading />;
      break;
    case "none":
      body = <LinuxOffer s={s} />;
      break;
    case "installing":
    case "failed":
      body = <LinuxProgress s={s} />;
      break;
    case "removing":
      body = <div class="scr-note accent">removing linux…</div>;
      break;
    case "installed": {
      const gpu = s.gpu;
      const gpuJob = gpu?.job;
      body = (
        <>
          <div class="scr-card tile">
            <div class="scr-row">
              <Icon name="penguin" size={22} class="scr-row-icon" />
              <div class="scr-row-text">
                <div>arch linux</div>
                <div class="scr-sub muted">installed · {s.size != null ? size(s.size) : "measuring…"}</div>
              </div>
            </div>
          </div>
          {gpu && (
            <div class="scr-card tile">
              <div class="scr-row">
                <Icon name="chip" size={22} class="scr-row-icon" />
                <div class="scr-row-text">
                  <div>gpu acceleration</div>
                  <div class={`scr-sub ${gpu.active ? "green" : "muted"}`}>
                    {gpuJob?.state === "working"
                      ? `${gpuJob.action}…`
                      : gpu.active
                        ? `on · ${gpu.device ?? "GPU"} · for apps opened from now on`
                        : gpu.wanted && gpuJob?.state === "failed"
                          ? "off: the GPU failed its check after a system update"
                          : gpu.wanted
                            ? "on · waiting for its check"
                            : gpuJob?.state === "failed"
                              ? "the GPU failed its check; apps stay in software"
                              : "experimental · faster OpenGL and Vulkan apps and games; terminal apps don't change"}
                  </div>
                </div>
                {gpuJob?.state !== "working" &&
                  (gpu.wanted ? (
                    <>
                      {gpuJob?.state === "failed" && <IconButton icon="refresh" label="retry" onClick={() => act("linux", "gpu", true)} />}
                      <Action icon="close" label="turn off" tone="danger" onClick={() => act("linux", "gpu", false)} />
                    </>
                  ) : (
                    <Action icon="play" label="turn on" onClick={() => act("linux", "gpu", true)} />
                  ))}
              </div>
              <JobLog job={gpuJob ?? null} />
            </div>
          )}
          <Action icon="deleteOutline" label="remove linux" tone="danger" onClick={() => setConfirm(true)} />
        </>
      );
      break;
    }
  }
  return (
    <Frame icon="penguin" title="linux">
      {body}
      {confirm && (
        <Confirm
          title="remove linux?"
          text="Deletes Linux apps, coding agents, packages and everything in /root, like Downloads. Themes, wallpapers, widgets and your home screen stay."
          yes="remove"
          icon="deleteOutline"
          danger
          onNo={() => setConfirm(false)}
          onYes={() => {
            setConfirm(false);
            act("linux", "remove");
          }}
        />
      )}
    </Frame>
  );
}

// --- coding agents

function AgentRow({ a, isDefault }: { a: CodingAgent; isDefault: boolean }) {
  const working = a.job?.state === "working";
  return (
    <div class="scr-card tile">
      <div class="scr-row">
        <Icon name="robotOutline" size={22} class="scr-row-icon" />
        <div class="scr-row-text">
          <div>
            {a.name}
            {isDefault && <span class="accent"> · default</span>}
          </div>
          <div class="scr-sub muted">{a.description}</div>
        </div>
        {working ? (
          <span class="accent scr-sub">{(a.job as { action: string }).action}…</span>
        ) : a.installed ? (
          <>
            <IconButton icon={isDefault ? "star" : "starOutline"} label="make default" onClick={() => act("coding", "choose", a.bin)} />
            <IconButton icon="deleteOutline" label="remove" tone="danger" onClick={() => act("coding", "remove", a.bin)} />
            <Action
              icon="play"
              label="open"
              tone="primary"
              onClick={() => {
                act("coding", "open", a.bin);
                closeScreen("coding");
              }}
            />
          </>
        ) : (
          <Action icon="trayArrowDown" label="install" onClick={() => act("coding", "install", a.bin)} />
        )}
      </div>
      <JobLog job={a.job} />
    </div>
  );
}

/** For a screen that needs Linux, without it: what it needs, and the way there. */
function NeedsLinux({ l }: { l: LinuxStatus }) {
  return (
    <div class="scr-card tile">
      <div class="scr-row">
        <Icon name="penguin" size={22} class="scr-row-icon" />
        <div class="scr-row-text scr-sub">this needs Linux (the app's Arch): {linuxLine(l, false)}</div>
        <Action icon="chevronRight" label="linux" onClick={() => openScreen("linux")} />
      </div>
    </div>
  );
}

function CodingScreen() {
  const s = useScreen<CodingState>("coding");
  return (
    <Frame icon="robotOutline" title="coding agents">
      <div class="scr-note muted">Installed with mise, like Omarchy. Logins open in your browser; paste keys with the keyboard's clipboard.</div>
      {!s ? <Loading /> : s.linux.state !== "installed" && <NeedsLinux l={s.linux} />}
      {s?.agents.map((a) => (
        <AgentRow key={a.bin} a={a} isDefault={s.default === a.bin} />
      ))}
    </Frame>
  );
}

// --- packages

function PackagesScreen() {
  const s = useScreen<PackagesState>("aur");
  const [q, setQ] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const query = q ?? s?.query ?? "";
  const list = s?.packages ?? [];
  const status = !s || s.searching ? (query.trim() ? "searching…" : "loading…") : !query.trim() ? `installed (${list.length})` : !list.length ? "no packages match" : plural(list.length, "result");
  return (
    <Frame icon="packageVariant" title="packages">
      <Field
        value={query}
        onInput={(v) => {
          setQ(v);
          act("aur", "query", v);
        }}
        placeholder="search packages"
      />
      <div class="scr-note muted">
        Arch Linux ARM packages via pacman, and the AUR via yay. Installing also updates the system, so it can take a while. AUR packages are user-submitted and built on the device: check
        their PKGBUILD on aur.archlinux.org first.
      </div>
      {s && s.linux.state !== "installed" && <NeedsLinux l={s.linux} />}
      <div class="scr-note muted">{status}</div>
      {list.map((p) => {
        const working = p.job?.state === "working";
        return (
          <div key={`${p.repo}/${p.name}`} class="scr-card tile">
            <div class="scr-row">
              <Icon name="packageVariant" size={20} class="scr-row-icon" />
              <div class="scr-row-text">
                <div>
                  {p.name} <span class="scr-sub muted">{[p.repo, p.version].filter(Boolean).join(" ")}</span>
                </div>
                {p.description && <div class="scr-sub muted scr-clamp">{p.description}</div>}
              </div>
              {working ? (
                <span class="accent scr-sub">{(p.job as { action: string }).action}…</span>
              ) : p.installed && p.core ? (
                <span class="muted scr-sub">required</span>
              ) : p.installed && confirming === p.name ? (
                <Action
                  icon="deleteOutline"
                  label="confirm"
                  tone="danger"
                  onClick={() => {
                    setConfirming(null);
                    act("aur", "remove", p.name);
                  }}
                />
              ) : p.installed ? (
                <IconButton icon="deleteOutline" label="remove (it also removes dependencies nothing else uses)" tone="danger" onClick={() => setConfirming(p.name)} />
              ) : (
                <Action icon="trayArrowDown" label="install" onClick={() => act("aur", "install", p.name)} />
              )}
            </div>
            <JobLog job={p.job} />
          </div>
        );
      })}
    </Frame>
  );
}

// --- licenses

function License({ c }: { c: LicensesState["components"][number] }) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState<string | null>(null);
  useEffect(() => {
    if (open && text == null && c.license !== "public-domain") act("licenses", "text", c.license).then((t) => setText((t as string) ?? ""));
  }, [open]);
  return (
    <div class="scr-card tile">
      <button type="button" class="scr-row" onClick={() => setOpen(!open)}>
        <Icon name="scaleBalance" size={20} class="scr-row-icon" />
        <div class="scr-row-text">
          <div>{c.name}</div>
          <div class="scr-sub muted">
            {c.license} · {c.use}
          </div>
        </div>
        <Icon name={open ? "chevronLeft" : "chevronRight"} size={20} class={`accent ${open ? "scr-rot" : ""}`} />
      </button>
      {open && (
        <div class="scr-license">
          <div class="scr-sub">{c.notice}</div>
          <div class="scr-row">
            <Action icon="openInNew" label="website" onClick={() => act("licenses", "open", c.url)} />
            {c.source && <Action icon="github" label="source code" onClick={() => act("licenses", "open", c.source)} />}
          </div>
          {text && <pre class="scr-code muted">{text}</pre>}
        </div>
      )}
    </div>
  );
}

function LicensesScreen() {
  const s = useScreen<LicensesState>("licenses");
  return (
    <Frame icon="scaleBalance" title="licenses">
      {!s ? (
        <Loading />
      ) : (
        <>
          <div class="scr-note muted">PowOS {s.version}, built on Omalauncher (© 2026 Simon Schubert). It includes the open source software below.</div>
          {s.components.map((c) => (
            <License key={c.name} c={c} />
          ))}
        </>
      )}
    </Frame>
  );
}

// --- gestures: edge gestures (EdgeGestures.kt reads what this keeps: the store's edgeGestures, EdgeConfig.kt's shape)

type EdgeSide = { on: boolean; top: number; bottom: number; width: number; actions: Record<string, string> };
type EdgeSettings = { on: boolean; handles: boolean; sensitivity: "low" | "normal" | "high"; left: EdgeSide; right: EdgeSide };

const EDGE_KEYS = ["short.straight", "short.up", "short.down", "long.straight", "long.up", "long.down"] as const;
const EDGE_GESTURES: Record<(typeof EDGE_KEYS)[number], [string, IconName]> = {
  "short.straight": ["swipe in", "arrowLeft"],
  "short.up": ["swipe in and up", "arrowUp"],
  "short.down": ["swipe in and down", "arrowDown"],
  "long.straight": ["swipe in and hold", "arrowLeft"],
  "long.up": ["in and up, hold", "arrowUp"],
  "long.down": ["in and down, hold", "arrowDown"],
};
/** The actions, as EdgeGestures.kt runs them; "app:<package>" opens that app. */
const EDGE_ACTIONS: [string, string][] = [
  ["quicktools", "quick tools"],
  ["back", "back"],
  ["home", "home"],
  ["recents", "recent apps"],
  ["previous", "previous app"],
  ["notifications", "notifications"],
  ["control", "control center"],
  ["assistant", "assistant"],
  ["drawer", "app drawer"],
  ["playpause", "play / pause"],
  ["app", "an app"],
  ["none", "nothing"],
];
// The defaults EdgeConfig.kt has: the right edge on (in and up: Quick Tools, straight in still Back), the left off.
const EDGE_DEFAULTS: EdgeSettings = {
  on: true,
  handles: true,
  sensitivity: "normal",
  right: {
    on: true,
    top: 0.5,
    bottom: 1,
    width: 18,
    actions: { "short.straight": "back", "short.up": "quicktools", "short.down": "notifications", "long.straight": "previous", "long.up": "quicktools", "long.down": "control" },
  },
  left: {
    on: false,
    top: 0.5,
    bottom: 1,
    width: 18,
    actions: { "short.straight": "back", "short.up": "back", "short.down": "back", "long.straight": "previous", "long.up": "home", "long.down": "recents" },
  },
};
const EDGE_SPANS: [string, number][] = [
  ["lower third", 0.67],
  ["lower half", 0.5],
  ["lower ⅔", 0.33],
  ["whole edge", 0.08],
];
const EDGE_WIDTHS: [string, number][] = [
  ["thin", 12],
  ["normal", 18],
  ["wide", 28],
];

function edgeMerged(saved: Partial<EdgeSettings> | null): EdgeSettings {
  const side = (d: EdgeSide, s?: Partial<EdgeSide>): EdgeSide => ({ ...d, ...s, actions: { ...d.actions, ...s?.actions } });
  return { ...EDGE_DEFAULTS, ...saved, left: side(EDGE_DEFAULTS.left, saved?.left), right: side(EDGE_DEFAULTS.right, saved?.right) };
}

function edgeActionLabel(a: string) {
  if (a.startsWith("app:")) {
    const pkg = a.slice(4);
    return apps.value.find((x) => x.kind === "android" && x.key.slice(2).split("/")[0] === pkg)?.label ?? pkg;
  }
  return EDGE_ACTIONS.find(([k]) => k === a)?.[1] ?? a;
}

function EdgeSideSection({ name, s, set }: { name: "left" | "right"; s: EdgeSide; set: (s: EdgeSide) => void }) {
  const [open, setOpen] = useState<string | null>(null);
  const [picking, setPicking] = useState<string | null>(null);
  const span = EDGE_SPANS.reduce((best, x) => (Math.abs(x[1] - s.top) < Math.abs(best[1] - s.top) ? x : best));
  const width = EDGE_WIDTHS.reduce((best, x) => (Math.abs(x[1] - s.width) < Math.abs(best[1] - s.width) ? x : best));
  const androidApps = apps.value.filter((a) => a.kind === "android" && !a.work && !a.clone);
  return (
    <Section icon={name === "right" ? "arrowLeft" : "arrowRight"} title={`${name} edge`}>
      <Option label="handle">
        <Segmented options={["on", "off"]} picked={s.on ? 0 : 1} onPick={(i) => set({ ...s, on: i === 0 })} />
      </Option>
      {s.on && (
        <>
          <Option label="where">
            <span class="scr-chips">
              {EDGE_SPANS.map(([label, top]) => (
                <button type="button" key={label} class={`scr-chip ${span[0] === label ? "on" : ""}`} onClick={() => set({ ...s, top, bottom: 1 })}>
                  {label}
                </button>
              ))}
            </span>
          </Option>
          <Option label="width">
            <Segmented options={EDGE_WIDTHS.map(([l]) => l)} picked={EDGE_WIDTHS.indexOf(width)} onPick={(i) => set({ ...s, width: EDGE_WIDTHS[i][1] })} />
          </Option>
          {EDGE_KEYS.map((k) => {
            const [label, icon] = EDGE_GESTURES[k];
            const action = s.actions[k] ?? "none";
            return (
              <div key={k} class="scr-edge-gesture">
                <button type="button" class="scr-row" data-setting={label} onClick={() => (setOpen(open === k ? null : k), setPicking(null))}>
                  <Icon name={icon} size={18} class={`scr-row-icon ${name === "left" && icon === "arrowLeft" ? "flip" : ""}`} />
                  <span class="scr-row-text">{label}</span>
                  <span class="scr-edge-action">{edgeActionLabel(action)}</span>
                </button>
                {open === k && (
                  <span class="scr-chips scr-edge-picks">
                    {EDGE_ACTIONS.map(([a, l]) => (
                      <button
                        type="button"
                        key={a}
                        class={`scr-chip ${(a === "app" ? action.startsWith("app:") : action === a) ? "on" : ""}`}
                        onClick={() => {
                          if (a === "app") return setPicking(k);
                          set({ ...s, actions: { ...s.actions, [k]: a } });
                          setOpen(null);
                        }}
                      >
                        {l}
                      </button>
                    ))}
                  </span>
                )}
                {open === k && picking === k && (
                  <span class="scr-chips scr-edge-picks">
                    {androidApps.map((app) => {
                      const pkg = app.key.slice(2).split("/")[0];
                      return (
                        <button
                          type="button"
                          key={app.key}
                          class={`scr-chip ${action === `app:${pkg}` ? "on" : ""}`}
                          onClick={() => {
                            set({ ...s, actions: { ...s.actions, [k]: `app:${pkg}` } });
                            setOpen(null);
                            setPicking(null);
                          }}
                        >
                          {app.label}
                        </button>
                      );
                    })}
                  </span>
                )}
              </div>
            );
          })}
        </>
      )}
    </Section>
  );
}

function GesturesScreen() {
  const [c, setC] = useState<EdgeSettings | null>(null);
  useEffect(() => {
    powos.store.get<Partial<EdgeSettings>>("edgeGestures").then(
      (saved) => setC(edgeMerged(saved)),
      () => setC(edgeMerged(null)),
    );
  }, []);
  if (!c) return <Frame icon="arrowLeft" title="gestures"><Loading /></Frame>;
  const save = (next: EdgeSettings) => {
    setC(next);
    powos.store.set("edgeGestures", next);
  };
  return (
    <Frame icon="arrowLeft" title="gestures">
      <Section icon="arrowLeft" title="edge gestures">
        <div class="scr-note muted">Swipe in from a handle on the screen's edge: a short swipe, or one held still at its end, straight in or diagonally up or down. Above the handles the edges stay Android's back swipe.</div>
        <Option label="edge gestures">
          <Segmented options={["on", "off"]} picked={c.on ? 0 : 1} onPick={(i) => save({ ...c, on: i === 0 })} />
        </Option>
        {c.on && (
          <>
            <Option label="show handles">
              <Segmented options={["on", "off"]} picked={c.handles ? 0 : 1} onPick={(i) => save({ ...c, handles: i === 0 })} />
            </Option>
            <Option label="sensitivity">
              <Segmented options={["low", "normal", "high"]} picked={["low", "normal", "high"].indexOf(c.sensitivity)} onPick={(i) => save({ ...c, sensitivity: (["low", "normal", "high"] as const)[i] })} />
            </Option>
          </>
        )}
      </Section>
      {c.on && (
        <>
          <EdgeSideSection name="right" s={c.right} set={(right) => save({ ...c, right })} />
          <EdgeSideSection name="left" s={c.left} set={(left) => save({ ...c, left })} />
        </>
      )}
    </Frame>
  );
}

const SCREENS: Record<ScreenName, FunctionComponent> = {
  settings: SettingsScreen,
  style: StyleScreen,
  themes: ThemesScreen,
  store: StoreScreen,
  linux: LinuxScreen,
  coding: CodingScreen,
  aur: PackagesScreen,
  licenses: LicensesScreen,
  gestures: GesturesScreen,
};

/** The top screen, over home; those under it wait (unwatched) until it closes. */
export function Screens() {
  const top = screens.value[screens.value.length - 1];
  if (!top) return null;
  const Screen = SCREENS[top];
  return <Screen key={top} />;
}
