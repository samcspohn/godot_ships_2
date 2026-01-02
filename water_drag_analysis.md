# Water Drag Analysis

## Current Implementation

Your code uses a **linear drag model** with exponential decay:
```
v(t) = v₀ · e^(-β·t)
x(t) = (v₀/β) · (1 - e^(-β·t))
```

Where β is the drag coefficient.

## The Problem

### 1. Linear vs Quadratic Drag

At **high velocities** (820 m/s), drag is **quadratic** (F ∝ v²), not linear (F ∝ v).

- **Linear drag** (Stokes' drag): Valid only at low Reynolds numbers (Re < 1)
- **Quadratic drag**: Valid at high Reynolds numbers (Re > 1000)

For a 380mm shell at 820 m/s:
- Reynolds number Re ≈ (ρ·v·D)/μ ≈ (1.225 · 820 · 0.38) / (1.8×10^-5) ≈ 2.1×10^7

This is **extremely high**, so quadratic drag dominates.

### 2. Multiplying β by 800

When you multiply β by 800, the exponential decay becomes:
```
v(t) = v₀ · e^(-800β·t)
```

This makes the velocity decay 800x faster, but this doesn't accurately represent water physics.

## Correct Water Drag Physics

### Quadratic Drag Equation

For high-velocity projectiles:
```
F_drag = -½ρ·C_D·A·v²
```

The equation of motion becomes:
```
m·dv/dt = -½ρ·C_D·A·v²
dv/dt = -k·v²  where k = (ρ·C_D·A)/(2m)
```

Solution:
```
v(t) = v₀/(1 + k·v₀·t)
x(t) = (1/k)·ln(1 + k·v₀·t)
```

### Density Ratio

- Air density: ρ_air ≈ 1.225 kg/m³
- Water density: ρ_water ≈ 1000 kg/m³
- Ratio: ρ_water/ρ_air ≈ **816.3**

So water drag coefficient should be:
```
k_water = k_air · 816.3  (NOT 800 multiplied to β!)
```

## Test Case Analysis

Initial velocity: v₀ = 820 m/s
Time: t = 0.035 s (fuze delay)
Drag coefficient (air): β = 0.009

### Current Implementation (Linear, β×800)

**Air:**
```
v_air(0.035) = 820 · e^(-0.009 · 0.035)
			 = 820 · e^(-0.000315)
			 = 820 · 0.9997
			 ≈ 819.74 m/s
Distance: (820/0.009) · (1 - 0.9997) ≈ 28.7 m
```

**Water (β×800 = 7.2):**
```
v_water(0.035) = 820 · e^(-7.2 · 0.035)
			   = 820 · e^(-0.252)
			   = 820 · 0.777
			   ≈ 637 m/s
Distance: (820/7.2) · (1 - 0.777) ≈ 25.4 m
```

**Issue:** Shell only loses 183 m/s (22% velocity) in water during 0.035s!

### Correct Quadratic Drag Model

For quadratic drag, if we convert your β to k:
```
k_air ≈ β/v₀ ≈ 0.009/820 ≈ 1.098×10^-5 s/m
k_water = k_air · 816.3 ≈ 0.00896 s/m
```

**Water (quadratic):**
```
v_water(0.035) = 820 / (1 + 0.00896 · 820 · 0.035)
			   = 820 / (1 + 0.257)
			   = 820 / 1.257
			   ≈ 652 m/s
Distance: ln(1.257)/0.00896 ≈ 25.6 m
```

Still only 168 m/s loss (20% velocity).

## Real-World Expectation

Based on naval artillery data, shells entering water at high velocity:
- Lose 50-70% of velocity in first few meters
- Decelerate **very rapidly** due to:
  1. High density (816x)
  2. Cavitation effects
  3. Tumbling/instability

A 380mm AP shell at 820 m/s hitting water would likely:
- Slow to ~200-400 m/s within 0.035s
- Travel only 5-15 meters before fuze triggers

## Recommendations

### Option 1: Enhanced Quadratic Model
Implement proper quadratic drag:
```gdscript
static func calculate_velocity_at_time_quadratic(v0: Vector3, time: float, k: float) -> Vector3:
	var v0_mag = v0.length()
	var direction = v0.normalized()
	var v_mag = v0_mag / (1.0 + k * v0_mag * time)
	return direction * v_mag

static func calculate_position_at_time_quadratic(start_pos: Vector3, v0: Vector3, time: float, k: float) -> Vector3:
	var v0_mag = v0.length()
	var direction = v0.normalized()
	var distance = log(1.0 + k * v0_mag * time) / k
	return start_pos + direction * distance
```

### Option 2: Empirical Water Drag Multiplier
Instead of multiplying drag by 800, use a larger multiplier (2000-5000) OR add velocity-dependent drag:
```gdscript
var effective_drag = base_drag * 800.0 * (1.0 + velocity.length()/1000.0)
```

### Option 3: Simplified High-Drag Model
For water, assume very rapid deceleration:
```gdscript
if in_water:
	# Water drag is extremely high - shell loses most velocity quickly
	var water_drag_factor = 5000.0  # Much higher than 800
	velocity = ProjectilePhysicsWithDrag.calculate_velocity_at_time(
		initial_velocity, 
		time_in_water, 
		base_drag * water_drag_factor
	)
```

## Conclusion

Your implementation is **partially correct** but **underestimates water drag** because:

1. You're using a linear drag model for high-velocity projectiles (should be quadratic)
2. Multiplying β by 800 doesn't correctly model the density ratio effect in an exponential decay model
3. Real shells experience additional drag from cavitation and tumbling

**Quick Fix:** Increase the multiplier from 800 to **3000-5000** to better approximate realistic water drag.

**Better Fix:** Implement quadratic drag model for both air and water.
