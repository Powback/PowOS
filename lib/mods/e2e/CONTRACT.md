# What a game must expose to be end-to-end testable

`powos mods verify` works on any Steam game with no cooperation from it: launch,
watch for frames and CPU progress, report crash/freeze/booted. That is a
compatibility check, and it is the ceiling of what you can learn from outside a
process.

`powos mods e2e` asks a different question — *does the mod actually do what it
claims* — and that question cannot be answered from outside. A mod can load
cleanly, survive the full timeout, and do nothing at all. Answering it needs
four things, of which three are already generic and one is on the game.

| | What it is | Who provides it |
|---|---|---|
| **Launch** | Start the game as the user really runs it | generic — `steam -applaunch` + the user's own Proton and launch options |
| **Input** | Drive it like a player | generic — virtual controllers via `/dev/uinput` |
| **State** | Read what the game currently believes | **the game or its mod** |
| **Assertions** | Named cases with a verdict | you, in a scenario module |

State is the whole difficulty. Everything else here is shared code.

---

## 1. The state channel

The harness must be able to ask the running game what is true right now and get
a structured answer. Without it a test can only assert on log lines and pixels,
and neither can answer "is there a second player, and where is he" — which is
the actual claim under test.

Four ways to provide it, best first.

### `http-json` — a loopback endpoint inside the game

The recommendation for anything you can put code inside. Cheap to implement,
trivial to assert on, and it works through Proton: a Windows build under Wine
listening on `127.0.0.1` is reachable from Linux tooling, because Wine's
sockets are the host's. This is verified, not assumed — it is how the Hollow
Knight scenario works.

`CoopKit.DebugServer` (`~/Projects/CoopModKit`) is a ~250-line drop-in for any
BepInEx/Unity mod. It handles the part that is easy to get wrong: **handlers run
on the game thread**, not the socket thread, because almost every engine's
object model explodes when touched from a background thread. The socket parks
the request on a queue and the mod's per-frame update runs it.

```csharp
_server = new DebugServer(log)
    .Route("/state", _ => Snapshot())     // returns a JSON string
    .Route("/cmd",   Command);
_server.Snapshot(path, "/state");         // also write it to a file
_server.Start(port);
// ...and from your Update(): _server.Pump(Time.unscaledTimeAsDouble);
```

```
E2E_STATE_KIND="http-json"
E2E_STATE_URL="http://127.0.0.1:27600"
E2E_STATE_PATH="/state"
E2E_COMMAND_PATH="/cmd"
```

**Safety is part of the contract.** The channel exposes internal state and,
through commands, control of it. It must be:

* **off by default**, so a released build with an untouched config never opens
  a socket;
* **loopback only** — `127.0.0.1`, never a wildcard;
* **switchable per run**, so the harness enables it for one run without editing
  the player's config permanently (`E2E_CONFIG_SET`, restored afterwards) or by
  an environment variable the mod reads.

### `cdp` — for games whose UI is a browser engine

Venice Unleashed's WebUI is Coherent Gameface, i.e. Chromium, and exposes the
Chrome DevTools Protocol when the client is launched with `-dwebui`. The
harness evaluates JS in the page and reads whatever the UI can see. Backed by
`lib/mods/vu-cdp.py`.

```
E2E_STATE_KIND="cdp"
E2E_CDP_ADDR="localhost:8884"
E2E_CDP_TARGET="mapeditor"
E2E_CDP_STATE_JS="(function(){return JSON.stringify({...});})()"
```

### `file` — a JSON snapshot the game writes

The fallback when you cannot open a socket. Poll-only, no commands, but it
survives anything a socket cannot, and it leaves the last live state on disk
after a crash. Snapshots are checked for staleness: a file the game stopped
writing is rejected rather than served as current, because a frozen world that
parses cleanly is worse than no data.

```
E2E_STATE_KIND="file"
E2E_STATE_FILE='${GAME_DIR}/BepInEx/state.json'
```

### `none`

No channel. Cases that need one are reported as **errored**, never failed —
the game is not being measured, and saying "fail" would send you debugging
code that works. A run of nothing but skips is reported as `not-run`, not a
pass.

