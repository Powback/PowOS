//! powos_registry: the device's list of PowOS apps and their widgets (docs/POWOS-APPS-FEASIBILITY.md section 5.5).
//! The launcher, the desktop and agents subscribe to it, so an install shows up everywhere live. Written only by the
//! device owner - the identity that published this module (`powos app install` runs as that user) - and read by
//! everyone. An app's row carries its whole powos-app.json, so readers need nothing else.
use serde::Deserialize;
use spacetimedb::{Identity, ReducerContext, Table, Timestamp};

#[spacetimedb::table(accessor = owner)]
pub struct Owner {
    #[primary_key]
    id: u8,
    identity: Identity,
}

#[spacetimedb::table(accessor = app, public)]
pub struct App {
    #[primary_key]
    id: String,
    name: String,
    version: String,
    /// Its database on this server ("" for none).
    database: String,
    /// "module" (Tier 0: no process), "native"/"sandbox"/"container" for a backend.
    tier: u8,
    manifest: String,
    installed_at: Timestamp,
}

#[spacetimedb::table(accessor = widget, public)]
pub struct Widget {
    /// "<app id>/<widget id>"
    #[primary_key]
    key: String,
    #[index(btree)]
    app_id: String,
    name: String,
    /// "island" (a module the shared host page imports) or "owl".
    kind: String,
    /// Relative to the app's UI dir.
    entry: String,
    size: String,
    min_size: String,
}

#[derive(Deserialize)]
struct Manifest {
    id: String,
    name: String,
    version: String,
    #[serde(default)]
    module: Option<ModuleSpec>,
    #[serde(default)]
    backend: Option<serde_json::Value>,
    #[serde(default)]
    widgets: Vec<WidgetSpec>,
}

#[derive(Deserialize)]
struct ModuleSpec {
    database: String,
}

#[derive(Deserialize)]
struct WidgetSpec {
    id: String,
    #[serde(default)]
    name: Option<String>,
    kind: String,
    #[serde(default)]
    entry: Option<String>,
    #[serde(default)]
    file: Option<String>,
    #[serde(default)]
    size: Option<String>,
    #[serde(default, rename = "minSize")]
    min_size: Option<String>,
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.owner().insert(Owner { id: 0, identity: ctx.sender() });
}

fn owner_only(ctx: &ReducerContext) -> Result<(), String> {
    match ctx.db.owner().id().find(0) {
        Some(o) if o.identity == ctx.sender() => Ok(()),
        _ => Err("only the device owner installs apps".into()),
    }
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
}

fn drop_widgets(ctx: &ReducerContext, app_id: &str) {
    let keys: Vec<String> = ctx.db.widget().app_id().filter(&app_id.to_string()).map(|w| w.key).collect();
    for k in keys {
        ctx.db.widget().key().delete(k);
    }
}

