use godot::prelude::*;

use super::{Cluster, HpaGraph, HpaObstacle, SubCluster, DEFAULT_CLUSTER_SIZE, DEFAULT_SUB_SIZE};
use crate::nav::map::NavigationMap;

impl HpaGraph {
    pub(crate) fn build_impl(&mut self, map: Gd<NavigationMap>, clearance: f32, cluster_size: i32) {
        self.built = false;
        self.clusters.clear();
        self.sub_clusters.clear();
        self.cluster_block_count.clear();
        self.cluster_threat_blocked.clear();
        self.threat_blocked_cids.clear();
        self.threat_blocked_count = 0;
        self.obstacles.clear();

        // `map.is_valid()` has no Rust equivalent — `Gd<NavigationMap>` is always a
        // valid reference once constructed, so only the `is_built()` check applies.
        if !map.bind().built {
            godot_print!("[HpaGraph] build: NavigationMap is not built");
            return;
        }

        self.clearance = clearance;
        self.cluster_size = if cluster_size > 0 {
            cluster_size
        } else {
            DEFAULT_CLUSTER_SIZE
        };
        {
            let m = map.bind();
            self.grid_w = m.grid_width;
            self.grid_h = m.grid_height;
            self.cell_size = m.cell_size;
            self.min_x = m.min_x;
            self.min_z = m.min_z;
        }
        self.nav_map = Some(map);

        self.ncx = (self.grid_w + self.cluster_size - 1) / self.cluster_size;
        self.ncz = (self.grid_h + self.cluster_size - 1) / self.cluster_size;

        // Sub-cluster sizing: keep sub_size tied to the default ratio. Require
        // cluster_size to be a positive integer multiple of sub_size so each
        // macro contains a whole number of subs and indexing stays trivial.
        self.sub_size = DEFAULT_SUB_SIZE;
        if self.sub_size <= 0 || self.cluster_size % self.sub_size != 0 {
            godot_print!(
                "[HpaGraph] build: cluster_size ({}) must be a positive multiple of sub_size ({}) — aborting build",
                self.cluster_size,
                self.sub_size
            );
            return;
        }
        self.subs_per_macro_side = self.cluster_size / self.sub_size;
        self.nsubx = self.ncx * self.subs_per_macro_side;
        self.nsubz = self.ncz * self.subs_per_macro_side;

        // Constant cluster A* step costs: every neighbour edge in the cluster
        // grid is exactly one cluster wide (cardinal) or one cluster diagonal.
        // No need to recompute sqrt for every expansion.
        self.cardinal_step_cost = self.cluster_size as f32 * self.cell_size;
        self.diagonal_step_cost = self.cardinal_step_cost * 1.41421356237f32;

        godot_print!(
            "[HpaGraph] building {}x{} clusters ({} cells each) and {}x{} sub-clusters ({} cells each) on grid {}x{}",
            self.ncx,
            self.ncz,
            self.cluster_size,
            self.nsubx,
            self.nsubz,
            self.sub_size,
            self.grid_w,
            self.grid_h
        );

        self.build_clusters();
        self.build_sub_clusters();

        let navigable_count = self.clusters.iter().filter(|c| c.navigable).count() as i32;
        let sub_navigable_count = self.sub_clusters.iter().filter(|s| s.navigable).count() as i32;

        godot_print!(
            "[HpaGraph] built: {} clusters ({} navigable), {} sub-clusters ({} navigable)",
            self.clusters.len() as i32,
            navigable_count,
            self.sub_clusters.len() as i32,
            sub_navigable_count
        );

        self.built = true;
    }

