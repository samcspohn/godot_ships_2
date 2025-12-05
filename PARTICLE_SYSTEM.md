# Unified Particle System Architecture

## Overview

A GPU-accelerated, template-based particle system for Godot 4.x that consolidates all particle effects into a single `GPUParticles3D` node. Uses shader-based particle processing with texture atlases to encode particle templates, enabling thousands of particles with minimal CPU overhead.

**Key Features:**
- Single `GPUParticles3D` node handles all particle types (100,000 particle pool)
- Template-based system: define particle behavior once, reuse everywhere
- GPU-driven: compute shaders handle all particle physics/rendering
- Texture atlases encode templates (properties, color ramps, scale curves, velocity curves)
- Low CPU overhead: emit via `emit_particle()` API with encoded metadata

## Architecture Components

### 1. ParticleTemplate (`particle_template.gd`)
**Resource class** that defines a particle type's behavior and appearance.

**Key Properties:**
- **Appearance**: texture, color_over_life (gradient), scale_over_life (curve), emission color/energy
- **Motion**: velocity range, direction, spread angle, gravity
- **Physics**: damping, linear/radial/tangent acceleration
- **Lifetime**: min/max lifetime with randomness
- **Emission Shape**: point, sphere, or box
- **Angular Motion**: rotation speed and initial angle ranges

**Internal Field:**
- `template_id` (int): Assigned by `ParticleTemplateManager` (0-15)

**Usage:** Create `.tres` resource files, configure properties, register with manager.

### 2. ParticleTemplateManager (`particle_template_manager.gd`)
**Singleton** that registers templates and encodes them into GPU-readable textures.

**Responsibilities:**
- Register up to 16 templates (MAX_TEMPLATES constant)
- Assign unique template IDs (0-15)
- Encode templates into texture atlases:
  - **template_properties_texture**: RGBAF texture (16×8 pixels) - scalar properties per template
  - **color_ramp_atlas**: RGBA8 texture (256×16) - color gradients over lifetime
  - **scale_curve_atlas**: RF texture (256×16) - scale curves over lifetime
  - **velocity_curve_atlas**: RGBF texture (256×16) - velocity modifiers over lifetime
  - **texture_array**: Texture2DArray - visual textures for each template

**Key Methods:**
- `register_template(template: ParticleTemplate) -> int`: Register and encode template
- `get_template_by_id(id: int) -> ParticleTemplate`
- `get_template_by_name(name: String) -> ParticleTemplate`
- `get_shader_uniforms() -> Dictionary`: Returns texture uniforms for shaders
- `build_texture_array() -> Texture2DArray`: Constructs texture array from registered templates

**Encoding Details:**
- Properties stored in 8 rows per template (velocity, damping, direction, gravity, etc.)
- Color/scale/velocity curves sampled at 256 points for smooth interpolation
- All data uploaded to GPU via shader uniforms

### 3. UnifiedParticleSystem (`unified_particle_system.gd`)
**Main GPUParticles3D node** - the single particle emitter for all effects.

**Configuration:**
- 100,000 particle pool
- 100s max lifetime
- Large visibility AABB (-100k to +100k on all axes)
- Fixed 30 FPS processing
- View depth draw order
- Y-to-velocity transform alignment

**Key Method:**
```gdscript
emit_particles(pos: Vector3, direction: Vector3, template_id: int, 
               size_multiplier: float, count: int, speed_mod: float)
```

**Emission Encoding:**
- Uses `emit_particle()` with metadata encoded in COLOR channel:
  - `COLOR.r` = template_id / 255.0 (normalized)
  - `COLOR.g` = size_multiplier (0-1, scales visual size and movement speed)
  - `COLOR.b` = speed_mod (time scale multiplier)
  - `COLOR.a` = unused (reserved)
- Direction passed via velocity parameter (shader calculates final velocity)
- Transform contains emission position

**Shaders:**
- Process material: `particle_template_process.gdshader`
- Draw material: `particle_template_material.gdshader`

