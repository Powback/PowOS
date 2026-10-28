/**
 * The host API: the one contract between the shell (this folder) and the native side - the phone's launcher (an
 * Android WebView, ShellBridge.kt) or PowOS's desktop host. Calls are async; events come through `on`. A browser
 * without a host gets bridge.ts's mock, so the shell runs anywhere.
 */
/** apps.links: an Android app's deep links (a prefix or pattern path ends in ".*"), with the activity each opens. */
export interface AppLinks {
  pkg: string;
  label: string;
  links: { uri: string; activity?: string }[];
  /** The home-screen widgets it declares (AppWidgetProviders); absent from an older APK. Sizes in dp, targetCell* in grid cells. */
  widgets?: AppWidget[];
}

export interface AppWidget {
  provider: string;
  label: string;
  minWidth: number;
  minHeight: number;
  minResizeWidth?: number;
  minResizeHeight?: number;
  targetCellWidth?: number;
  targetCellHeight?: number;
  resize: ("horizontal" | "vertical")[];
  categories: string[];
  updatePeriodMs: number;
  preview: "image" | "layout" | "none";
  configure?: string;
}

export interface App {
  /** Stable id: "a:<package/activity[@profile]>" (Android), "l:<desktop id>" (Linux / PowOS), "p:<app id>" (a PowOS app). */
  key: string;
  label: string;
  /** URL of its icon (the host serves them). */
  icon: string;
  kind: "android" | "linux" | "powos";
  /** A work-profile app, a clone, or the system's own (not uninstallable). */
  work?: boolean;
  clone?: boolean;
  system?: boolean;
  /** Android: ApplicationInfo.category (0 game ... 8 accessibility), when the app says one (the app library's folders). */
  category?: number | null;
  /** Linux: its .desktop Categories ("Network;WebBrowser;"). */
  categories?: string | null;
}

/** CSS px; [keyboard] is the soft keyboard's height (0 while it's down). */
export interface Insets {
  top: number;
  bottom: number;
  left: number;
  right: number;
  keyboard: number;
}

