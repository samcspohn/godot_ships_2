use godot::prelude::*;

/// Each enemy's forecast positions (EnemyForecast): `t.len()` samples per enemy, enemy-major.
#[derive(Clone, Default)]
pub(crate) struct Forecast {
    pub pos: Vec<Vector2>,
    pub t: Vec<f32>,
    /// A station must hold this long after we reach it.
    pub hold_s: f32,
    pub from: Vector2,
    pub speed: f32,
    /// Metres of water route from `from` per grid water cell (INF unreached); empty for straight lines.
    pub route: Vec<f32>,
}

impl Forecast {
    pub(crate) fn from_opts(o: &VarDictionary) -> Self {
        Self {
            pos: o.get("fc").and_then(|v| v.try_to::<PackedVector2Array>().ok()).map_or(Vec::new(), |a| a.to_vec()),
            t: o.get("fc_t").and_then(|v| v.try_to::<PackedFloat32Array>().ok()).map_or(Vec::new(), |a| a.to_vec()),
            hold_s: o.get("fc_hold_s").map_or(0.0, |v| v.to::<f32>()),
            from: o.get("from").and_then(|v| v.try_to::<Vector2>().ok()).unwrap_or(Vector2::INF),
            speed: o.get("speed").map_or(0.0, |v| v.to::<f32>()),
            route: Vec::new(),
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.t.is_empty() || self.pos.is_empty() || !self.from.is_finite() || self.speed <= 0.0
    }

    /// Enemy `i` `s` seconds from now; None for an enemy the forecast does not cover.
    pub(crate) fn at(&self, i: usize, s: f32) -> Option<Vector2> {
        let n = self.t.len();
        let row = self.pos.get(i * n..(i + 1) * n)?;
        let j = self.t.partition_point(|&x| x <= s);
        if j == 0 {
            return row.first().copied();
        }
        if j >= n {
            return row.last().copied();
        }
        let f = (s - self.t[j - 1]) / (self.t[j] - self.t[j - 1]).max(1e-3);
        Some(row[j - 1].lerp(row[j], f))
    }

    /// When we reach `p` (grid cell `k`, along `route` when it has one), then every sample until hold_s after.
    pub(crate) fn window_k(&self, k: usize, p: Vector2) -> Vec<f32> {
        let last = self.t.last().copied().unwrap_or(0.0);
        let d = self.route.get(k).copied().filter(|d| d.is_finite()).unwrap_or_else(|| self.from.distance_to(p));
        let eta = (d / self.speed).min(last);
        let end = eta + self.hold_s;
        let mut w = vec![eta];
        w.extend(self.t.iter().copied().filter(|&s| s > eta && s < end));
        if end > eta {
            w.push(end);
        }
        w
    }

    pub(crate) fn window(&self, p: Vector2) -> Vec<f32> {
        self.window_k(usize::MAX, p)
    }

    pub(crate) fn eta(&self, p: Vector2) -> f32 {
        self.window(p)[0]
    }

    pub(crate) fn eta_k(&self, k: usize, p: Vector2) -> f32 {
        self.window_k(k, p)[0]
    }
}
