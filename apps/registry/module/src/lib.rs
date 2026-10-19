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
