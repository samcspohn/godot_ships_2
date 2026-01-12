# Ships Core GDExtension

A unified GDExtension library that combines projectile physics calculations and game systems functionality for the Godot Ships 2 project.

## Features

### Projectile Physics
- `ProjectilePhysics` - Basic projectile physics calculations without drag
- `ProjectilePhysicsWithDrag` - Advanced projectile physics with air resistance

### Game Systems
- `ProjectileData` - Data structure for projectile information
- `ShellData` - Shell-specific data storage
- `EmitterData` - Particle emitter data
- `EmissionRequest` - Particle emission request handling
- `EmitterInitRequest` - Emitter initialization requests
- `_ProjectileManager` - Central projectile management system
- `ComputeParticleSystem` - GPU-accelerated particle system using compute shaders

## Building

```bash
cd gdextension/ships_core
scons platform=linux target=editor
scons platform=linux target=template_debug
scons platform=linux target=template_release
```

Replace `linux` with your target platform (`windows`, `macos`, etc.).

## Dependencies

- godot-cpp (located at `../godot-cpp`)