### What to put in a snapshot

Whatever your assertions need, but at minimum: an identity (mod name and
version, game version), where the game is (scene, game state, is it paused),
and one entry per entity the feature is about, each with a **position** and its
**bound input device**. Positions are what make "moved independently" provable;
device bindings are what make "player two is on the second controller"
provable.

Numbers must be JSON-legal. A dead transform yields NaN, and a NaN emitted raw
produces a document no parser accepts — silently breaking every later
assertion. `CoopKit.Json` writes `null` for those.

---

## 2. Input

Generic. `E2E_PADS=N` creates N virtual Xbox-360-compatible controllers before
the scenario runs; `sess.pad(i)` drives one:

```python
sess.pad(0).press("START")           # tap
sess.pad(0).stick(1.0, 0.0)          # hold right
sess.pad(1).press("A", 2.0)          # hold two seconds
```

Three things to know, all learned the hard way:

* **`/dev/uinput` needs permission.** An ACL (`setfacl -m u:$USER:rw
  /dev/uinput`) or a udev rule plus `input` group membership. `powos mods e2e
  <game> --probe` says which is missing. On this machine an ACL is already in
  place and no sudo is needed.
* **Focus may be required.** evdev reaches a process regardless of focus, but
  the layers between do not all agree: Unity does not poll input while the
  application is in the background. The symptom is total and silent — pads
  enumerate, no button ever registers, and it looks exactly like a broken mod.
  Set `E2E_FOCUS_WINDOW=1` and `E2E_WINDOW_MATCH`. **This makes a run
  non-headless**: it needs a session whose compositor will honour an activation
  request. Do not engineer around this silently — a rig that depends on window
  focus without saying so will rot.
* **Names do not survive.** Whatever you call a uinput device, the game will
  rename it after whichever controller profile it matched — InControl reports
  every pad as "Xbox Controller". Identify pads by count delta, by a device GUID
  if the engine exposes one, or behaviourally: hold a button and ask the game
  which device index reports a press. The last one is strongest, because it
  measures the mapping instead of assuming it.

---

## 3. The scenario

`lib/mods/e2e/scenarios/<game>.py`. Optional `setup(sess)` gets the game to a
testable state; `@test(...)` registers cases.

```python
from report import test, Skip

def setup(sess):
    sess.add_pads(2)
    sess.channel.command("loadsave", slot=1)
    ok, last = sess.channel.wait_for(lambda s: s["inGameplay"], timeout=180)

@test("player two moves on its own pad, and player one does not")
def t_move(sess):
    ...
    return "player two travelled +4.2 units; player one moved 0.1"
```

Return a string saying what you *observed*. A case that cannot produce one is
usually a case that did not check anything.

### Get into a testable state without driving menus

Most games start at a title screen and the feature under test needs a loaded
save. Driving the title menus with a virtual pad works until someone reorders a
menu row, and then the test fails for a reason that has nothing to do with the
mod. Give the harness a hands-free entry point instead:

* Hollow Knight: a `/cmd?do=loadsave&slot=N` command that calls the game's own
  save-slot load.
* Venice Unleashed: a `DEV_AUTO_ENTER_EDITOR` config flag so the client enters
  the editor by itself once the level loads.

Same idea both times: the mod offers a door, and the harness does not have to
mime a human to get through it.

### Test the configuration people actually use

The easiest configuration to automate is rarely the one under test. For couch
co-op the tempting setup is "player one on the keyboard, every pad is a
joiner" — no pad has to be reserved and the harness is simpler. It also never
checks whether player one's own controller still works once a second player
exists, which is the half that breaks, and which a person notices within
seconds of sitting down. Set the rig up the way the feature ships.

The same idea generalises: if a feature rebinds, reassigns or reroutes
something, assert on **both** sides of the rebinding. The thing that was
supposed to change, and the thing that was supposed to keep working.

And take a baseline first. "X stopped working after Y" is a different bug from
"X never worked", and without a case that measured X before Y they are the
same report.

### Write assertions that can fail

