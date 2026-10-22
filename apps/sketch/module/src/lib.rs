//! Sketch's logic: a PowOS app module in the device's own SpacetimeDB (Tier 0 - no process of its own).
//! A drawing is vector data: its strokes (table `stroke`) in the drawing's own space (the canvas's device pixels when
//! the drawing was started: `width` x `height`), so any screen, rotation or fold redraws them whole - fitted, never
//! cropped. Each stroke is written as it ends, so a restart loses nothing. `image` is only a picture of the whole
//! drawing for the gallery and the home widget; `base` is the raster an older (pre-stroke) drawing started from.
//! The canvas is unbounded: `viewport` is how each drawing was last looked at (pan + zoom), kept apart from the
//! drawing itself so moving the view never touches a stroke.
//!
//! Hot reload: `powos app publish` (or `powos app dev`) swaps this module in place, clients connected throughout.
//! Keep schema changes additive - a new table, or a new column at the END of a table with
//! `#[default(...)]` - so the data migrates in place; renaming or removing a column is refused by the server.
use spacetimedb::{ReducerContext, SpacetimeType, Table, Timestamp};

/// Stamped on the rows this module writes: a republished module shows on the next change.
const MODULE: &str = env!("CARGO_PKG_VERSION");
/// A data URL bigger than this is refused (a full-screen WebP is ~100-400 KB).
const MAX_IMAGE: usize = 3 * 1024 * 1024;
const MAX_TITLE: usize = 80;
/// A stroke's points: x, y, width triples - at most this many numbers (10k points).
const MAX_POINTS: usize = 30_000;

#[spacetimedb::table(accessor = drawing, public)]
pub struct Drawing {
    #[primary_key]
    #[auto_inc]
    id: u64,
    title: String,
    /// The image as a data URL (image/webp or image/png).
    image: String,
    width: u32,
    height: u32,
    created: Timestamp,
    updated: Timestamp,
    module: String,
    /// The page's own id for the drawing (it makes one before the server answers); "" = an older raster drawing.
    #[default("")]
    key: String,
    /// The raster an older drawing started from, drawn under its strokes in the box width x height.
    #[default("")]
    base: String,
}

/// One stroke of a drawing, in that drawing's own space.
#[spacetimedb::table(accessor = stroke, public)]
pub struct Stroke {
    #[primary_key]
    #[auto_inc]
    id: u64,
    #[index(btree)]
    drawing: u64,
    /// The page's id for it: retries are idempotent, undo/redo address it before the server answered.
    uid: String,
    color: String,
    eraser: bool,
    /// x, y, width triples.
    points: Vec<f32>,
    /// Undone (or cleared): kept so redo / undoing a clear brings it back.
    hidden: bool,
    created: Timestamp,
}

/// How a drawing is looked at (one row per drawing key; none = fitted whole): the drawing-space point at the
/// canvas's centre and the zoom (CSS px per drawing unit), so a rotation or another screen keeps the same spot.
/// `fit` = the user asked to see everything: the page refits it on every resize instead.
#[spacetimedb::table(accessor = viewport, public)]
pub struct Viewport {
    #[primary_key]
    key: String,
    cx: f64,
    cy: f64,
    zoom: f64,
    fit: bool,
    updated: Timestamp,
}

/// A view as the page sends it (Viewport without its key and time).
#[derive(SpacetimeType)]
pub struct ViewIn {
    cx: f64,
    cy: f64,
    zoom: f64,
    fit: bool,
}

/// A finished stroke as the page sends it; width x height = the canvas, used only when it starts a new drawing.
#[derive(SpacetimeType)]
pub struct StrokeIn {
    uid: String,
    width: u32,
    height: u32,
    color: String,
    eraser: bool,
    points: Vec<f32>,
}