### 4. ParticleEmitter (`particle_emitter.gd`)
**Optional Node3D helper** for spawning particles at a specific location.

**Properties:**
- `template`: Reference to ParticleTemplate
- `auto_emit`: Emit on ready
- `one_shot`: Single burst vs continuous
- `emission_rate`: Particles per second (continuous mode)
- `emission_count`: Particles per burst
- `base_direction`: Emission direction (transformed by node's basis)
- `inherit_velocity`: Add emitter's movement velocity
- `size_multiplier`: Scale particles (with optional variation)

**Methods:**
- `emit_particles(count: int, custom_direction: Vector3, custom_size: float)`
- `emit_burst(count: int, direction: Vector3, size: float)`
- `stop_emission()` / `restart_emission()`

**Use Case:** Place in scenes for level-specific effects (fire, smoke, ambient particles).

### 5. ParticleSystemInit (`particle_system_init.gd`)
**Autoload singleton** that initializes the system at startup.

**Responsibilities:**
1. Create `ParticleTemplateManager` singleton
2. Load template resources from `res://src/particles/templates/`
3. Register all templates
4. Create `UnifiedParticleSystem` node and add to scene tree
5. Provide convenience accessors

**Registered Templates (example):**
- `splash_template.tres` - Water splash effects
- `explosion_template.tres` - High-explosive detonations
- `sparks_template.tres` - Metal impact sparks
- `muzzle_blast_template.tres` - Gun muzzle flashes

**Methods:**
- `get_template_by_name(name: String) -> ParticleTemplate`
- `get_particle_system() -> UnifiedParticleSystem`

## Shader Pipeline

### Process Shader (`particle_template_process.gdshader`)
**Particle physics and lifecycle management** (runs on GPU per particle per frame).

**Uniforms:**
- `template_properties`, `color_ramp_atlas`, `scale_curve_atlas`, `velocity_curve_atlas`
- `max_templates` (16)

**start() Function:**
- Decode template_id and size_multiplier from COLOR
- Fetch template properties from texture (8 texelFetch calls)
- Initialize particle:
  - Random lifetime (from template range)
  - Initial position (with emission shape offset)
  - Initial velocity (direction × speed × spread)
  - Initial rotation angle
  - Initial scale (from template range)
- Store age/lifetime in CUSTOM channel:
  - `CUSTOM.x` = rotation angle (degrees)
  - `CUSTOM.y` = age (seconds)
  - `CUSTOM.z` = unused
  - `CUSTOM.w` = lifetime (seconds)

**process() Function:**
- Update age: `CUSTOM.y += DELTA * speed_scale`
- Calculate lifetime_percent (0.0 to 1.0)
- Deactivate if age >= lifetime
- Apply forces:
  - Gravity
  - Linear acceleration (along velocity)
  - Velocity curve modifiers (sampled from atlas)
  - Attractor forces
- Apply damping
- Update position: `TRANSFORM[3].xyz += VELOCITY * DELTA * size_multiplier`
- Update rotation (angular velocity)
- Align transform to velocity direction (billboard effect)
- Apply rotation around forward axis

**Optimization:** Particle is only active during its lifetime, then recycled by GPU.

### Material Shader (`particle_template_material.gdshader`)
**Visual rendering** (runs per pixel per particle).

**Uniforms:**
- `texture_atlas` (Texture2DArray) - particle textures
- `color_ramp_atlas` - color gradients

**vertex() Function:**
- Decode template_id from COLOR.r
- Calculate lifetime_percent from INSTANCE_CUSTOM
- Manual billboarding:
  - Extract camera right/up vectors from INV_VIEW_MATRIX
  - Build billboard matrix preserving scale
  - Apply size_multiplier from COLOR.g

**fragment() Function:**
- Sample texture from array: `texture(texture_atlas, vec3(UV, template_id))`
- Sample color ramp: `texture(color_ramp_atlas, vec2(lifetime_percent, v_coord))`
- Multiply texture × color ramp
- Apply fade-out at end of life (95-100% lifetime)
- Optional alpha scissor for performance

## Usage Patterns

### Pattern 1: Direct Emission (High Performance)
**Use when:** Need maximum control, emitting from game logic.

```gdscript
var particle_system: UnifiedParticleSystem = get_node("/root/UnifiedParticleSystem")
var template = get_node("/root/ParticleSystemInit").get_template_by_name("explosion")

# Emit 50 particles with size 2.0, speed 1.0
particle_system.emit_particles(
    Vector3(0, 10, 0),      # position
    Vector3(0, 1, 0),       # direction
    template.template_id,   # template ID
    2.0,                    # size multiplier
    50,                     # particle count
    1.0                     # speed modifier
)
```

### Pattern 2: ParticleEmitter Nodes (Scene Integration)
**Use when:** Effects tied to scene locations (torches, vents, ambient).

```gdscript
# In scene editor: add ParticleEmitter node
# - Assign template resource
# - Set auto_emit = true
# - Configure emission_rate / emission_count
# - Position node where particles should spawn

# Runtime control:
var emitter = $ParticleEmitter
emitter.emit_burst(20, Vector3.UP, 1.5)
emitter.stop_emission()
```

### Pattern 3: Effect System Integration (Current Implementation)
**Use when:** Centralized effect management (hit effects, muzzle blasts).

See: `src/artillary/HitEffects/hit_effects.gd`

```gdscript
class_name HitEffects_

var _particle_system: UnifiedParticleSystem
var _templates: Dictionary  # cached templates

func splash_effect(pos: Vector3, size: float):
    var template = _templates[EffectType.SPLASH]
    var count = int(SPLASH_PARTICLES)
    var direction = Vector3(0, 1, 0)
    _particle_system.emit_particles(pos, direction, template.template_id, size, count, 4.0 / size)
```

## Creating New Particle Templates

### Step 1: Create Template Resource
```gdscript
# In Godot Editor:
# 1. Create new ParticleTemplate resource (.tres file)
# 2. Configure properties in inspector:
#    - Load texture image
#    - Set up color gradient (GradientTexture1D)
#    - Configure scale curve (CurveTexture)
#    - Set velocity ranges, spread, lifetime, etc.
# 3. Save to res://src/particles/templates/my_template.tres
```

### Step 2: Register in ParticleSystemInit
```gdscript
# In particle_system_init.gd:
var my_template: ParticleTemplate

func _load_templates():
    # ... existing templates ...
    
    my_template = load("res://src/particles/templates/my_template.tres")
    if my_template:
        template_manager.register_template(my_template)
    else:
        push_error("Failed to load my_template")
```

### Step 3: Use in Game Code
```gdscript
var template = get_node("/root/ParticleSystemInit").get_template_by_name("my_template_name")
particle_system.emit_particles(position, direction, template.template_id, 1.0, 10, 1.0)
```

## Performance Characteristics

### Advantages
- **GPU-Driven**: All physics on GPU, minimal CPU usage
- **Single Draw Call**: All particles in one GPUParticles3D node
- **Template Reuse**: No duplicate particle system nodes
- **Efficient Encoding**: Texture atlases provide fast GPU lookups
- **Dynamic Scaling**: size_multiplier allows per-emission variation without new templates

### Limitations
- **16 Template Maximum**: Hardcoded limit (expandable by increasing MAX_TEMPLATES and atlas sizes)
- **100k Particle Pool**: Fixed pool size (adjustable via `amount` property)
- **Memory**: All templates loaded at startup (not streaming)
- **Shader Complexity**: Harder to debug than simple ParticleProcessMaterial

### Optimization Tips
- Use `alpha_scissor` in material shader for transparent-heavy effects
- Reduce `emission_count` for distant/less important effects
- Use `speed_mod` to make effects faster (shorter lifetime) under load
- Pool management: restart() clears all particles if needed

## Migration from Legacy System

**Old System:** Individual `GPUParticles3D` nodes per effect type, object pooling.

**New System:** Single unified particle system with templates.

**Benefits:**
- No pool management overhead
- No node instantiation/queuing
- Consistent performance regardless of effect count
- Easier effect authoring (edit resource, not nodes)

**Deprecated:**
- `src/artillary/HitEffects/hit_effect.gd` (old class)
- Pool-based particle management
- Per-effect GPUParticles3D scenes

**Compatibility:** `HitEffects_` class maintains same API for backward compatibility.

## Debugging

### Common Issues

**"Template not found" error:**
- Ensure template is registered in `ParticleSystemInit._load_templates()`
- Check template_name matches in resource and lookup code
- Verify ParticleSystemInit is added as autoload

**Particles not appearing:**
- Check visibility_aabb (very large by default)
- Verify `emitting = true` on UnifiedParticleSystem
- Check particle lifetime > 0
- Ensure texture is assigned in template
- Verify camera can see emission position

**Performance issues:**
- Reduce particle count (100k pool is very large)
- Enable alpha_scissor
- Check for excessive emit_particles() calls
- Profile with Godot's profiler (GPU time)

### Useful Debug Commands
```gdscript
# Print registered templates
print(template_manager.next_template_id, " templates registered")

# Check particle system state
print("Emitting: ", unified_system.emitting)
print("Active particles: ", unified_system.get_active_particle_count())

# Restart particle system (clear all)
unified_system.restart()

# Update shader uniforms (after template changes)
unified_system.update_shader_uniforms()
```

## Future Enhancement Opportunities

### Template System
- Increase MAX_TEMPLATES (requires larger atlas textures)
- Add template inheritance/variants
- Runtime template creation
- Template LOD system

### Rendering
- Soft particles (depth fade)
- Collision detection (GPU-based)
- Mesh particles (use mesh instead of quad)
- Lighting integration (dynamic light response)

### Physics
- Wind zones
- Force fields
- Particle-particle interaction
- Constraint systems

### Performance
- Frustum culling per particle (GPU)
- Distance-based LOD (fewer particles far away)
- Occlusion culling
- Streaming templates (load on demand)

### Tooling
- Template preview in editor
- Visual particle editor plugin
- Effect timeline sequencer
- Particle analytics (count, memory usage)

## File Structure

```
src/particles/
├── unified_particle_system.gd          # Main particle system node
├── particle_template.gd                # Template resource class
├── particle_template_manager.gd        # Template registry/encoder
├── particle_emitter.gd                 # Helper emitter node
├── particle_system_init.gd             # Autoload initializer
├── UnifiedParticleSystem.tscn          # Scene file (optional)
├── shaders/
│   ├── particle_template_process.gdshader   # Physics shader
│   └── particle_template_material.gdshader  # Rendering shader
└── templates/
    ├── splash_template.tres
    ├── explosion_template.tres
    ├── sparks_template.tres
    └── muzzle_blast_template.tres
```

## Key Takeaways for AI Agents

1. **Single Particle System**: All particles go through `UnifiedParticleSystem` - never create separate GPUParticles3D nodes.

2. **Template-Based**: Define behavior in `ParticleTemplate` resources, register once, use everywhere.

3. **GPU Encoding**: Templates are baked into texture atlases at startup - modifications require re-encoding.

4. **Emission API**: `emit_particles(pos, dir, template_id, size, count, speed)` - this is the primary interface.

5. **Size Multiplier**: Controls both visual size AND movement speed - use for variation without new templates.

6. **16 Template Limit**: Current hard limit - can be increased but requires shader/texture changes.

7. **Shader Pipeline**: Process shader (physics) → Material shader (rendering) → both read from same atlases.

8. **Autoload Required**: `ParticleSystemInit` must be configured as autoload for system to work.

9. **Performance First**: System designed for thousands of particles - don't hesitate to emit aggressively.

10. **Legacy Compatibility**: Old `HitEffects` class wraps new system - prefer direct `emit_particles()` calls in new code.