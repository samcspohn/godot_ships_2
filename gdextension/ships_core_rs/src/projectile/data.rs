use godot::prelude::*;
use godot::classes::Resource;

/// Per-shell state for an in-flight projectile.
///
/// Every field below is registered as a Godot PROPERTY by the C++
/// (`ADD_PROPERTY`), so GDScript reaches the setters as `projectile.position = x`
/// rather than by calling `set_position()`. They are all live API even though a
/// grep for `.set_position(` finds nothing.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ProjectileData {
    base: Base<RefCounted>,
    #[var(get = get_position, set = set_position)]
    pub(crate) position: Vector3,
    #[var(get = get_start_position, set = set_start_position)]
    pub(crate) start_position: Vector3,
    #[var(get = get_start_time, set = set_start_time)]
    pub(crate) start_time: f64,
    #[var(get = get_launch_velocity, set = set_launch_velocity)]
    pub(crate) launch_velocity: Vector3,
    /// ShellParams resource.
    #[var(get = get_params, set = set_params)]
    pub(crate) params: Option<Gd<Resource>>,
    #[var(get = get_trail_pos, set = set_trail_pos)]
    pub(crate) trail_pos: Vector3,
    /// Ship reference.
    #[var(get = get_owner, set = set_owner)]
    pub(crate) owner: Option<Gd<Object>>,
    #[var(get = get_frame_count, set = set_frame_count)]
    pub(crate) frame_count: i32,
    /// Ships to exclude from collision.
    #[var(get = get_exclude, set = set_exclude)]
    pub(crate) exclude: VarArray,
    // C++ constructor sets `emitter_id = -1` explicitly (not the zero the
    // derived `init` would otherwise produce), so it needs an explicit default.
    #[init(val = -1)]
    #[var(get = get_emitter_id, set = set_emitter_id)]
    pub(crate) emitter_id: i32,
    #[var(get = get_shell_uid, set = set_shell_uid)]
    pub(crate) shell_uid: u32,
}

#[godot_api]
impl ProjectileData {
    /// The C++ default `_exclude = Array()` is only used by an internal C++
    /// caller, which becomes a direct Rust call; every GDScript caller passes
    /// all six arguments, so the binding needs no default.
    #[func]
    pub(crate) fn initialize(&mut self, pos: Vector3, vel: Vector3, t: f64, p: Gd<Resource>, owner: Option<Gd<Object>>, exclude: VarArray) {
        self.position = pos;
        self.start_position = pos;
        self.trail_pos = pos + vel.normalized() * 25.0;
        self.params = Some(p);
        self.start_time = t;
        self.launch_velocity = vel;
        self.owner = owner;
        self.frame_count = 0;
        self.exclude = exclude;
        self.emitter_id = -1;
        self.shell_uid = 0;
    }

    #[func] pub(crate) fn get_position(&self) -> Vector3 { self.position }
    #[func] pub(crate) fn get_start_position(&self) -> Vector3 { self.start_position }
    #[func] pub(crate) fn get_start_time(&self) -> f64 { self.start_time }
    #[func] pub(crate) fn get_launch_velocity(&self) -> Vector3 { self.launch_velocity }
    #[func] pub(crate) fn get_params(&self) -> Option<Gd<Resource>> { self.params.clone() }
    #[func] pub(crate) fn get_trail_pos(&self) -> Vector3 { self.trail_pos }
    #[func] pub(crate) fn get_owner(&self) -> Option<Gd<Object>> { self.owner.clone() }
    #[func] pub(crate) fn get_frame_count(&self) -> i32 { self.frame_count }
    #[func] pub(crate) fn get_exclude(&self) -> VarArray { self.exclude.clone() }
    #[func] pub(crate) fn get_emitter_id(&self) -> i32 { self.emitter_id }
    #[func] pub(crate) fn get_shell_uid(&self) -> u32 { self.shell_uid }

    #[func] pub(crate) fn set_position(&mut self, v: Vector3) { self.position = v; }
    #[func] pub(crate) fn set_start_position(&mut self, v: Vector3) { self.start_position = v; }
    #[func] pub(crate) fn set_start_time(&mut self, v: f64) { self.start_time = v; }
    #[func] pub(crate) fn set_launch_velocity(&mut self, v: Vector3) { self.launch_velocity = v; }
    #[func] pub(crate) fn set_params(&mut self, v: Option<Gd<Resource>>) { self.params = v; }
    #[func] pub(crate) fn set_trail_pos(&mut self, v: Vector3) { self.trail_pos = v; }
    #[func] pub(crate) fn set_owner(&mut self, v: Option<Gd<Object>>) { self.owner = v; }
    #[func] pub(crate) fn set_frame_count(&mut self, v: i32) { self.frame_count = v; }
    #[func] pub(crate) fn set_exclude(&mut self, v: VarArray) { self.exclude = v; }
    #[func] pub(crate) fn set_emitter_id(&mut self, v: i32) { self.emitter_id = v; }
    #[func] pub(crate) fn set_shell_uid(&mut self, v: u32) { self.shell_uid = v; }

    #[func] pub(crate) fn increment_frame_count(&mut self) { self.frame_count += 1; }
}

/// Shell-specific data storage. Like ProjectileData, every field is registered
/// as a Godot property via ADD_PROPERTY, so all six get/set pairs are live API
/// reachable as `shell.velocity = v` even though nothing calls `set_velocity()`
/// by name.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ShellData {
    base: Base<RefCounted>,
    #[var(get = get_params, set = set_params)]
    pub(crate) params: Option<Gd<Resource>>,
    #[var(get = get_velocity, set = set_velocity)]
    pub(crate) velocity: Vector3,
    #[var(get = get_position, set = set_position)]
    pub(crate) position: Vector3,
    #[var(get = get_end_position, set = set_end_position)]
    pub(crate) end_position: Vector3,
    #[var(get = get_fuse, set = set_fuse)]
    pub(crate) fuse: f64,
    #[var(get = get_hit_result, set = set_hit_result)]
    pub(crate) hit_result: i32,
}

#[godot_api]
impl ShellData {
    #[func] pub(crate) fn get_params(&self) -> Option<Gd<Resource>> { self.params.clone() }
    #[func] pub(crate) fn get_velocity(&self) -> Vector3 { self.velocity }
    #[func] pub(crate) fn get_position(&self) -> Vector3 { self.position }
    #[func] pub(crate) fn get_end_position(&self) -> Vector3 { self.end_position }
    #[func] pub(crate) fn get_fuse(&self) -> f64 { self.fuse }
    #[func] pub(crate) fn get_hit_result(&self) -> i32 { self.hit_result }

    #[func] pub(crate) fn set_params(&mut self, v: Option<Gd<Resource>>) { self.params = v; }
    #[func] pub(crate) fn set_velocity(&mut self, v: Vector3) { self.velocity = v; }
    #[func] pub(crate) fn set_position(&mut self, v: Vector3) { self.position = v; }
    #[func] pub(crate) fn set_end_position(&mut self, v: Vector3) { self.end_position = v; }
    #[func] pub(crate) fn set_fuse(&mut self, v: f64) { self.fuse = v; }
    #[func] pub(crate) fn set_hit_result(&mut self, v: i32) { self.hit_result = v; }
}
