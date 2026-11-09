use godot::prelude::*;

use super::point_store::PtTable;
use super::ProjectileManager;
use crate::projectile::damage_model::DamageModel;
use crate::variant_cast::VariantCast;

const SHELL_UNKNOWN: i64 = -1;
const SHELL_AP: i64 = 0;
/// Citadel damage counts this much extra.
const CITADEL_W: f64 = 1.0;

/// The fields of SkillStance._effective_of's answer it reads; absent ones at its defaults.
#[derive(Clone, Copy)]
struct Ev {
    ap_ev: f64,
    ap_dps: f64,
    he_dps: f64,
    ap_pure: f64,
    ap_cit: f64,
    he_cit: f64,
    ap_landed: f64,
    he_landed: f64,
}

struct Pack {
    shooter: i64,
    hull: i64,
    model: Option<Gd<DamageModel>>,
    alpha_ap: f64,
    alpha_he: f64,
    rate: f64,
    guns: i64,
    max_range: f64,
    keys: PackedStringArray,
    q: [PackedFloat64Array; 2],
    w: [PackedFloat32Array; 2],
    fires: Vec<(Vector3, bool)>,
    ap_size: f64,
    he_size: f64,
    fire_chance: f64,
}

impl Pack {
    fn read(d: &VarDictionary) -> Pack {
        let f = |k: &str| d.get(k).map(|v| v.to_f64()).unwrap_or(0.0);
        let fires: PackedFloat32Array = d.get("fires").and_then(|v| v.try_to().ok()).unwrap_or_default();
        Pack {
            shooter: d.get("shooter").map(|v| v.to_i64()).unwrap_or(0),
            hull: d.get("hull").map(|v| v.to_i64()).unwrap_or(0),
            model: d.get("model").and_then(|v| v.try_to::<Gd<DamageModel>>().ok()),
            alpha_ap: f("alpha_ap"),
            alpha_he: f("alpha_he"),
            rate: d.get("rate").map(|v| v.to_f64()).unwrap_or(-1.0),
            guns: d.get("guns").map(|v| v.to_i64()).unwrap_or(0),
            max_range: f("max_range"),
            keys: d.get("keys").and_then(|v| v.try_to().ok()).unwrap_or_default(),
            q: [d.get("q0").and_then(|v| v.try_to().ok()).unwrap_or_default(),
                d.get("q1").and_then(|v| v.try_to().ok()).unwrap_or_default()],
            w: [d.get("w0").and_then(|v| v.try_to().ok()).unwrap_or_default(),
                d.get("w1").and_then(|v| v.try_to().ok()).unwrap_or_default()],
            fires: fires.as_slice().chunks_exact(4).map(|c| (Vector3::new(c[0], c[1], c[2]), c[3] > 0.5)).collect(),
            ap_size: f("ap_size"),
            he_size: f("he_size"),
            fire_chance: f("fire_chance"),
        }
    }
}

fn salvo_fire_share(shells: i64, landed: f64, chance: f64) -> f64 {
    let k = shells as f64 * landed * chance;
    if k > 0.0 { k.min(1.0) / k } else { 1.0 }
}

/// BotGunnery.expected_points_pairs at one range: per aspect the AP and HE answers, None where unanswered.
fn points(pm: &ProjectileManager, p: &Pack, range: f64, aspects: &[f64], notes: &mut Vec<i32>)
        -> Vec<Option<Ev>> {
    let n = aspects.len();
    let mut out: Vec<Option<Ev>> = (0..n).map(|_| None).collect();
    if p.rate < 0.0 || p.max_range < range || p.keys.is_empty() {
        return out;
    }
    let mut rows: Vec<Vec<Option<(f64, f64, f64)>>> = Vec::with_capacity(2);
    for ammo in 0..2 {
        let key = p.keys.get(ammo).map(|k| k.to_string()).unwrap_or_default();
        let t = if key.is_empty() { None } else { pm.point_store.read().unwrap().get(&key).cloned() };
        if key.is_empty() {
            notes.extend_from_slice(&[0, 0]);
            return out;
        }
        let r = t.map(|t| best_row(&t.read().unwrap(), p, ammo, range, aspects)).unwrap_or_else(|| vec![None; n]);
        let served = r.iter().filter(|x| x.is_some()).count() as i32;
        notes.extend_from_slice(&[served, r.first().map(|x| x.is_some() as i32).unwrap_or(0)]);
        rows.push(r);
    }
    for i in 0..n {
        let (Some(a), Some(h)) = (rows[0][i], rows[1][i]) else { continue };
        let ap_ev = a.1 * p.ap_size;
        let he_fire = (h.0 - h.1) * salvo_fire_share(p.guns, h.2, p.fire_chance);
        let he_ev = h.1 * p.he_size + he_fire;
        out[i] = Some(Ev { ap_ev, ap_dps: ap_ev * p.rate, he_dps: he_ev * p.rate, ap_pure: ap_ev * p.rate, ap_cit: 0.0,
            he_cit: 0.0, ap_landed: a.2, he_landed: h.2 });
    }
    out
}

