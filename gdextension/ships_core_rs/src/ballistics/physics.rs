use crate::variant_cast::VariantCast;
use godot::prelude::*;

const GRAVITY: f64 = -9.8;

#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct ProjectilePhysics {
    base: Base<Node>,
}

#[godot_api]
impl ProjectilePhysics {
    #[func]
    fn get_gravity() -> f64 {
        GRAVITY
    }

    /// Returns [launch_vector, time_to_target] or [null, -1] if no solution exists.
    #[func]
    pub(crate) fn calculate_launch_vector(start_pos: Vector3, target_pos: Vector3, projectile_speed: f64) -> VarArray {
        let disp = target_pos - start_pos;

        let horiz_dist = Vector2::new(disp.x, disp.z).length() as f64;
        // atan2 runs in f32 (float args pick the float overload) and is then
        // widened, matching `double horiz_angle = std::atan2(...)`. The trig on
        // it below is therefore f64.
        let horiz_angle = disp.z.atan2(disp.x) as f64;

        let g = GRAVITY.abs();
        let v = projectile_speed;
        let h = disp.y as f64;

        let discriminant = v.powf(4.0) - g * (g * horiz_dist.powf(2.0) + 2.0 * h * v.powf(2.0));

        if discriminant < 0.0 {
            return no_solution();
        }

        let sqrt_disc = discriminant.sqrt();
        let angle1 = ((v.powf(2.0) + sqrt_disc) / (g * horiz_dist)).atan();
        let angle2 = ((v.powf(2.0) - sqrt_disc) / (g * horiz_dist)).atan();

        // A valid trajectory requires cos(angle) != 0 and a forward flight time.
        let mut time1 = -1.0;
        let mut time2 = -1.0;

        if angle1.cos().abs() > 0.001 {
            time1 = horiz_dist / (v * angle1.cos());
            if time1 <= 0.0 {
                time1 = -1.0;
            }
        }

        if angle2.cos().abs() > 0.001 {
            time2 = horiz_dist / (v * angle2.cos());
            if time2 <= 0.0 {
                time2 = -1.0;
            }
        }

        // Prefer the shorter time to target when both arcs are valid.
        let elev_angle = if time1 < 0.0 && time2 >= 0.0 {
            angle2
        } else if time2 < 0.0 && time1 >= 0.0 {
            angle1
        } else if time1 >= 0.0 && time2 >= 0.0 {
            if time1 < time2 {
                angle1
            } else {
                angle2
            }
        } else {
            return no_solution();
        };

        let launch_vector = Vector3::new(
            (v * elev_angle.cos() * horiz_angle.cos()) as f32,
            (v * elev_angle.sin()) as f32,
            (v * elev_angle.cos() * horiz_angle.sin()) as f32,
        );

        let time_to_target = horiz_dist / (v * elev_angle.cos());

        let mut result = VarArray::new();
        result.push(&launch_vector.to_variant());
        result.push(&time_to_target.to_variant());
        result
    }

    #[func]
    fn calculate_position_at_time(start_pos: Vector3, launch_vector: Vector3, time: f64) -> Vector3 {
        Vector3::new(
            (start_pos.x as f64 + launch_vector.x as f64 * time) as f32,
            (start_pos.y as f64 + launch_vector.y as f64 * time + 0.5 * GRAVITY * time * time) as f32,
            (start_pos.z as f64 + launch_vector.z as f64 * time) as f32,
        )
    }

    #[func]
    fn calculate_leading_launch_vector(
        start_pos: Vector3,
        target_pos: Vector3,
        target_velocity: Vector3,
        projectile_speed: f64,
    ) -> VarArray {
        let mut result = Self::calculate_launch_vector(start_pos, target_pos, projectile_speed);

        if result.at(0).is_nil() {
            return no_solution();
        }

        let mut time_estimate: f64 = result.at(1).to_f64();

        for _ in 0..1 {
            let predicted_pos = target_pos + target_velocity * time_estimate as f32;
            result = Self::calculate_launch_vector(start_pos, predicted_pos, projectile_speed);

            if result.at(0).is_nil() {
                return no_solution();
            }

            time_estimate = result.at(1).to_f64();
        }

        let final_target_pos = target_pos + target_velocity * time_estimate as f32;
        Self::calculate_launch_vector(start_pos, final_target_pos, projectile_speed)
    }

    #[func]
    fn calculate_max_range_from_angle(angle: f64, projectile_speed: f64) -> f64 {
        let g = GRAVITY.abs();

        // R = (v^2 * sin(2t)) / g
        let max_range = (projectile_speed.powf(2.0) * (2.0 * angle).sin()) / g;

        if max_range < 0.0 {
            return 0.0;
        }

        max_range
    }

    #[func]
    fn calculate_angle_from_max_range(max_range: f64, projectile_speed: f64) -> f64 {
        let g = GRAVITY.abs();

        let theoretical_max = projectile_speed.powf(2.0) / g;

        if max_range > theoretical_max || max_range < 0.0 {
            return -1.0;
        }

        let sin_2theta = (max_range * g) / projectile_speed.powf(2.0);

        // Two solutions exist; return the flatter trajectory.
        sin_2theta.asin() / 2.0
    }
}

fn no_solution() -> VarArray {
    let mut result = VarArray::new();
    result.push(&Variant::nil());
    result.push(&(-1.0f64).to_variant());
    result
}