    pub(crate) fn build_clusters(&mut self) {
        let total = (self.ncx * self.ncz) as usize;
        self.clusters = vec![Cluster::default(); total];
        self.cluster_block_count = vec![0; total];
        self.cluster_threat_blocked = vec![0; total];

        const NEG_INF: f32 = f32::NEG_INFINITY;
        const POS_INF: f32 = f32::INFINITY;

        let map = self.nav_map.as_ref().unwrap().clone();
        let map = map.bind();

        for cz in 0..self.ncz {
            for cx in 0..self.ncx {
                let id = self.cluster_id(cx, cz);
                let x0 = cx * self.cluster_size;
                let z0 = cz * self.cluster_size;
                let x1 = (x0 + self.cluster_size - 1).min(self.grid_w - 1);
                let z1 = (z0 + self.cluster_size - 1).min(self.grid_h - 1);

                // Macro→sub range (always a full subs_per_macro_side × ... block;
                // out-of-grid subs are clamped/marked impassable in build_sub_clusters).
                let sub_x0 = cx * self.subs_per_macro_side;
                let sub_z0 = cz * self.subs_per_macro_side;
                let sub_x1 = sub_x0 + self.subs_per_macro_side - 1;
                let sub_z1 = sub_z0 + self.subs_per_macro_side - 1;

                // Cluster centre (world coords of the middle cell).
                let (wx_center, wz_center) = self.grid_to_world((x0 + x1) / 2, (z0 + z1) / 2);

                // Full SDF scan for max_sdf, min_sdf and how much of the cluster is
                // actually water. nav_frac is measured at the *build* clearance,
                // not per query: it ranks clusters by openness for cost shaping,
                // and that ordering barely moves with query clearance.
                let mut max_sdf = NEG_INF;
                let mut min_sdf = POS_INF;
                let mut nav_cells: i32 = 0;
                let mut tot_cells: i32 = 0;
                for gz in z0..=z1 {
                    for gx in x0..=x1 {
                        let (wx, wz) = self.grid_to_world(gx, gz);
                        let sdf = map.get_distance_impl(wx, wz);
                        if sdf > max_sdf {
                            max_sdf = sdf;
                        }
                        if sdf < min_sdf {
                            min_sdf = sdf;
                        }
                        if sdf >= self.clearance {
                            nav_cells += 1;
                        }
                        tot_cells += 1;
                    }
                }
                let nav_frac = if tot_cells > 0 {
                    nav_cells as f32 / tot_cells as f32
                } else {
                    0.0
                };

                self.clusters[id as usize] = Cluster {
                    id,
                    cx,
                    cz,
                    x0,
                    z0,
                    x1,
                    z1,
                    sub_x0,
                    sub_z0,
                    sub_x1,
                    sub_z1,
                    max_sdf,
                    min_sdf,
                    nav_frac,
                    wx_center,
                    wz_center,
                    navigable: max_sdf >= self.clearance,
                };
            }
        }
    }