This is the rule that matters most, and the reason this directory contains a
fake game.

**Any "X happened" check that would also pass when *everything* happened needs
its negative half.** "Player two moved" passes when both Knights move together
— which is exactly what a mod wiring the clone to player one's input handler
does. The check has to be "the driven one moved AND the other did not".

Then prove it:

```
powos mods e2e prove <game>
```

`mockgame.py` runs the real scenario against a fake game with no engine behind
it, once healthy and once per known fault. Every case must pass when healthy
and go red under the fault it claims to detect. A case that stays green under
its fault is decoration, and the run says so by name. This costs seconds
instead of a five-minute launch, which is the only reason it actually gets done.

---

## 4. The games.d conf

`config/mods/games.d/<game>.conf`, alongside the existing mod-install rules.

| Key | Meaning |
|---|---|
| `E2E_SCENARIO` | Scenario module name (defaults to the game id) |
| `E2E_PROCESS_MATCH` | The process that *is* the game — waited for on launch, SIGTERMed on teardown |
| `E2E_PADS` | Virtual controllers to create |
| `E2E_LOG_FILES` | Logs to watch (array) |
| `E2E_LOAD_MARKER` | A line proving the mod loaded — advisory only, see below |
| `E2E_STATE_*` | The state channel, per section 1 |
| `E2E_WINDOW_MATCH` / `E2E_FOCUS_WINDOW` | Window title, and whether to focus it |
| `E2E_READY_TIMEOUT` / `E2E_STOP_GRACE` | Seconds to become testable / to shut down |
| `E2E_CONFIG_SET` | `<path>:[Section]Key=Value` applied before the run, **restored after** |
| `E2E_BACKUP` | Globs copied before the run and restored after |
| `E2E_SAVE_SLOT` | Save to load; blank lets the scenario work it out |

Single-quote anything containing `${GAME_DIR}` or `${HOME}` — the conf is
sourced by bash, and those must survive to be expanded by the harness against
the resolved Steam library path.

Two traps encoded here because both cost a full launch to find:

* **`E2E_CONFIG_SET` sections are not decoration.** INI keys are scoped to
  their section. Appending `DebugServer = true` to the end of a file puts it in
  whatever section happens to be last, where the code reading `[Debug]` never
  finds it — the setting silently keeps its default and the failure surfaces
  much later as "the feature did not turn on".
* **`E2E_BACKUP` takes globs, not directories.** Backing up a save folder and
  restoring it afterwards also restores everything else living there. For
  Hollow Knight that is `Player.log`, so each run reverted its own game log to
  the previous run's copy and every log-based diagnosis read stale lines.

---

## 5. Things that will bite you

**Logs are block-buffered.** A game's log does not reach disk while it runs, so
a marker can be absent for a minute after the event. `E2E_LOAD_MARKER` is
therefore advisory: its absence is warned about, never fatal. The state channel
is the gate. Anything time-sensitive must come from the channel.

**Logs get truncated.** BepInEx rewrites its log every launch. A watcher that
remembers the old file's size and seeks there lands past the end of the new,
shorter file and reads nothing — so a marker in the first ten lines reports as
never appearing. `logs.py` detects a file smaller than its mark and re-reads
from the top.

**Never SIGKILL a game client.** The Proton/nvidia stack leaks GPU and host
memory when a process dies without unwinding, and only a reboot gives it back.
`proc.stop()` sends SIGTERM, waits, and reports a survivor rather than killing
it.

**Never match your own process.** `pgrep -f <pattern>` matches the shell running
it, so `kill $(pgrep -f ...)` kills the caller. `proc.find()` scans `/proc`
directly and excludes this process, its ancestors, and anything whose `comm` is
a shell or interpreter — a process finder must not be able to return the
process doing the finding.

**Somebody else's game.** If a matching process is already running, the harness
reuses it, says loudly that it did not apply its own launch environment, and
**does not stop it at teardown** — whoever started it owns it. Results from a
session you did not configure are not results, and SIGTERMing a colleague's
game mid-play has no undo. (This harness did exactly that once, before the
guard existed.)