fn check(image: &str) -> Result<(), String> {
    if !image.starts_with("data:image/") {
        return Err("image: a data:image/... URL".into());
    }
    if image.len() > MAX_IMAGE {
        return Err(format!("image: at most {} KB", MAX_IMAGE / 1024));
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn rename(ctx: &ReducerContext, id: u64, title: String) -> Result<(), String> {
    let title = title.trim().to_string();
    if title.is_empty() || title.len() > MAX_TITLE {
        return Err(format!("title: 1..{MAX_TITLE} characters"));
    }
    let mut d = ctx.db.drawing().id().find(id).ok_or("no such drawing")?;
    d.title = title;
    d.module = MODULE.into();
    ctx.db.drawing().id().update(d);
    Ok(())
}

#[spacetimedb::reducer]
pub fn remove(ctx: &ReducerContext, id: u64) {
    let ids: Vec<u64> = ctx.db.stroke().drawing().filter(id).map(|s| s.id).collect();
    for s in ids {
        ctx.db.stroke().id().delete(s);
    }
    if let Some(d) = ctx.db.drawing().id().find(id) {
        ctx.db.viewport().key().delete(&d.key);
    }
    ctx.db.drawing().id().delete(id);
}

fn by_key(ctx: &ReducerContext, key: &str) -> Option<Drawing> {
    if key.is_empty() {
        return None;
    }
    ctx.db.drawing().iter().find(|d| d.key == key)
}

fn new_drawing(ctx: &ReducerContext, key: &str, width: u32, height: u32) -> Drawing {
    let n = ctx.db.drawing().count() + 1;
    ctx.db.drawing().insert(Drawing {
        id: 0,
        title: format!("Sketch {n}"),
        image: String::new(),
        width: width.max(1),
        height: height.max(1),
        created: ctx.timestamp,
        updated: ctx.timestamp,
        module: MODULE.into(),
        key: key.into(),
        base: String::new(),
    })
}

fn check_stroke(s: &StrokeIn) -> Result<(), String> {
    if s.uid.is_empty() || s.uid.len() > 64 || s.color.len() > 32 {
        return Err("stroke: uid 1..64, color at most 32 characters".into());
    }
    if s.points.is_empty() || s.points.len() % 3 != 0 || s.points.len() > MAX_POINTS {
        return Err(format!("stroke: points are x, y, width triples, at most {MAX_POINTS} numbers"));
    }
    if s.points.iter().any(|v| !v.is_finite()) {
        return Err("stroke: points must be finite".into());
    }
    Ok(())
}

/// Add a finished stroke to the drawing `key` (made, the box width x height, if it doesn't exist yet). A uid already
/// there is a retry: nothing happens.
#[spacetimedb::reducer]
pub fn add_stroke(ctx: &ReducerContext, key: String, s: StrokeIn) -> Result<(), String> {
    check_stroke(&s)?;
    if key.is_empty() || key.len() > 64 {
        return Err("key: 1..64 characters".into());
    }
    let d = match by_key(ctx, &key) {
        Some(d) => d,
        None => new_drawing(ctx, &key, s.width, s.height),
    };
    if ctx.db.stroke().drawing().filter(d.id).any(|x| x.uid == s.uid) {
        return Ok(());
    }
    ctx.db.stroke().insert(Stroke {
        id: 0,
        drawing: d.id,
        uid: s.uid,
        color: s.color,
        eraser: s.eraser,
        points: s.points,
        hidden: false,
        created: ctx.timestamp,
    });
    let mut d = d;
    d.updated = ctx.timestamp;
    d.module = MODULE.into();
    ctx.db.drawing().id().update(d);
    Ok(())
}

/// Undo / redo / clear: hide or show these strokes (never deletes them).
#[spacetimedb::reducer]
pub fn set_hidden(ctx: &ReducerContext, key: String, uids: Vec<String>, hidden: bool) -> Result<(), String> {
    let d = by_key(ctx, &key).ok_or("no such drawing")?;
    let rows: Vec<Stroke> = ctx.db.stroke().drawing().filter(d.id).filter(|s| uids.contains(&s.uid)).collect();
    for mut s in rows {
        s.hidden = hidden;
        ctx.db.stroke().id().update(s);
    }
    Ok(())
}

/// Forget undone strokes that can't be redone any more (a new stroke after an undo). Only hidden ones go.
#[spacetimedb::reducer]
pub fn drop_hidden(ctx: &ReducerContext, key: String, uids: Vec<String>) -> Result<(), String> {
    let d = by_key(ctx, &key).ok_or("no such drawing")?;
    let ids: Vec<u64> =
        ctx.db.stroke().drawing().filter(d.id).filter(|s| s.hidden && uids.contains(&s.uid)).map(|s| s.id).collect();
    for id in ids {
        ctx.db.stroke().id().delete(id);
    }
    Ok(())
}

/// An older raster drawing becomes a stroke drawing: its picture becomes the base its new strokes draw over (the
/// picture itself is kept as it was). Again with the same key: nothing happens.
#[spacetimedb::reducer]
pub fn adopt(ctx: &ReducerContext, id: u64, key: String) -> Result<(), String> {
    if key.is_empty() || key.len() > 64 {
        return Err("key: 1..64 characters".into());
    }
    let mut d = ctx.db.drawing().id().find(id).ok_or("no such drawing")?;
    if d.key == key {
        return Ok(());
    }
    if !d.key.is_empty() {
        return Err("that drawing has a key already".into());
    }
    d.key = key;
    d.base = d.image.clone();
    d.module = MODULE.into();
    ctx.db.drawing().id().update(d);
    Ok(())
}

/// The gallery / widget picture of the drawing `key` (its strokes stay the drawing).
#[spacetimedb::reducer]
pub fn thumb(ctx: &ReducerContext, key: String, image: String) -> Result<(), String> {
    check(&image)?;
    let mut d = by_key(ctx, &key).ok_or("no such drawing")?;
    d.image = image;
    d.updated = ctx.timestamp;
    d.module = MODULE.into();
    ctx.db.drawing().id().update(d);
    Ok(())
}

/// Where the drawing `key` is looked at (pan + zoom). Only the view: the drawing and its strokes stay as they are.
#[spacetimedb::reducer]
pub fn set_view(ctx: &ReducerContext, key: String, v: ViewIn) -> Result<(), String> {
    if key.is_empty() || key.len() > 64 {
        return Err("key: 1..64 characters".into());
    }
    let ViewIn { cx, cy, zoom, fit } = v;
    if !cx.is_finite() || !cy.is_finite() || !zoom.is_finite() || zoom <= 0.0 || zoom > 1000.0 {
        return Err("view: finite centre, zoom in (0, 1000]".into());
    }
    let v = Viewport { key, cx, cy, zoom, fit, updated: ctx.timestamp };
    if ctx.db.viewport().key().find(&v.key).is_some() {
        ctx.db.viewport().key().update(v);
    } else {
        ctx.db.viewport().insert(v);
    }
    Ok(())
}