export interface Cell {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Something on a home page: a widget, a pinned app or a folder of them. */
export interface HomeItem {
  key: string;
  kind: "widget" | "app" | "folder" | "appwidget" | "panel";
  page: number;
  /** Its place on the page's grid; null until placed. */
  cell: Cell | null;
  resizable: boolean;
  minSize: [number, number];
  size: [number, number] | null;
  /** widget; panel: which of the shell's own (ui/agents.tsx's "agents") */
  name?: string;
  error?: string;
  /** app: its label and the drawer's key for it */
  label?: string;
  app?: string;
  /** folder */
  apps?: { key: string; label: string; app: string }[];
  /** appwidget: another app's Android widget (its [name] is the widget's label) */
  appWidget?: AppWidgetRef;
  /** A placeholder the shell drew at once while the real tile is on its way (e.g. "Adding..."); gone with home.changed. */
  pending?: string;
}

/**
 * What a hosted Android widget shows, as data ("appwidgets.data" while watchData is on): the rendered view tree
 * slimmed down. Bounds are [x, y, w, h] dp inside the widget. Roles are guesses by size/position.
 */
export interface AppWidgetTree {
  /** The widget's size, dp. */
  w: number;
  h: number;
  texts: { t: string; role: "title" | "value" | "label"; size: number; b: [number, number, number, number] }[];
  /** [ref]: a small cached picture, fetched once with appWidgets.image(ref). */
  images: { ref: string; b: [number, number, number, number]; d?: string }[];
  progress: { v: number; max: number; indeterminate: boolean; b: [number, number, number, number] }[];
  /** Each list's rows, each row its texts. */
  lists: { b: [number, number, number, number]; rows: string[][] }[];
  /** What a tap does something on: its centre goes to appWidgets.touch. */
  targets: { b: [number, number, number, number]; label: string }[];
}

/** The "appwidgets.data" event. */
export interface AppWidgetData {
  id: number;
  provider: string;
  /** Epoch ms of the read. */
  at: number;
  tree: AppWidgetTree;
}

/** An Android widget on home: the system's id for it, its provider (a component) and that provider's app. */
export interface AppWidgetRef {
  id: number;
  provider: string;
  package: string;
  /** It can be set up again after it's placed (its own settings screen). */
  reconfigurable: boolean;
  /** The smallest it may be made, dp (its provider's minimum resize size), and which sides of its tile move. */
  minDp: [number, number];
  resize: "both" | "horizontal" | "vertical";
}

/** A widget an Android app offers (the add-widget picker): sizes in dp, [preview] a picture of it (a URL). */
export interface AppWidgetProvider {
  /** Its component and profile ("package/class#serial"), what appWidgets.add takes. */
  provider: string;
  label: string;
  app: string;
  package: string;
  /** From the work profile. */
  work: boolean;
  description: string | null;
  /** The size a launcher would first give it, and the smallest it may be made. */
  sizeDp: [number, number];
  minDp: [number, number];
  /** It opens its own setup screen when added. */
  configure: boolean;
  preview: string;
}

export interface Home {
  columns: number;
  pages: number[];
  items: HomeItem[];
}

/** The quick settings that switch here: on or off, null where the phone can't (no flashlight, no access). */
export interface QuickState {
  torch: boolean | null;
  dnd: boolean | null;
  /** The control center's tiles, in the phone's own order. */
  tiles: QuickTile[];
  /** 0..1 (perceptual), and whether the phone sets it itself. */
  brightness: { value: number; auto: boolean };
  /** Media volume 0..1; the ringer: 0 silent, 1 vibrate, 2 ring. */
  volume: { value: number; ringer: number };
}

/** What's playing: nothing (playing false, no title) or a track. art: an id for /_media/<id>. */
export interface MediaState {
  available: boolean;
  playing: boolean;
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  app?: string;
  package?: string;
  position?: number | null;
  duration?: number | null;
  art?: string | null;
}

/** One control center tile: a switch (on true/false) or an action/page (on null). */
export interface QuickTile {
  id: string;
  label: string;
  on: boolean | null;
  /** A line under the label (the carrier). */
  detail: string | null;
  /** A third-party tile's app (custom(...) ids). */
  app?: string;
}

/** The screen the assistant was opened over. */
export interface AssistScreen {
  text: string;
  screenshot: string | null;
}

/** Something an agent told the user, unread (time: Unix seconds; id: comms' message id). */
export interface AgentMail {
  id?: string;
  from: string;
  text: string;
  time: number;
  priority?: string;
}
/** An agent at work: a tmux session in PowOS; [title] its pane's (Claude Code's: the task, a spinner while working). */
/**
 * The phone-check runner on the Mac (tools/phone/verify/queue.sh), as its heartbeat file on the phone says:
 * state waiting | paused | running | idle | stopped ("" when unknown); age: seconds since its last beat (-1: none yet).
 */
export interface VerifyState {
  state: string;
  age: number;
}

export interface AgentSession {
  name: string;
  activity: number;
  attached: boolean;
  title: string;
  path: string;
  command: string;
}

/** One entry of PowOS AI's chat; a tool's ok is null while it runs. */
export type ChatItem =
  | { kind: "user" | "assistant"; text: string }
  | { kind: "tool"; name: string; hint: string; ok: boolean | null; out?: string }
  | { kind: "note"; text: string; error: boolean };
/** A notification as the panel shows it; [icon] its app's drawer icon, [time] Unix seconds. */
export interface PhoneNotification {
  key: string;
  app: string;
  icon: string | null;
  title: string;
  text: string;
  time: number;
  clearable: boolean;
  profile: string | null;
  /** Its buttons in order (notifications.action's index); [input]: it takes a typed reply. */
  actions?: { title: string; input: boolean }[];
  /** Notification.category ("alarm", "call", "msg", ...): an alarm's or a call's banner stays up longer. */
  category?: string | null;
  /** Its app's package (an older host: none). */
  pkg?: string;
  /** Android's group key (the app's bundle; its summary is never listed itself), null when it's in none. */
  group?: string | null;
  /** A conversation (a messaging-style one): shown on its own, above the groups. */
  conversation?: boolean;
}
/**
 * A recent task, as the switcher (ui/recents.tsx) shows it: [id] the system's, [key] and [icon] its app's in the drawer (null when it
 * isn't there), [snapshot] its last frame (a new URL each listing).
 */
/** A floating app window on the unfolded home (system/WindowFrames.kt): its task, app, name, and whether it's minimised. */
export interface AppWindow {
  id: number;
  pkg: string;
  label: string;
  minimised: boolean;
  /** On a home page not on screen (ui/desktops.ts): out of sight until home shows that page. */
  away?: boolean;
  /** The shell's key of the PowOS (Linux) app it shows ("l:..."): its task is PowOS's own, so pkg says nothing. */
  app?: string;  /** Where it shows on the screen, device px [left, top, right, bottom]; absent while hidden or minimised. */
  bounds?: [number, number, number, number];
}

export interface RecentTask {
  id: number;
  label: string;
  key: string | null;
  icon: string | null;
  snapshot: string;
  /** Unfolded: it comes back as a floating window (its card grows to [window], or the host opens it out of the card). */
  floats?: boolean;
  /** A floating window already: where it is (CSS px of the page), where it comes back. */
  window?: { left: number; top: number; width: number; height: number };
}
/** [available]: the launcher may read them (it has notification access). */
/**
 * A window on the desktop (PowOS's desktop host: KWin's window list through libtaskmanager). [id] is the host's
 * (KWin's window uuid); [icon] a URL the host serves.
 */
export interface DesktopWindow {
  id: string;
  title: string;
  /** Its app id (the .desktop name: "org.kde.konsole"), "" when unknown. */
  app: string;
  appName: string;
  icon: string;
  active: boolean;
  minimized: boolean;
  /** An Android app's window (the phone's session: app id "android-<package>"). */
  android?: boolean;
  /** An Android app still on the phone's own screen: a stand-in - activating it moves the app into a window. */
  onPhone?: boolean;
}

export interface NotificationList {
  available: boolean;
  items: PhoneNotification[];
}

/** The colors in use: the launcher's palette as CSS (background, surface, foreground, muted, accent, border, red, ...), and the theme's own by name (color0-15, cursor, ...). */
export interface ThemeColors {
  name: string;
  light: boolean;
  css: Record<string, string>;
  colors: Record<string, string>;
}
/** The wallpaper as an image ([url] on the page's origin, [rev] new whenever it's another picture), or none. */
export interface GlassSource {
  wallpaper: { url: string; rev: string; source: string } | null;
  blurBehind: boolean;
}
/** A theme to pick: what its swatch shows (background, foreground, accent, red, yellow, green, magenta). */
export interface ThemeChoice {
  name: string;
  title: string;
  colors: Record<string, string>;
}

/** A widget's full-size screen, open over home ([key] null: none). A terminal's is edge to edge, without a title. */
export interface WidgetScreen {
  key: string | null;
  terminal?: boolean;
  title?: string;
}

export interface Chat {
  busy: boolean;
  items: ChatItem[];
  /** A thread of its own open instead of the main conversation (PowosAiChat.Thread): "create app"'s. */
  thread?: { dir: string; title: string; kind: string } | null;
  /**
   * Sent mid-turn, waiting for theirs, oldest first (PowosAiChat.queued): every chat shows them at once. Absent from a
   * host that doesn't queue (an older APK): the page queues itself (assistant.ts).
   */
  queued?: { id: number; text: string }[];
}

/** An app that runs, or one frozen (asleep in RAM: powos-sleep-gui, a game frozen with Steam). */
export type RunState = "running" | "frozen";

/** Visible system chrome is shared web UI; hosts supply state and perform scoped actions. */
export interface ChromeState {
  kind: "window" | "grip" | "status";
  clock?: string;
  notifications?: number | null;
  title?: string;
  icon?: string;
  maximised?: boolean;
  pressed?: string | null;
  battery?: number | null;
  charging?: boolean;
  network?: "wifi" | "cellular" | "ethernet" | "offline" | null;
  vpn?: boolean;
  left?: number;
  right?: number;
}
export interface ChromeRegion { action: string; x: number; y: number; width: number; height: number }

export interface Bridge {
  /** Perf traces (?: hosts from before it): saves JSON under the AI shared dir, returns its path in PowOS. */
  perf?: { save(json: string): Promise<string | null>; /** Main shell frame sample to the other windows (hosts from before it: absent). */ publish?(json: string): Promise<unknown> };
  chrome: {
    state(): Promise<ChromeState>;
    ready(): Promise<void>;
    action(action: string): Promise<void>;
    regions(regions: ChromeRegion[]): Promise<void>;
  };
  /** "android" | "powos" | "mock" */
  host: string;
  apps: {
    list(): Promise<App[]>;
    launch(key: string): Promise<void>;
    info(key: string): Promise<void>;
    uninstall(key: string): Promise<void>;
    /**
     * Which apps run, app key -> "running" | "frozen" (only those that do); "apps.running" carries it again on every
     * change. Android: an app with a task in recents; Linux, Steam and its games: a window, frozen by powos-sleep-gui.
     * Only where the host knows it.
     */
    running?(): Promise<Record<string, RunState>>;
    /**
     * An Android app's deep links (App API's "+ add app"): the URIs its exported VIEW/BROWSABLE intent filters open,
     * read from its manifest - nothing is fired. Android only; an older APK rejects it ("no such call").
     */
    links?(pkg: string): Promise<AppLinks>;
  };
  usage: {
    /** Keys, last opened first. */
    recent(limit: number): Promise<string[]>;
  };
  /** The shell's own data files (data/*.json), kept by the host. */
  store: {
    get<T = unknown>(name: string): Promise<T | null>;
    set(name: string, value: unknown): Promise<void>;
  };
  /** The home screen, shared with the Compose launcher while both exist. */
  home: {
    get(): Promise<Home>;
    /** Moves or resizes an item (to another page too). */
    place(key: string, cell: Cell, page: number): Promise<void>;
    /** Pins an app (a drawer key) to a page, at a cell if given; returns the item's key. */
    add(app: string, page: number, cell?: Cell): Promise<string>;
    remove(key: string): Promise<void>;
    /** Drops an app item on another app or a folder: into one folder. Returns the folder's key. */
    group(key: string, target: string): Promise<string | null>;
    /** Gives items without a cell (a store widget, an app pinned from a menu) the first free spot on a grid this big. */
    arrange(cols: number, rows: number): Promise<void>;
    /** Puts the shell's own panel [name] ("agents") on [page] at [cell]; returns its key ("panel:<name>"). */
    addPanel(name: string, page: number, cell: Cell): Promise<string>;
  };
  /**
   * OWL widgets: the host runs them; the page draws their trees, sent as "widget.tree" ({ key, screen, tree }) while
   * watched, and sends back events and sizes. [screen]: the widget's full-screen block instead of its tile.
   */
  widgets: {
    watch(key: string, screen?: boolean): Promise<void>;
    unwatch(key: string, screen?: boolean): Promise<void>;
    /** Runs a handler (onTap, onDrag, onChange) of element [id] with its numbers (x, y, dx, dy in dp). */
    fire(key: string, screen: boolean, id: string, name: string, args: number[]): Promise<void>;
    /** The tile's size: cells (cols, rows) and dp. */
    size(key: string, cols: number, rows: number, width: number, height: number): Promise<void>;
    /** A Canvas's size in dp: its drawing is evaluated at it. */
    canvas(key: string, id: string, width: number, height: number): Promise<void>;
    /** The home page on screen (a page number): widgets on it and beside it run their sources. */
    page(page: number): Promise<void>;
    /** A tap on the tile that no element took: the widget's own onTap (often screen(), opening it full size). */
    tap(key: string): Promise<void>;
    /** The widget screen open now; "widget.screen" brings each change. */
    screen(): Promise<WidgetScreen>;
    closeScreen(): Promise<void>;
  };
  /**
   * Other apps' Android widgets on home (items of kind "appwidget"): the host draws each off screen and sends its
   * frames ("appwidgets.frame" { id, url } while watched); the page sends touches back. Placed, moved and removed
   * through home like any item.
   */
  appWidgets: {
    providers(): Promise<AppWidgetProvider[]>;
    /**
     * Puts [provider]'s widget at [cell] on [page], [width] x [height] dp. "pending": Android asks the user first
     * (allow PowOS to create widgets, then the widget's setup) - "home.changed" brings it, "appwidgets.failed" says
     * it didn't happen.
     */
    add(
      provider: string,
      page: number,
      cell: Cell,
      width: number,
      height: number,
    ): Promise<"added" | "pending" | "failed">;
    /**
     * Shows widget [id] at [width] x [height] (its tile, CSS px): answers its latest frame's URL (if any) and whether
     * it has a list to scroll; "appwidgets.frame" ({ id, url, scrolls }) brings each next.
     */
    watch(id: number, width: number, height: number): Promise<{ url: string | null; scrolls: boolean } | null>;
    unwatch(id: number): Promise<void>;
    /**
     * Host-optional (f307: feature-detect `powos.appWidgets.watchData`). Turns widget [id]'s data mode on or off: while
     * on, "appwidgets.data" ({@link AppWidgetData}) comes after each update that changed what it shows (at most about
     * once a second); the widget is hosted without frames. Off for every widget until asked, so idle ones cost nothing.
     */
    watchData?(id: number, on: boolean): Promise<void>;
    /** Host-optional: the picture [ref] of an {@link AppWidgetTree} image, a small PNG data URL (null once forgotten). */
    image?(ref: string): Promise<string | null>;
    /** A touch on its tile at (x, y) of a tile [width] x [height] CSS px; "cancel": the page took the gesture. */
    touch(
      id: number,
      action: "down" | "move" | "up" | "cancel",
      x: number,
      y: number,
      width: number,
      height: number,
    ): Promise<void>;
    /** Its own setup screen again. */
    configure(id: number): Promise<void>;
  };
  /**
   * PowOS AI: the conversation with PowOS's manager, the one its own app (and the desktop's manager widget) shows.
   * "ai.changed" brings the whole chat ({ busy, items }) as a turn streams in.
   */
  ai: {
    chat(): Promise<Chat>;
    /** Asks it: one turn, streamed into the chat. [recents] false: not also put into the app switcher (that briefly shows the chat activity over home). */
    send(text: string, recents?: boolean): Promise<void>;
    /** Takes a queued message back before its turn: it's never sent (?: hosts from before the queue). */
    unqueue?(id: number): Promise<void>;
    /**
     * "Test now": the verify queue (tools/phone/verify/queue.sh, on the Mac) runs [task]'s queued phone checks at once
     * ("all": every queued one), not waiting for the phone to sit idle. ?: hosts from before it.
     */
    verifyGo?(task: string): Promise<void>;
    /**
     * Asks for the verify runner's state; it comes as "verify.state" (VerifyState). ?: hosts from before it (their
     * call rejects "no such call": the page then shows no "checks paused").
     */
    verifyState?(): Promise<void>;
    /**
     * Stops the phone checks: the runner kills the running one and pauses the queue (the test pill's x; verifyGo "all"
     * resumes). [dry]: nothing stopped - it only answers, so a page can tell this host has it (older ones reject "no
     * such call"). ?: hosts from before it.
     */
    verifyStop?(dry?: boolean): Promise<void>;
    /** Opens PowOS AI's own app. */
    open(): Promise<void>;
    /**
     * "Create app": a fresh thread in a new directory, building [description] as a PowOS app (`powos app new` /
     * `install`). False while a turn is under way (or PowOS isn't running).
     */
    newApp(description: string): Promise<boolean>;
    /** Back from a thread to the main conversation. False while a turn is under way. */
    closeThread(): Promise<boolean>;
    /** What agents told the user and is unread, newest first ("ai.mail" brings it again). */
    mail(): Promise<AgentMail[]>;
    /**
     * Marks one read ([mailRead]) or all ([mailClear]): read everywhere - its notification goes, and it's out of the
     * user's comms inbox.
     */
    mailRead(id: string): Promise<void>;
    mailClear(): Promise<void>;
    /** Asks for the agents at work (PowOS's tmux sessions); they come as "ai.sessions" (AgentSession[]). */
    sessions(): Promise<void>;
    /** Opens a terminal on one of them. */
    attach(name: string): Promise<void>;
  };
  /**
   * Terminals: a process on a pty, by an id the page picks (views naming one id share it). Bytes are base64 both ways.
   * Output comes as "term.data" ({ id, run, data, end }: [end] the offset after it in the run's output) and its end as
   * "term.exit" ({ id, run, code }); "term.style" says the style changed (the terminal font arrived).
   */
  term: {
    /**
     * Starts [id] unless it runs ([restart]: also if it ended), running [command] (null: PowOS's tmux picker, or a
     * login shell); [owner] is the widget it ends with. Answers its state, with what it wrote lately to start from.
     */
    open(
      id: string,
      owner: string | null,
      command: string | null,
      cols: number,
      rows: number,
      restart?: boolean,
    ): Promise<TermState>;
    write(id: string, data: string): Promise<void>;
    resize(id: string, cols: number, rows: number): Promise<void>;
    close(id: string): Promise<void>;
    /** How terminals look: the launcher's terminal font, at [points] (null: the terminal text size). */
    style(points: number | null): Promise<TermStyle>;
  };
  clipboard: {
    read(): Promise<string | null>;
    write(text: string): Promise<void>;
  };
  /**
   * Remote input (ui/remote.tsx): the phone as a keyboard and mouse for a computer, over its USB cable (HID functions
   * on the phone's USB gadget) or Bluetooth (the HID device profile). "remote.state" brings each change.
   */
  remote: {
    state(): Promise<RemoteState>;
    /** Where reports go (null: nowhere), turning that side on first. */
    target(target: RemoteTarget | null): Promise<RemoteState>;
    /** Turns a side off: USB, the gadget back as Android had it; Bluetooth, the keyboard unregistered. */
    off(side: RemoteTarget): Promise<RemoteState>;
    /** Android's "make visible" dialog, for a new computer to pair with the phone. */
    discoverable(): Promise<void>;
    connect(address: string): Promise<void>;
    disconnect(): Promise<void>;
    /** Keyboard reports in order, each [modifiers, ...usages held] (remote.ts). */
    keys(reports: number[][]): Promise<void>;
    /** A mouse report: buttons (1 left, 2 right, 4 middle), relative motion, wheel and horizontal wheel. */
    mouse(buttons: number, dx: number, dy: number, wheel?: number, pan?: number): Promise<void>;
  };
  /**
   * Smart glasses (Even Realities G2/G1: glasses/Glasses.kt, docs/GLASSES.md): the pair, its connection, its display,
   * input and microphone. "glasses.state" (GlassesState) on every change; "glasses.input" ({ input, side }: input
   * "click" | "double" | "up" | "down" | "enter" | "exit" | "headUp" | "headDown" ...); "glasses.transcript" ({ text,
   * final }: the G2's own speech recognition); "glasses.audio" ({ data: base64, codec, rate }, to a page that asked
   * with audio(true)); "glasses.message" ({ text, seconds }: `powos glasses show`, to the surface page).
   */
  glasses: {
    state(): Promise<GlassesState>;
    /** Android's companion pairing dialogs (one per arm). "started" | "unavailable". */
    pair(): Promise<"started" | "unavailable">;
    /** Forgets the pair (disconnects, drops the associations). */
    forget(): Promise<GlassesState>;
    /** Connects (and keeps reconnecting) the paired glasses. False: none paired. */
    connect(): Promise<boolean>;
    disconnect(): Promise<GlassesState>;
    /** The glasses' own text rendering (the G2's teleprompter, the G1's text screen). False: not ready. */
    showText(text: string): Promise<boolean>;
    /** A picture (data: URL or base64 PNG), scaled to the canvas and converted (4-bit greys / 1-bit). [dither]: G1. */
    showImage(image: string, dither?: boolean): Promise<boolean>;
    clear(): Promise<boolean>;
    mic(on: boolean): Promise<boolean>;
    /** This page wants "glasses.audio" events (many: only while it uses them). */
    audio(on: boolean): Promise<boolean>;
    /** This page is the glasses' screen (shell/glasses/surface.tsx): `powos glasses show` comes to it. */
    surface(on: boolean): Promise<boolean>;
    /** The glasses' screen loads its app again (another one picked: store "glasses"). */
    reload(): Promise<void>;
    /** An option's value; with [value], sets it. "g2Raster": pictures to the G2 over its unverified render channel. */
    option(name: string, value?: boolean): Promise<boolean>;
  };
  /**
   * Host-optional (f307: feature-detect `powos.health`): Health Connect, read-only - what the wearables' apps wrote there
   * (the health central, apps/health). Records are normalised; times are Unix ms; [source] is the package of the app that
   * wrote it. Rejects where Health Connect isn't on the phone or the permission is missing (ask with grant).
   */
  health?: {
    status(): Promise<HealthStatus>;
    /** Shows Health Connect's permission dialog over PowOS when a type is missing (once); answers the status after it. */
    grant(): Promise<HealthStatus>;
    /** Records of [types] (all when empty) that overlap [sinceMs, untilMs] (default now). */
    read(types: HealthType[], sinceMs: number, untilMs?: number): Promise<HealthRecord[]>;
    /** A changes token for [types]: what `changes` continues from. */
    token(types: HealthType[]): Promise<{ token: string }>;
    /**
     * Only what changed since [token]: new and updated records, ids of deleted ones, and the next token. [expired]: the
     * token was too old (Health Connect keeps about 30 days) - read since the last sample instead; the token is fresh.
     */
    changes(types: HealthType[], token: string): Promise<{ token: string; records: HealthRecord[]; deleted: string[]; expired: boolean }>;
  };
  /** The phone's notifications, for the launcher's own panel; "notifications.changed" brings the list again. */
  notifications: {
    list(): Promise<NotificationList>;
    open(key: string): Promise<void>;
    dismiss(key: string): Promise<void>;
    clearAll(): Promise<void>;
    /** Opens the setting that grants the launcher notification access. */
    access(): Promise<void>;
    /** Presses [key]'s action [index]; [text] is the reply typed into it when it takes one. */
    action(key: string, index: number, text?: string): Promise<void>;
  };
  /**
   * The assistant's screen (index.html?mode=assist, over another app): what that app's screen showed - its text, an
   * outline, and a screenshot URL ("assist.context" brings them as they arrive) - and closing the assistant.
   * "assist.reset" comes with each summoning (the page starts dictating then), "assist.hidden" when it goes away,
   * "assist.held" right after it when the side button is still down (hold to talk: a hold's dictation), then
   * "assist.keyup" when it's let go; "assist.quick" instead when it was already up (the dictation ends at a short pause).
   */
  assist: {
    screen(): Promise<AssistScreen | null>;
    close(): Promise<void>;
    /** Saves an image for PowOS AI to look at (a cut-out region as a data: URL, or null: the whole screen); its path. */
    attach(image: string | null): Promise<string | null>;
    /** Live mode: the screen a frame a second (Android asks for consent); "assist.live" brings its state. */
    live(on: boolean): Promise<void>;
    liveState(): Promise<{ on: boolean; frames: number }>;
    /** The last moments that changed, tiled into one image where PowOS sees it; its path (null: nothing yet). */
    filmstrip(): Promise<string | null>;
    /** Where the page takes touches (live mode: its bar, CSS px); null: everywhere. */
    touchable(rect: { left: number; top: number; width: number; height: number } | null): Promise<void>;
  };
  /** The lock screen's face (index.html?mode=lock): unlocking is Android's (its PIN pad, the fingerprint). */
  lock: {
    unlock(): Promise<void>;
  };
  /**
   * The control center (and the notification panel's row): every tile the phone's own control center has, switched
   * here, and its sliders. "qs.changed" brings the state again.
   */
  /** The touch controller overlay (GamepadOverlay), for the control centre's Controller tile. */
  pad: {
    /** Whether the overlay is on (live, else what was saved for the next start). */
    state(): Promise<boolean>;
    /** Shows or hides it; resolves to the new state. Rejects where the phone has no overlay. */
    overlay(on: boolean): Promise<boolean>;
    /** Opens its layout editor. False: no game session up to edit on. */
    edit(): Promise<boolean>;
  };
  /** What's playing ("media.changed" brings it again once asked): the control center's media card. */
  media: {
    state(): Promise<MediaState>;
    control(command: "toggle" | "play" | "pause" | "next" | "previous" | "open"): Promise<void>;
    /** The phone's output picker (speaker, Bluetooth, cast) for that app's audio. */
    output(pkg?: string): Promise<void>;
  };
  qs: {
    /** Resolvable native settings pages; absent on older hosts. */
    destinations?(): Promise<{ id: string; label: string; keywords: string }[]>;
    state(): Promise<QuickState>;
    /** A tile tapped: a switch flipped, an action run (screenshot, lock), a page opened. */
    toggle(name: string): Promise<QuickState>;
    /** Android's own page for a tile (its long press), or wifi / bluetooth / internet / settings. */
    open(name: string): Promise<void>;
    /** A slider: "brightness" / "volume" 0..1, "auto-brightness" 0/1, "ringer" 0..1 (silent, vibrate, ring). */
    set(name: "brightness" | "volume" | "auto-brightness" | "ringer", value: number): Promise<QuickState>;
    /** The control center shown (true) or shut: other apps' tiles keep their state current while it shows. */
    listening(on: boolean): Promise<void>;
  };
  /**
   * The shade (index.html?mode=shade, in PowOS's system window above the status bar - the native shade host): the
   * host drives the pull ("shade.drag" { q: 0..1 } while the finger is on the top edge, "shade.settle" { open }), and
   * hears when the page closed it. Heads-up banners show here too: "shade.peek" (a PhoneNotification, or null: it's
   * gone) with the window a strip at the top as tall as [peekHeight] says; [expand] makes it the whole shade, open.
   */
  /**
   * The open shell panel (the launcher drawer "apps", PowOS AI's "ai"), told to the host so the bottom-edge home gesture
   * closes it (events "panel.close.begin" / ".drag" { p } / ".end" { shut }). Optional: an older host lacks it.
   */
  panels?: { open(kind: "apps" | "ai"): Promise<void>; closed(): Promise<void> };
  shade: {
    closed(): Promise<void>;
    expand(): Promise<void>;
    /** The banner's bottom edge, CSS px from the top of the window. */
    peekHeight(px: number): Promise<void>;
    /**
     * How strongly what's behind the shade's window is blurred when it's open: the compositor's radius at full openness,
     * dp (0..600; default 140). The compositor's blur is only a fraction of its radius - text needs a lot.
     */
    blur(dp: number): Promise<void>;
    /**
     * The panel's openness (0..1) as the page renders it this frame: the host blurs what's behind by it on the window's
     * draw that carries the frame - the blur in the same frame as the panel, both ways (a pull, the page's own swipe
     * shut, a settle). Optional: an older host drives the blur from its own pull.
     */
    behind?(q: number): Promise<void>;
    /**
     * Home's page: a pull down on home is the shade's now ([on]: nothing open over home's pages). Resolves true when the
     * host takes that finger itself (its gesture input), false when it can't - then home asks [open] on a swipe down.
     */
    homePull(on: boolean, exclude?: { left: number; top: number; width: number; height: number }, mainPage?: boolean): Promise<boolean>;
    /** The shade down, not following a finger (home without the host's gesture input). */
    open(): Promise<void>;
  };
  /**
   * An overlay window's page over any app (OverlayHost.kt): Quick Tools (mode=quicktools: "qt.drag" { side, y, q },
   * "qt.settle" { open }). [closed]: the page is shut, the window can go.
   */
  overlay: {
    closed(): Promise<void>;
  };
  /**
   * The pull-up panels over apps (mode=pull: "pull.begin" { kind }, "pull.drag" { p }, "pull.end" { open },
   * "pull.hide"). [closed]: shut and settled; [launched]: an app was opened from it, the window goes at once.
   */
  pull: {
    closed(): Promise<void>;
    launched(): Promise<void>;
  };
  /**
   * The desktop's windows (PowOS's desktop host only; the phone rejects these): every window, ungrouped, in the
   * taskbar's order; "windows.changed" (DesktopWindow[]) brings the whole list again on any change.
   */
  windows: {
    list(): Promise<DesktopWindow[]>;
    /** Raises and focuses it (a minimized one comes back); false: no such window. */
    activate(id: string): Promise<boolean>;
    /** Minimizes it, or brings a minimized one back. */
    minimize(id: string): Promise<boolean>;
    /** Asks it to close (the app may ask to save first); false: no such window. */
    close(id: string): Promise<boolean>;
  };
  /**
   * The desktop panel's own surface (index.html?mode=panel, a layer surface along the screen's bottom edge): [px]
   * tall while something opens above the bar (the launcher), the bar alone again with 0. The space kept free of
   * maximized windows stays the bar's.
   */
  panel: {
    height(px: number): Promise<void>;
  };
  /** Android's recent tasks (the host is the recents provider): newest first; switching to one; removing one. */
  tasks: {
    list(): Promise<RecentTask[]>;
    /**
     * Brings the task back: growing out of [from] (its card, CSS px), or "instant" (the page grew the card to the
     * screen itself); false if it's gone.
     */
    open(id: number, from?: { left: number; top: number; width: number; height: number } | "instant"): Promise<boolean>;
    remove(id: number): Promise<boolean>;
    /** Two tasks side by side (WM Shell's split screen): [first] left / top. */
    split(first: number, second: number): Promise<boolean>;
    /** The task in a floating window (freeform). */
    float(id: number): Promise<boolean>;
    /** Host-optional (f307: feature-detect): the task in a PowOS desktop window ([on], AppWindows' size/placement) or full screen. */
    desktopWindow?(id: number, on?: boolean): Promise<boolean>;
    /** Its app's info screen. */
    info(id: number): Promise<boolean>;
    /** Its last frame saved to Pictures/Screenshots: the file's name, or null. */
    screenshot(id: number): Promise<string | null>;
  };
  /**
   * The floating app windows (unfolded home), top-most first, for the dock; "windows.changed" (AppWindow[]) after.
   * The phone's only (wire calls "windows.list" / "windows.restore"): not `windows`, which is the desktop's taskbar.
   */
  floating?: {
    list(): Promise<AppWindow[]>;
    /** Brings it back (minimised, or under others) on top; false if it's gone. "windows.raised" (its id) after. */
    restore(id: number): Promise<boolean>;
    /** Home's pages as desktops (ui/desktops.ts): [hide] are the other pages' windows, out of sight; the rest back. */
    desktop(hide: number[]): Promise<boolean>;
    /** Off the screen into the dock, as its minimise button does (the dock's tap on the focused window's app). */
    minimise?(id: number): Promise<boolean>;
    /** Over the windows' whole area, or back where it was (its title bar's maximise button). */
    maximise?(id: number): Promise<boolean>;
    /** Where home's bottom bar starts (CSS px from the top): windows open and maximise above it, never over it. */
    area?(barTop: number): Promise<boolean>;
    /**
     * A page swipe moving the windows of the pages it shows (ui/desktops.ts, the host's PageSlide), CSS px: "start"
     * { rels: task id -> page offset -1/0/1, width, x } (false: nothing slides), "move" x (the track's offset from the
     * page it started on), "settle" { to, ms, curve: cubic-bezier, hide } (the track's own transition; [hide] is the
     * desktop change, committed when it lands), "cancel".
     */
    slide?(op: "start" | "move" | "settle" | "cancel", data?: unknown): Promise<boolean>;
  };
  /**
   * The switcher, a layer of home (ui/recents.tsx). The host drives it: "recents.begin" ({ from, tasks }: a swipe up
   * over task [from] began, its window following the finger), "recents.drag" ({ progress 0..1, x, y }: every frame of
   * it, CSS px), "recents.end" ({ to: "switcher" | "home" | "app", snapshot }), "recents.show" ({ open, from, tasks }:
   * up without a swipe), "recents.hide" (home went away), "recents.tasks" ({ tasks }: the list for next time, laid out
   * ahead), "switcher.toggle" (the overview button again).
   */
  recents: {
    /** Where the first card's frame is (CSS px, its corner radius): a swiped-up window lands there. */
    slot(rect: { left: number; top: number; width: number; height: number; radius: number }): Promise<void>;
    /** After "recents.end" to the switcher: the first card shows the app's snapshot, its window may go. */
    ready(): Promise<void>;
    /** The page closed it (a tap beside the cards, Back, Home). */
    closed(): Promise<void>;
    /** Whether it's up, over what, with the tasks (a page that just loaded). */
    state(): Promise<{ open: boolean; from: number | null; tasks: RecentTask[] }>;
  };
  /** The theme: the colors in use ("theme.changed" brings them again), the ones to pick from, picking one. */
  theme: {
    get(): Promise<ThemeColors>;
    list(): Promise<ThemeChoice[]>;
    pick(name: string): Promise<void>;
  };
  /**
   * Settings and the screens it opens (screens.ts, ShellScreens.kt): one's state now, then again as "screens.state"
   * ({ name, state }) on every change until unwatch; and what's tapped there (the host answers with what it returns).
   * The host opens one itself as "screens.open" ({ name }), and says a store install is done as "screens.done".
   */
  screens: {
    watch(name: string): Promise<unknown>;
    unwatch(name: string): Promise<void>;
    act(name: string, action: string, arg?: unknown): Promise<unknown>;
  };
  /** The default coding agent: its name, and the home menu's tasks for it (or the screen that sets one up). */
  agents: {
    default(): Promise<string | null>;
    newWidget(): Promise<"started" | "linux" | "agents">;
    newApp(): Promise<"started" | "linux" | "agents">;
    /**
     * The Agents view (agents.ts): everything now (full), then "agents.delta" (AgentsDelta, only what changed) until
     * unsubscribe - a hidden page unsubscribes and takes a snapshot again when it shows.
     */
    snapshot(): Promise<AgentsDelta>;
    unsubscribe(): Promise<void>;
    /** Shows [agent]'s events (null: none): they come as "agents.delta" ({ eventsOf, events }), now and on change. */
    events(agent: string | null): Promise<void>;
    /** The agents' notification was tapped since last asked ("agents.open" says so to a page that's there). */
    takeOpen(): Promise<boolean>;
    /** The user's answer to an ask (AgentAsk.id): allow, or deny with what the agent is told instead. */
    answer(ask: string, behavior: "allow" | "deny", reason?: string): Promise<void>;
    /** Mail to an agent's comms inbox (its role), as the user. */
    message(role: string, text: string): Promise<void>;
    /** Ends an agent's current turn (SIGINT; the session stays). This phone's agents only. */
    interrupt(agent: string): Promise<void>;
  };
  /**
   * Speech to text (the phone's recognizer; the page's own has none). "speech.state" ({ listening, text, error })
   * as it hears; "speech.done" ({ text }) once it ends; "speech.permission" ({ granted }) after it asked for the mic.
   */
  speech: {
    /**
     * Listens across pauses: [hold] until stop(), else until ~4 s with nothing heard (or stop()). "asked": it asked for
     * the mic first, nothing started.
     */
    start(hold: boolean): Promise<"started" | "asked" | "unavailable">;
    stop(): Promise<void>;
    cancel(): Promise<void>;
    /** The dictation under way becomes a hold's: it ends only at stop() (the press that started it is still down). */
    hold(): Promise<void>;
    /** Binds the recognizer without listening (the mic stays closed), so the next start is immediate. */
    warm(): Promise<void>;
    /** The dictation under way (a tap's) ends after [ms] with nothing heard instead of ~4 s. */
    quiet(ms: number): Promise<void>;
  };
  keyboard: {
    show(): Promise<void>;
    hide(): Promise<void>;
  };
  /** The pet over apps (system/PetOverlay.kt): on or off; no argument reads it. An older host has none: check. */
  pet?: {
    overlay(on?: boolean): Promise<boolean>;
  };
  system: {
    insets(): Promise<Insets>;
    /** The display the host shows on now (dp), pushed as "system.display" on every fold/display change and on resume. An older host or the web shell has none: check. */
    display?(): Promise<{ widthDp: number; heightDp: number; displayId: number; rotation: number; folded: boolean }>;
    /** The battery: level 0-100 (null when unknown) and whether it's charging. */
    battery(): Promise<{ level: number | null; charging: boolean }>;
    /** Pulls Android's notification shade down ([open], the default) or puts it away. */
    notifications(open?: boolean): Promise<boolean>;
    /**
     * What the shell's glass (ui/glass.ts) has to work with: the wallpaper behind the page as an image (Android draws
     * it behind the window, out of the page's reach - the page frosts this copy of it once), and whether the host
     * blurs what's behind this window itself (the shade's, over an app). "system.glass" brings it again when the
     * wallpaper changes. Hosts without it reject: no glass, the plain fills.
     */
    glass(): Promise<GlassSource>;
  };
  /**
   * Events: "apps.changed", "home.changed", "widget.tree", "system.back" (Android's Back), "system.home" (Home pressed while home shows), "keyboard.inset" (px, every frame of its slide), "system.insets", "system.display" (widthDp, heightDp, displayId, rotation, folded), "ai.changed" (a Chat), "ai.mail" (AgentMail[]), "assist.context" (AssistScreen), "shade.drag" ({ q }), "shade.panel" ({ panel: "notifications" | "control" }), "media.changed" (MediaState), "qs.changed" (QuickState), "qs.collapse" (a tile opened something: the panel goes), "lock.shown" (the face shown again), "shade.settle" ({ open }), "shade.peek" (PhoneNotification | null), "qt.drag" ({ side, y, q }) / "qt.settle" ({ open }) (Quick Tools), "home.panel" ({ kind }: home with its pull-up panel up), "recents.begin" / "recents.drag" / "recents.end" / "recents.show" / "recents.hide" / "recents.tasks" (Bridge.recents), "switcher.toggle", "ai.sessions" (AgentSession[]), "verify.state" (VerifyState), "widget.screen" (a WidgetScreen), "speech.state" / "speech.done" / "speech.permission", "theme.changed" (ThemeColors), "system.glass" (GlassSource), "notifications.changed" (NotificationList),
   * "appwidgets.frame" ({ id, url, scrolls }), "appwidgets.failed" ({ provider }), "files.changed" ({ path }, for hot reload), "windows.changed" (DesktopWindow[]), "agents.delta" (AgentsDelta), "agents.open" (the agents' notification tapped). Returns an unsubscribe function.
   */
  on(event: string, handler: (data: any) => void): () => void;
}

export interface TermState {
  running: boolean;
  /** The exit status once it ended (-signal if a signal ended it). */
  code: number | null;
  /** Which start of [id] this is: events of an earlier one are stale. */
  run: number;
  /** Its latest output (base64), up to [end], the offset after it. */
  history: string;
  end: number;
}

export interface TermStyle {
  /** Text size, CSS px; the pad around the text, CSS px; Android's font scale (a widget's textSize is in sp). */
  size: number;
  pad: number;
  fontScale: number;
  family: string;
  /** The family's file is there (/_font/terminal/<family>); the Nerd Font symbols are at /_font/symbols. */
  font: boolean;
}

/** A widget's node tree (WidgetTree.kt): props evaluated, colors as CSS, a Canvas's drawing as ops. */
export interface OwlNode {
  k: string;
  id: string;
  p?: Record<string, any>;
  h?: string[];
  c?: OwlNode[];
  ops?: OwlOp[];
}

export interface OwlOp {
  op: string;
  a: any[];
  n?: Record<string, any>;
  c?: OwlOp[];
}

export interface OwlRoot extends OwlNode {
  padding?: number;
  /** The widget has an onTap: a tap on the tile that no element takes runs it (widgets.tap). */
  tap?: boolean;
  background?: string | null;
}

declare global {
  interface Window {
    powos?: Bridge;
    /**
     * [name]: which host ("powos": the desktop's powos-shell; none: the phone's WebView, "android"). The desktop has
     * call(); the phone has postMessage(JSON [id, method, args]) - a web message listener only the page's top frame at
     * its own origin gets (ShellOrigin.kt), never an iframe.
     */
    PowosHost?: { name?: string; call?(id: number, method: string, args: string): void; postMessage?(message: string): void };
    __powosHost?: {
      resolve(id: number, v: unknown): void;
      reject(id: number, m: string): void;
      emit(e: string, d: unknown): void;
    };
  }
}

/**
 * The Agents view's rows (docs/AGENTS-VIEW-DESIGN.md §3): the same fields as powos-agentsd's spool and, in Phase 2,
 * SpacetimeDB's tables. Ids are host-prefixed ("phone:<session>", "mac:<session>/<subagent>"); times Unix ms.
 */
export interface Agent {
  id: string;
  host: string;
  role: string;
  /** The parent agent's id; "@<role>" when it's only known by its comms role (resolved to that role's agent). */
  parent: string | null;
  state: "working" | "idle" | "needs_you" | "blocked" | "paused" | "gone";
  title: string;
  step: string;
  cwd: string;
  pid: number;
  subs: number;
  unread: number;
  report: string;
  /** The work board task it holds (`powos agents task set <id> --step ...`; powos-agentsd's `work`), "" or absent: none. */
  work?: string;
  /** A finished subagent's landed commit sha, from its hand-back ("" or absent: none named). */
  sha?: string;
  started: number;
  last: number;
  rev: number;
}
export interface AgentTask {
  id: string;
  agent: string;
  subject: string;
  status: "open" | "in_progress" | "done";
  order: number;
  updated: number;
}
export interface AgentEvent {
  id: number;
  agent: string;
  ts: number;
  kind: "tool" | "prompt" | "stop" | "sub_start" | "sub_stop" | "notify" | "fail" | "compact";
  name: string;
  hint: string;
  ok: boolean | null;
  n: number;
  ms: number;
}
export interface AgentMessage {
  id: string;
  from: string;
  to: string;
  kind: "message" | "escalate" | "notify" | "ask" | "report";
  priority: string;
  ts: number;
  body: string;
  read: boolean;
}
export interface AgentAsk {
  id: string;
  agent: string;
  tool: string;
  summary: string;
  ts: number;
  expires: number;
  answer: "allow" | "deny" | null;
  reason: string | null;
  by: string | null;
}
/**
 * What changed (§4 The backend swap): rows by id; [gone] agents removed; [tasksOf] agents whose task lists [tasks]
 * replace; [eventsOf] the agent whose recent events [events] are; [full] everything, replacing what was there.
 */
export interface AgentsDelta {
  agents?: Agent[];
  gone?: string[];
  tasks?: AgentTask[];
  tasksOf?: string[];
  events?: AgentEvent[];
  eventsOf?: string;
  messages?: AgentMessage[];
  asks?: AgentAsk[];
  full?: boolean;
}

export type RemoteTarget = "usb" | "bluetooth";
export interface RemoteHost {
  address: string;
  name: string;
  /** The one it was with last: Bluetooth reconnects to it. */
  last?: boolean;
  connected?: boolean;
}
/** Remote input's sides: where reports go, and how each side is. */
export interface RemoteState {
  target: RemoteTarget | null;
  usb: {
    on: boolean;
    busy: boolean;
    /** The phone's USB port: "configured" (a computer has it), "not attached", "off"... */
    state: string;
    error: string | null;
  };
  bluetooth: {
    available: boolean;
    enabled: boolean;
    registered: boolean;
    discoverable: boolean;
    /** The phone's Bluetooth name: what a computer finds when pairing. */
    name?: string | null;
    host: RemoteHost | null;
    connecting: string | null;
    /** Paired computers, the last one first. */
    hosts: RemoteHost[];
    error: string | null;
  };
}

/** An arm of the glasses: its address, advertised name, and link ("off" | "connecting" | "discovering" | "authenticating" | "ready"). */
export interface GlassesArm {
  address: string;
  name: string | null;
  phase: string;
}
/** The glasses as the host has them (Glasses.state). */
export interface GlassesState {
  /** Bluetooth there, and on. */
  available: boolean;
  enabled: boolean;
  /** The paired pair: "G2" | "G1" and its id ("G2_84"); null: none paired. */
  paired: { model: "G1" | "G2"; pairId: string } | null;
  /** Connected or reconnecting on purpose. */
  wanted: boolean;
  phase: "off" | "connecting" | "ready";
  left: GlassesArm | null;
  right: GlassesArm | null;
  /** On the face (null: the glasses don't say - the G2). */
  worn: boolean | null;
  /** False while the display is cleared because they're off the face. */
  shown: boolean;
  battery: Record<string, number>;
  mic: boolean;
  error: string | null;
  /** The display: 576x288 at 4 bits (G2), 576x136 at 1 bit (G1). */
  canvas: { width: number; height: number; bits: number } | null;
  /** Pictures: confirmed on real glasses (G1), and usable now (G2 only with the g2Raster option). */
  image: { verified: boolean; usable: boolean };
  options: Record<string, boolean>;
}

export type HealthType = "steps" | "heart_rate" | "sleep" | "exercise" | "weight" | "active_calories";

export interface HealthStatus {
  /** "none": no Health Connect on this phone; "update": its provider app needs an update. */
  state: "ok" | "update" | "none";
  granted: HealthType[];
  missing: HealthType[];
}

/** One normalised Health Connect record. Units: steps count, heart_rate bpm (start = end), sleep/exercise min, weight kg, active_calories kcal. */
export interface HealthRecord {
  /** Stable (Health Connect's record id; heart rate: "<id>:<n>"): the same record read again upserts. */
  id: string;
  type: HealthType;
  start: number;
  end: number;
  value: number;
  unit: string;
  /** The package of the app that wrote it - the wearable's own app. */
  source: string;
  /** Exercise: its title or Health Connect's exercise type number. */
  detail?: string;
}