/// (value, damage, landed) per aspect, as point_best_pairs reports them.
fn best_row(g: &PtTable, p: &Pack, ammo: usize, range: f64, aspects: &[f64]) -> Vec<Option<(f64, f64, f64)>> {
    let q = &p.q[ammo];
    let w = &p.w[ammo];
    if q.len() < 5 || w.len() < g.n_comp {
        return vec![None; aspects.len()];
    }
    aspects.iter().map(|&a| g.best(range, a, w.as_slice(), q[2], q[3], q[4], &p.fires)
        .map(|b| (b.value as f32 as f64, b.damage as f32 as f64, b.landed as f32 as f64))).collect()
}

fn baked(p: &Pack, range: f64, aspect: f64) -> Option<Ev> {
    let m = p.model.as_ref()?;
    let e = m.bind().expected(p.shooter, p.hull, range as f32, aspect as f32)?;
    Some(Ev { ap_ev: e.ap_ev as f64, ap_dps: e.ap_dps as f64, he_dps: e.he_dps as f64, ap_pure: e.ap_pure_dps as f64,
        ap_cit: e.ap_cit as f64, he_cit: e.he_cit as f64, ap_landed: e.ap_landed as f64, he_landed: e.he_landed as f64 })
}

/// SkillStance._effective_of: (dps, raw dps, damage per hit over alpha).
fn effective(e: &Ev, p: &Pack, read: i64) -> (f64, f64, f64) {
    let ap = e.ap_pure * (1.0 + CITADEL_W * e.ap_cit);
    let he = e.he_dps * (1.0 + CITADEL_W * e.he_cit);
    let rate = e.ap_dps / e.ap_ev.max(1e-6);
    if read == SHELL_AP || (read == SHELL_UNKNOWN && ap >= he) {
        return (ap, e.ap_pure, e.ap_pure / rate / e.ap_landed.max(0.01) / p.alpha_ap.max(1.0));
    }
    (he, e.he_dps, e.he_dps / rate / e.he_landed.max(0.01) / p.alpha_he.max(1.0))
}

/// SkillStance._fill_cells: fills the NAN `cells` of entry `e` ([row, raw, hit, range, cal, read]), emptying all three
/// once one is unknown. Returns the point-query notes: [cells asked, then per shell asked: served, first served].
pub(super) fn fill(pm: &ProjectileManager, e: &mut VarArray, cells: &PackedInt32Array, pack: &VarDictionary,
        step_deg: f64) -> PackedInt32Array {
    let mut notes = Vec::new();
    let mut row: PackedFloat32Array = e.get(0).and_then(|v| v.try_to().ok()).unwrap_or_default();
    if row.is_empty() {
        return PackedInt32Array::new();
    }
    let mut want: Vec<usize> = Vec::new();
    for &a in cells.as_slice() {
        let a = a as usize;
        if a < row.len() && row[a].is_nan() && !want.contains(&a) {
            want.push(a);
        }
    }
    if want.is_empty() {
        return PackedInt32Array::new();
    }
    let mut raw: PackedFloat32Array = e.get(1).and_then(|v| v.try_to().ok()).unwrap_or_default();
    let mut hit: PackedFloat32Array = e.get(2).and_then(|v| v.try_to().ok()).unwrap_or_default();
    let range = e.get(3).map(|v| v.to_f64()).unwrap_or(0.0);
    let cal = e.get(4).map(|v| v.to_f64()).unwrap_or(0.0);
    let read = e.get(5).map(|v| v.to_i64()).unwrap_or(SHELL_UNKNOWN);
    let p = Pack::read(pack);
    let aspects: Vec<f64> = want.iter().map(|&a| a as f64 * step_deg).collect();
    let pts = points(pm, &p, range, &aspects, &mut notes);
    if !notes.is_empty() {
        notes.insert(0, want.len() as i32);
    }
    let notes = PackedInt32Array::from(notes.as_slice());
    for (j, &a) in want.iter().enumerate() {
        let ev = pts[j].or_else(|| baked(&p, range, aspects[j]));
        let Some(ev) = ev else {
            e.set(0, &PackedFloat32Array::new().to_variant());
            e.set(1, &PackedFloat32Array::new().to_variant());
            e.set(2, &PackedFloat32Array::new().to_variant());
            return notes;
        };
        let x = effective(&ev, &p, read);
        row[a] = (x.0 as f32 as f64 * cal) as f32;
        raw[a] = (x.1 as f32 as f64 * cal) as f32;
        hit[a] = (x.2 as f32 as f64 * cal) as f32;
    }
    e.set(0, &row.to_variant());
    e.set(1, &raw.to_variant());
    e.set(2, &hit.to_variant());
    notes
}