/// Adds or replaces an app from its manifest (powos-app.json, as text).
#[spacetimedb::reducer]
pub fn install(ctx: &ReducerContext, manifest: String) -> Result<(), String> {
    owner_only(ctx)?;
    let m: Manifest = serde_json::from_str(&manifest).map_err(|e| format!("powos-app.json: {e}"))?;
    if !valid_id(&m.id) {
        return Err(format!("bad app id {:?}: a-z 0-9 . - only", m.id));
    }
    let tier = if m.backend.as_ref().is_some_and(|b| !b.is_null()) { 1 } else { 0 };
    ctx.db.app().id().delete(m.id.clone());
    ctx.db.app().insert(App {
        id: m.id.clone(),
        name: m.name,
        version: m.version,
        database: m.module.map(|s| s.database).unwrap_or_default(),
        tier,
        manifest: manifest.clone(),
        installed_at: ctx.timestamp,
    });
    drop_widgets(ctx, &m.id);
    for w in m.widgets {
        if !valid_id(&w.id) {
            return Err(format!("bad widget id {:?}", w.id));
        }
        let entry = w.entry.or(w.file).unwrap_or_default();
        if entry.is_empty() || entry.split('/').any(|p| p == "..") {
            return Err(format!("widget {}: bad entry", w.id));
        }
        ctx.db.widget().insert(Widget {
            key: format!("{}/{}", m.id, w.id),
            app_id: m.id.clone(),
            name: w.name.unwrap_or_else(|| w.id.clone()),
            kind: w.kind,
            entry,
            size: w.size.unwrap_or_else(|| "4x2".into()),
            min_size: w.min_size.unwrap_or_else(|| "2x1".into()),
        });
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn remove(ctx: &ReducerContext, id: String) -> Result<(), String> {
    owner_only(ctx)?;
    drop_widgets(ctx, &id);
    ctx.db.app().id().delete(id);
    Ok(())
}

// --------------------------------------------------------------------------------------------------------- creation
//
// An app or widget being built (docs/AGENT-HANDBOOK.md, "live creation"): written by the build pipeline (powos-app
// cmd_new/cmd_install for apps, powos-compose for widgets) as each step starts and ends, so the shell can show a
// live placeholder instead of nothing. Never written by the shell page itself - it only subscribes (owner_only, like
// install/remove). Kept separate from `app`/`widget`: a creation that fails or is discarded never touches them.

#[spacetimedb::table(accessor = creation, public)]
pub struct Creation {
    #[primary_key]
    id: String,
    /// "app" or "widget".
    kind: String,
    /// What the user asked for; also what Retry re-sends.
    title: String,
    /// "running" | "done" | "failed".
    status: String,
    step: String,
    step_index: u32,
    step_count: u32,
    #[default("")]
    error: String,
    /// The app id (or "<app>/<widget>" key) once known; "" until then.
    #[default("")]
    app_id: String,
    started_at: Timestamp,
    updated_at: Timestamp,
}

#[spacetimedb::table(accessor = creation_step, public)]
pub struct CreationStepRow {
    /// "<creation id>:<idx>"
    #[primary_key]
    id: String,
    #[index(btree)]
    creation_id: String,
    idx: u32,
    label: String,
    /// "pending" | "active" | "done" | "failed".
    state: String,
}

#[spacetimedb::table(accessor = creation_log, public)]
pub struct CreationLog {
    #[primary_key]
    #[auto_inc]
    id: u64,
    #[index(btree)]
    creation_id: String,
    line: String,
    ts: Timestamp,
}

fn creation_clear(ctx: &ReducerContext, id: &str) {
    let keys: Vec<String> = ctx.db.creation_step().creation_id().filter(&id.to_string()).map(|s| s.id).collect();
    for k in keys {
        ctx.db.creation_step().id().delete(k);
    }
    let logs: Vec<u64> = ctx.db.creation_log().creation_id().filter(&id.to_string()).map(|l| l.id).collect();
    for l in logs {
        ctx.db.creation_log().id().delete(l);
    }
}

fn get_creation(ctx: &ReducerContext, id: &str) -> Result<Creation, String> {
    ctx.db.creation().id().find(id.to_string()).ok_or_else(|| format!("no creation {id:?}"))
}

/// "app:<id>" or "widget:<id>" -> ("app"|"widget", the rest). The kind rides in the id's prefix instead of its own
/// argument so `creation_begin` stays at 4 params (ctx + 3): a struct arg hit a codegen gap (the TS generator drops a
/// SpacetimeType that's only ever a reducer parameter, never a table column - confirmed against apps/sketch's
/// ViewIn/StrokeIn, which ARE table columns elsewhere and do generate; filed as a thing to retry once fixed upstream).
fn creation_kind(id: &str) -> &'static str {
    if id.starts_with("widget:") { "widget" } else { "app" }
}

/// Starts (or restarts, for Retry) a creation with its step labels; the first step is active at once. `id` is
/// "app:<app id>" or "widget:<generated id>".
#[spacetimedb::reducer]
pub fn creation_begin(ctx: &ReducerContext, id: String, title: String, steps: Vec<String>) -> Result<(), String> {
    owner_only(ctx)?;
    let kind = creation_kind(&id).to_string();
    let rest = id.splitn(2, ':').nth(1).unwrap_or(&id);
    if !valid_id(rest) {
        return Err(format!("bad creation id {id:?}: a-z 0-9 . - only after the kind prefix"));
    }
    if steps.is_empty() {
        return Err("creation needs at least one step".into());
    }
    creation_clear(ctx, &id);
    for (i, label) in steps.iter().enumerate() {
        ctx.db.creation_step().insert(CreationStepRow {
            id: format!("{id}:{i}"),
            creation_id: id.clone(),
            idx: i as u32,
            label: label.clone(),
            state: if i == 0 { "active".into() } else { "pending".into() },
        });
    }
    ctx.db.creation().id().delete(id.clone());
    ctx.db.creation().insert(Creation {
        id,
        kind,
        title,
        status: "running".into(),
        step: steps[0].clone(),
        step_index: 0,
        step_count: steps.len() as u32,
        error: String::new(),
        app_id: String::new(),
        started_at: ctx.timestamp,
        updated_at: ctx.timestamp,
    });
    Ok(())
}

/// A log line from the build (the shell shows the latest few).
#[spacetimedb::reducer]
pub fn creation_add_log(ctx: &ReducerContext, id: String, line: String) -> Result<(), String> {
    owner_only(ctx)?;
    get_creation(ctx, &id)?;
    ctx.db.creation_log().insert(CreationLog { id: 0, creation_id: id.clone(), line, ts: ctx.timestamp });
    let mut rows: Vec<CreationLog> = ctx.db.creation_log().creation_id().filter(&id).collect();
    rows.sort_by_key(|r| r.id);
    while rows.len() > 20 {
        ctx.db.creation_log().id().delete(rows.remove(0).id);
    }
    Ok(())
}

/// Step `idx` finished; the next step (if any) becomes active.
#[spacetimedb::reducer]
pub fn creation_step_done(ctx: &ReducerContext, id: String, idx: u32) -> Result<(), String> {
    owner_only(ctx)?;
    let mut c = get_creation(ctx, &id)?;
    if let Some(mut s) = ctx.db.creation_step().id().find(format!("{id}:{idx}")) {
        s.state = "done".into();
        ctx.db.creation_step().id().update(s);
    }
    let next = idx + 1;
    if next < c.step_count {
        if let Some(mut s) = ctx.db.creation_step().id().find(format!("{id}:{next}")) {
            c.step = s.label.clone();
            s.state = "active".into();
            ctx.db.creation_step().id().update(s);
        }
        c.step_index = next;
    }
    c.updated_at = ctx.timestamp;
    ctx.db.creation().id().update(c);
    Ok(())
}

/// The current step (and the whole creation) failed; the shell offers Retry / Discard.
#[spacetimedb::reducer]
pub fn creation_failed(ctx: &ReducerContext, id: String, error: String) -> Result<(), String> {
    owner_only(ctx)?;
    let mut c = get_creation(ctx, &id)?;
    if let Some(mut s) = ctx.db.creation_step().id().find(format!("{}:{}", id, c.step_index)) {
        s.state = "failed".into();
        ctx.db.creation_step().id().update(s);
    }
    c.status = "failed".into();
    c.error = error;
    c.updated_at = ctx.timestamp;
    ctx.db.creation().id().update(c);
    Ok(())
}

/// The build finished: `app_id` is the real app (or "<app>/<widget>" key) now in `app`/`widget`.
#[spacetimedb::reducer]
pub fn creation_done(ctx: &ReducerContext, id: String, app_id: String) -> Result<(), String> {
    owner_only(ctx)?;
    let mut c = get_creation(ctx, &id)?;
    c.status = "done".into();
    c.app_id = app_id;
    c.step_index = c.step_count.saturating_sub(1);
    c.updated_at = ctx.timestamp;
    ctx.db.creation().id().update(c);
    Ok(())
}

/// The user dismissed a finished or failed placeholder (or Retry's old attempt, before a fresh `creation_begin`).
#[spacetimedb::reducer]
pub fn creation_discard(ctx: &ReducerContext, id: String) -> Result<(), String> {
    owner_only(ctx)?;
    creation_clear(ctx, &id);
    ctx.db.creation().id().delete(id);
    Ok(())
}
