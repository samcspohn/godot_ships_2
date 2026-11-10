//! SkillStance's incoming-damage rows per (shooter, range bucket): [row, raw, hit] over every aspect.

use std::collections::HashMap;

use godot::prelude::*;

use crate::projectile::manager::stance_cells::{fill_cells, Pack};
use crate::projectile::manager::ProjectileManager;

struct Bucket {
    range: f64,
    cal: f64,
    read: i64,
    /// NAN cells until filled; None once one is unknown, then it serves nothing.
    cells: Option<[Vec<f32>; 3]>,
}

struct Shooter {
    sig: i64,
    t: f64,
    buckets: HashMap<i32, Bucket>,
    /// BotGunnery.stance_cell_pack's inputs, parsed once per sig, and the shell read rows are built under.
    pack: Option<(Pack, i64)>,
}

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct StanceRows {
    base: Base<RefCounted>,
    by: HashMap<i64, Shooter>,
}

#[godot_api]
impl StanceRows {
    /// Drops `id`'s buckets once built under another sig or more than `ttl` ago.
    #[func]
    fn validate(&mut self, id: i64, sig: i64, now: f64, ttl: f64) -> i64 {
        let why = match self.by.get(&id) {
            None => 1,
            Some(s) if now - s.t > ttl => 2,
            Some(s) if s.sig != sig => 3,
            _ => return 0,
        };
        let dropped = self.by.get(&id).map_or(0, |s| s.buckets.len()) as i64;
        self.by.insert(id, Shooter { sig, t: now, buckets: HashMap::new(), pack: None });
        why * 100000 + dropped
    }

    #[func]
    fn has(&self, id: i64, bucket: i32) -> bool {
        self.by.get(&id).is_some_and(|s| s.buckets.contains_key(&bucket))
    }

    #[func]
    fn has_pack(&self, id: i64) -> bool {
        self.by.get(&id).is_some_and(|s| s.pack.is_some())
    }

    #[func]
    fn set_pack(&mut self, id: i64, pack: VarDictionary, read: i64) {
        if let Some(s) = self.by.get_mut(&id) {
            s.pack = Some((Pack::read(&pack), read));
        }
    }

    /// An empty `bucket`, its cells built at `range` under `cal` and shell read `read`.
    #[func]
    fn create(&mut self, id: i64, bucket: i32, range: f64, cal: f64, read: i64, n_asp: i64) {
        if let Some(s) = self.by.get_mut(&id) {
            let nan = vec![f32::NAN; n_asp.max(0) as usize];
            s.buckets.insert(bucket, Bucket { range, cal, read, cells: Some([nan.clone(), nan.clone(), nan]) });
        }
    }

    /// Fills `cells` of `bucket` still NAN; returns the point-query notes.
    #[func]
    fn fill(&mut self, pm: Gd<ProjectileManager>, id: i64, bucket: i32, cells: PackedInt32Array, step_deg: f64) -> PackedInt32Array {
        let Some(s) = self.by.get_mut(&id) else { return PackedInt32Array::new() };
        let (Some((pack, _)), Some(b)) = (s.pack.as_ref(), s.buckets.get_mut(&bucket)) else { return PackedInt32Array::new() };
        let Some(row) = b.cells.as_mut() else { return PackedInt32Array::new() };
        let (known, notes) = fill_cells(&pm.bind(), row, b.range, b.cal, b.read, pack, step_deg, cells.as_slice());
        if !known {
            b.cells = None;
        }
        PackedInt32Array::from(notes.as_slice())
    }

    /// Kind 0 rows, 1 raw, 2 hit; empty when absent or unknown.
    #[func]
    fn row(&self, id: i64, bucket: i32, kind: i64) -> PackedFloat32Array {
        self.get(id, bucket, kind as usize).flatten().map_or_else(PackedFloat32Array::new, PackedFloat32Array::from)
    }

    /// `to` serves what `from` does (a freed shooter's survey bucket).
    #[func]
    fn copy_bucket(&mut self, id: i64, from: i32, to: i32) {
        if let Some(s) = self.by.get_mut(&id) {
            let cells = s.buckets.get(&from).and_then(|b| b.cells.clone());
            s.buckets.insert(to, Bucket { range: 0.0, cal: 0.0, read: 0, cells });
        }
    }

    #[func]
    fn clear(&mut self) {
        self.by.clear();
    }
}

impl StanceRows {
    /// Builds `bucket` at `range` when absent and fills aspect `a`, as GDScript's _ensure would; false without a pack.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn ensure_cell(&mut self, pm: &ProjectileManager, id: i64, bucket: i32, range: f64, a: usize, step_deg: f64,
            n_asp: usize) -> bool {
        let Some(s) = self.by.get_mut(&id) else { return false };
        let Some((pack, read)) = s.pack.as_ref() else { return false };
        if !s.buckets.contains_key(&bucket) {
            let Some(cal) = pack.cal(range) else { return false };
            let nan = vec![f32::NAN; n_asp];
            s.buckets.insert(bucket, Bucket { range, cal, read: *read, cells: Some([nan.clone(), nan.clone(), nan]) });
        }
        let b = s.buckets.get_mut(&bucket).unwrap();
        let Some(row) = b.cells.as_mut() else { return true };
        let (known, _) = fill_cells(pm, row, b.range, b.cal, b.read, pack, step_deg, &[a as i32]);
        if !known {
            b.cells = None;
        }
        true
    }

    /// Both kinds' rows of (id, bucket) as kind_rows gives them.
    pub(crate) fn pair(&self, id: i64, bucket: i32, kinds: [usize; 2]) -> Option<[Vec<f32>; 2]> {
        let b = self.by.get(&id)?.buckets.get(&bucket)?;
        Some(kinds.map(|k| b.cells.as_ref().map_or_else(Vec::new, |c| c[k.min(2)].clone())))
    }

    /// None: bucket absent; Some(None): unknown.
    pub(crate) fn get(&self, id: i64, bucket: i32, kind: usize) -> Option<Option<&[f32]>> {
        let b = self.by.get(&id)?.buckets.get(&bucket)?;
        Some(b.cells.as_ref().map(|k| k[kind.min(2)].as_slice()))
    }

    /// Per shooter index (`ids` order), bucket -> `kind` row; empty for unknown.
    pub(crate) fn kind_rows(&self, ids: &[i64], kind: usize) -> HashMap<(usize, i32), Vec<f32>> {
        let mut out = HashMap::new();
        for (i, id) in ids.iter().enumerate() {
            let Some(s) = self.by.get(id) else { continue };
            for (&b, r) in &s.buckets {
                out.insert((i, b), r.cells.as_ref().map_or_else(Vec::new, |k| k[kind.min(2)].clone()));
            }
        }
        out
    }
}