    pub(crate) fn build_sub_clusters(&mut self) {
        let total = (self.nsubx * self.nsubz) as usize;
        self.sub_clusters = vec![SubCluster::default(); total];

        const NEG_INF: f32 = f32::NEG_INFINITY;
        const POS_INF: f32 = f32::INFINITY;

        let map = self.nav_map.as_ref().unwrap().clone();
        let map = map.bind();

        for scz in 0..self.nsubz {
            for scx in 0..self.nsubx {
                let sid = self.sub_id(scx, scz);

                // Parent macro.
                let parent_cx = scx / self.subs_per_macro_side;
                let parent_cz = scz / self.subs_per_macro_side;
                let parent_cid = self.cluster_id(parent_cx, parent_cz);

                // Cell range in the underlying SDF grid.
                let x0 = scx * self.sub_size;
                let z0 = scz * self.sub_size;
                let x1 = x0 + self.sub_size - 1;
                let z1 = z0 + self.sub_size - 1;

                // Wholly outside the cell grid — mark impassable, no SDF scan.
                if x0 >= self.grid_w || z0 >= self.grid_h {
                    // Centre still computed for debug/visualisation.
                    let (wx_center, wz_center) = self.grid_to_world((x0 + x1) / 2, (z0 + z1) / 2);
                    self.sub_clusters[sid as usize] = SubCluster {
                        id: sid,
                        parent_cid,
                        scx,
                        scz,
                        x0,
                        z0,
                        x1,
                        z1,
                        max_sdf: NEG_INF,
                        min_sdf: NEG_INF,
                        nav_frac: 0.0,
                        wx_center,
                        wz_center,
                        navigable: false,
                    };
                    continue;
                }

                // Clamp to cell grid (last column/row of subs may be partial).
                let cx1 = x1.min(self.grid_w - 1);
                let cz1 = z1.min(self.grid_h - 1);

                let (wx_center, wz_center) = self.grid_to_world((x0 + cx1) / 2, (z0 + cz1) / 2);

                let mut max_sdf = NEG_INF;
                let mut min_sdf = POS_INF;
                let mut nav_cells: i32 = 0;
                let mut tot_cells: i32 = 0;
                for gz in z0..=cz1 {
                    for gx in x0..=cx1 {
                        let (wx, wz) = self.grid_to_world(gx, gz);
                        let sdf = map.get_distance_impl(wx, wz);
                        if sdf > max_sdf {
                            max_sdf = sdf;
                        }
                        if sdf < min_sdf {
                            min_sdf = sdf;
                        }
                        if sdf >= self.clearance {
                            nav_cells += 1;
                        }
                        tot_cells += 1;
                    }
                }
                let nav_frac = if tot_cells > 0 {
                    nav_cells as f32 / tot_cells as f32
                } else {
                    0.0
                };

                self.sub_clusters[sid as usize] = SubCluster {
                    id: sid,
                    parent_cid,
                    scx,
                    scz,
                    x0,
                    z0,
                    x1: cx1,
                    z1: cz1,
                    max_sdf,
                    min_sdf,
                    nav_frac,
                    wx_center,
                    wz_center,
                    navigable: max_sdf >= self.clearance,
                };
            }
        }
    }

    /// All cluster ids whose AABB overlaps the circle (pos, radius).
    pub(crate) fn clusters_in_radius(&self, pos: Vector2, radius: f32) -> Vec<i32> {
        let mut result = Vec::new();
        if self.clusters.is_empty() {
            return result;
        }

        let wx0 = pos.x - radius;
        let wx1 = pos.x + radius;
        let wz0 = pos.y - radius;
        let wz1 = pos.y + radius;

        let cluster_world = self.cluster_size as f32 * self.cell_size;

        let cx0 = ((wx0 - self.min_x) / cluster_world) as i32;
        let cx1 = ((wx1 - self.min_x) / cluster_world) as i32;
        let cz0 = ((wz0 - self.min_z) / cluster_world) as i32;
        let cz1 = ((wz1 - self.min_z) / cluster_world) as i32;

        let cx0 = cx0.max(0);
        let cx1 = cx1.min(self.ncx - 1);
        let cz0 = cz0.max(0);
        let cz1 = cz1.min(self.ncz - 1);

        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                result.push(self.cluster_id(cx, cz));
            }
        }
        result
    }

    pub(crate) fn add_obstacle_impl(&mut self, id: i32, pos: Vector2, radius: f32) {
        self.remove_obstacle_impl(id);
        let obs = HpaObstacle { id, pos, radius };
        let cids = self.clusters_in_radius(pos, radius);
        for cid in cids {
            self.cluster_block_count[cid as usize] += 1;
        }
        self.obstacles.insert(id, obs);
    }

    pub(crate) fn remove_obstacle_impl(&mut self, id: i32) {
        let obs = match self.obstacles.get(&id) {
            Some(o) => *o,
            None => return,
        };
        let cids = self.clusters_in_radius(obs.pos, obs.radius);
        for cid in cids {
            if cid >= 0 && (cid as usize) < self.cluster_block_count.len() {
                self.cluster_block_count[cid as usize] =
                    (self.cluster_block_count[cid as usize] - 1).max(0);
            }
        }
        self.obstacles.remove(&id);
    }

    pub(crate) fn clear_obstacles_impl(&mut self) {
        for c in self.cluster_block_count.iter_mut() {
            *c = 0;
        }
        self.obstacles.clear();
    }
}
