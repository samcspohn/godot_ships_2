#include "projectile_physics_with_drag.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>
#include <limits>

using namespace godot;

ProjectilePhysicsWithDrag::ProjectilePhysicsWithDrag() {
}

ProjectilePhysicsWithDrag::~ProjectilePhysicsWithDrag() {
}

void ProjectilePhysicsWithDrag::_bind_methods() {
    // Bind simple (no-drag) static methods
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("simple_calculate_launch_vector", "start_pos", "target_pos", "projectile_speed"), &ProjectilePhysicsWithDrag::simple_calculate_launch_vector);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("simple_calculate_position_at_time", "start_pos", "launch_vector", "time"), &ProjectilePhysicsWithDrag::simple_calculate_position_at_time);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("simple_calculate_leading_launch_vector", "start_pos", "target_pos", "target_velocity", "projectile_speed"), &ProjectilePhysicsWithDrag::simple_calculate_leading_launch_vector);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("simple_calculate_max_range_from_angle", "angle", "projectile_speed"), &ProjectilePhysicsWithDrag::simple_calculate_max_range_from_angle);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("simple_calculate_angle_from_max_range", "max_range", "projectile_speed"), &ProjectilePhysicsWithDrag::simple_calculate_angle_from_max_range);

    // Bind drag-affected static methods
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_absolute_max_range", "projectile_speed", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_absolute_max_range);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_velocity_at_time", "launch_vector", "time", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_velocity_at_time);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_precise_shell_position", "start_pos", "target_pos", "launch_vector", "current_time", "total_flight_time", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_precise_shell_position);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_launch_vector", "start_pos", "target_pos", "projectile_speed", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_launch_vector);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_impact_position", "start_pos", "launch_velocity", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_impact_position);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("estimate_time_of_flight", "start_pos", "launch_vector", "horiz_dist", "drag_coefficient"), &ProjectilePhysicsWithDrag::estimate_time_of_flight);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_position_at_time", "start_pos", "launch_vector", "time", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_position_at_time);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_leading_launch_vector", "start_pos", "target_pos", "target_velocity", "projectile_speed", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_leading_launch_vector);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_max_range_from_angle", "angle", "projectile_speed", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_max_range_from_angle);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("calculate_angle_from_max_range", "max_range", "projectile_speed", "drag_coefficient"), &ProjectilePhysicsWithDrag::calculate_angle_from_max_range);
    
    // Bind constant getters
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_gravity"), &ProjectilePhysicsWithDrag::get_gravity);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_default_drag_coefficient"), &ProjectilePhysicsWithDrag::get_default_drag_coefficient);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_shell_380mm_drag_coefficient"), &ProjectilePhysicsWithDrag::get_shell_380mm_drag_coefficient);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_ping_pong_drag_coefficient"), &ProjectilePhysicsWithDrag::get_ping_pong_drag_coefficient);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_bowling_ball_drag_coefficient"), &ProjectilePhysicsWithDrag::get_bowling_ball_drag_coefficient);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_position_tolerance"), &ProjectilePhysicsWithDrag::get_position_tolerance);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_max_iterations"), &ProjectilePhysicsWithDrag::get_max_iterations);
    ClassDB::bind_static_method("ProjectilePhysicsWithDrag", D_METHOD("get_initial_angle_step"), &ProjectilePhysicsWithDrag::get_initial_angle_step);

    // Note: BIND_CONSTANT only works for integer constants
    // Float constants are exposed via static getter methods bound above
    BIND_CONSTANT(MAX_ITERATIONS);
}

// ==========================================
// Simple (No-Drag) Projectile Physics Methods
// ==========================================

Array ProjectilePhysicsWithDrag::simple_calculate_launch_vector(
    const Vector3& start_pos,
    const Vector3& target_pos,
    double projectile_speed
) {
    // Calculate displacement vector
    Vector3 disp = target_pos - start_pos;
    
    // Calculate horizontal distance and direction
    double horiz_dist = Vector2(disp.x, disp.z).length();
    double horiz_angle = std::atan2(disp.z, disp.x);
    
    // Physical parameters
    double g = std::abs(GRAVITY);
    double v = projectile_speed;
    double h = disp.y;
    
    // Calculate the discriminant from the quadratic equation derived from the physics
    double discriminant = std::pow(v, 4) - g * (g * std::pow(horiz_dist, 2) + 2.0 * h * std::pow(v, 2));
    
    if (discriminant < 0) {
        // No solution exists - target is out of range
        Array result;
        result.push_back(Variant());
        result.push_back(-1.0);
        return result;
    }
    
    // Calculate the two possible elevation angles (high and low arc)
    double sqrt_disc = std::sqrt(discriminant);
    double angle1 = std::atan((std::pow(v, 2) + sqrt_disc) / (g * horiz_dist));
    double angle2 = std::atan((std::pow(v, 2) - sqrt_disc) / (g * horiz_dist));
    
    // Calculate flight times for both possible angles
    // A valid trajectory requires that cos(angle) != 0 (not firing straight up or down)
    double time1 = -1.0;
    double time2 = -1.0;
    
    if (std::abs(std::cos(angle1)) > 0.001) {  // Avoid division by zero
        time1 = horiz_dist / (v * std::cos(angle1));
        // Make sure this is a valid forward trajectory (not firing backward)
        if (time1 <= 0) {
            time1 = -1.0;
        }
    }
    
    if (std::abs(std::cos(angle2)) > 0.001) {  // Avoid division by zero
        time2 = horiz_dist / (v * std::cos(angle2));
        // Make sure this is a valid forward trajectory (not firing backward)
        if (time2 <= 0) {
            time2 = -1.0;
        }
    }
    
    // Choose the angle that results in the shortest time to target (shortest path)
    double elev_angle;
    
    // If only one solution is valid, use that one
    if (time1 < 0 && time2 >= 0) {
        elev_angle = angle2;
    } else if (time2 < 0 && time1 >= 0) {
        elev_angle = angle1;
    } else if (time1 >= 0 && time2 >= 0) {
        // If both are valid, use the one with shorter time
        elev_angle = (time1 < time2) ? angle1 : angle2;
    } else {
        // No valid solution
        Array result;
        result.push_back(Variant());
        result.push_back(-1.0);
        return result;
    }
    
    // Calculate the initial velocity components
    Vector3 launch_vector = Vector3(
        v * std::cos(elev_angle) * std::cos(horiz_angle),
        v * std::sin(elev_angle),
        v * std::cos(elev_angle) * std::sin(horiz_angle)
    );
    
    // Calculate time to target
    double time_to_target = horiz_dist / (v * std::cos(elev_angle));
    
    Array result;
    result.push_back(launch_vector);
    result.push_back(time_to_target);
    return result;
}

Vector3 ProjectilePhysicsWithDrag::simple_calculate_position_at_time(
    const Vector3& start_pos,
    const Vector3& launch_vector,
    double time
) {
    return Vector3(
        start_pos.x + launch_vector.x * time,
        start_pos.y + launch_vector.y * time + 0.5 * GRAVITY * time * time,
        start_pos.z + launch_vector.z * time
    );
}

Array ProjectilePhysicsWithDrag::simple_calculate_leading_launch_vector(
    const Vector3& start_pos,
    const Vector3& target_pos,
    const Vector3& target_velocity,
    double projectile_speed
) {
    // Start with the time it would take to hit the current position
    Array result = simple_calculate_launch_vector(start_pos, target_pos, projectile_speed);
    
    Variant launch_vec = result[0];
    if (launch_vec.get_type() != Variant::VECTOR3) {
        Array fail_result;
        fail_result.push_back(Variant());
        fail_result.push_back(-1.0);
        return fail_result;
    }
    
    double time_estimate = result[1];
    
    // Refine the estimate a few times
    for (int i = 0; i < 1; i++) {  // Just a few iterations should be sufficient
        Vector3 predicted_pos = target_pos + target_velocity * time_estimate;
        result = simple_calculate_launch_vector(start_pos, predicted_pos, projectile_speed);
        
        launch_vec = result[0];
        if (launch_vec.get_type() != Variant::VECTOR3) {
            Array fail_result;
            fail_result.push_back(Variant());
            fail_result.push_back(-1.0);
            return fail_result;
        }
        
        time_estimate = result[1];
    }
    
    // Final calculation with the best time estimate
    Vector3 final_target_pos = target_pos + target_velocity * time_estimate;
    return simple_calculate_launch_vector(start_pos, final_target_pos, projectile_speed);
}

double ProjectilePhysicsWithDrag::simple_calculate_max_range_from_angle(
    double angle,
    double projectile_speed
) {
    double g = std::abs(GRAVITY);
    
    // Using the range formula: R = (v² * sin(2θ)) / g
    double max_range = (std::pow(projectile_speed, 2) * std::sin(2.0 * angle)) / g;
    
    // Handle negative results (when firing downward)
    if (max_range < 0) {
        return 0.0;
    }
    
    return max_range;
}

double ProjectilePhysicsWithDrag::simple_calculate_angle_from_max_range(
    double max_range,
    double projectile_speed
) {
    double g = std::abs(GRAVITY);
    
    // The theoretical maximum range is achieved at 45 degrees
    double theoretical_max = std::pow(projectile_speed, 2) / g;
    
    // Check if the requested range is physically possible
    if (max_range > theoretical_max || max_range < 0) {
        return -1.0;  // Impossible range
    }
    
    // Using the formula: sin(2θ) = (R * g) / v²
    double sin_2theta = (max_range * g) / std::pow(projectile_speed, 2);
    
    // Calculate the angle (there are two solutions, we'll return the flatter trajectory)
    double angle = std::asin(sin_2theta) / 2.0;
    
    return angle;
}

// ==========================================
// Drag-Affected Projectile Physics Methods
// ==========================================

Array ProjectilePhysicsWithDrag::calculate_absolute_max_range(double projectile_speed, double drag_coefficient) {
    // Initialize search parameters
    double min_range = 0.0;
    double max_range = projectile_speed * projectile_speed / std::abs(GRAVITY) * 2.0;  // Theoretical max without drag
    double best_range = 0.0;
    double best_angle = 0.0;
    double best_time = 0.0;
    
    // Binary search to find maximum range
    for (int i = 0; i < MAX_ITERATIONS; i++) {
        double test_range = (min_range + max_range) / 2.0;
        Vector3 target_pos = Vector3(test_range, 0, 0);
        
        Array result = calculate_launch_vector(Vector3(), target_pos, projectile_speed, drag_coefficient);
        
        Variant launch_vec = result[0];
        double time = result[1];
        
        if (launch_vec.get_type() == Variant::VECTOR3 && time > 0) {
            if (test_range > best_range) {
                best_range = test_range;
                Vector3 velocity = launch_vec;
                best_angle = std::atan2(velocity.y, std::sqrt(velocity.x * velocity.x + velocity.z * velocity.z));
                best_time = time;
                min_range = best_range;
            }
        } else {
            max_range = test_range;
        }
        
        if (max_range - min_range < 0.01) {  // 1cm tolerance
            break;
        }
    }
    
    Array result;
    result.push_back(best_range);
    result.push_back(best_angle);
    result.push_back(best_time);
    return result;
}

Vector3 ProjectilePhysicsWithDrag::calculate_velocity_at_time(const Vector3& launch_vector, double time, double drag_coefficient) {
    double v0x = launch_vector.x;
    double v0y = launch_vector.y;
    double v0z = launch_vector.z;
    double beta = drag_coefficient;
    double g = std::abs(GRAVITY);
    
    Vector3 velocity;
    
    // Calculate exponential decay due to drag
    double drag_decay = std::exp(-beta * time);
    
    // For x and z (horizontal components with drag)
    // vx = v₀x * e^(-βt)
    velocity.x = v0x * drag_decay;
    velocity.z = v0z * drag_decay;
    
    // For y (vertical component with drag and gravity)
    // vy = v₀y * e^(-βt) - (g/β) + (g/β) * e^(-βt)
    velocity.y = v0y * drag_decay - (g / beta) + (g / beta) * drag_decay;
    
    return velocity;
}

Vector3 ProjectilePhysicsWithDrag::calculate_precise_shell_position(
    const Vector3& start_pos, 
    const Vector3& target_pos,
    const Vector3& launch_vector, 
    double current_time,
    double total_flight_time,
    double drag_coefficient
) {
    // Safety check
    if (total_flight_time <= 0.0) {
        return start_pos;
    }
    
    // If we haven't reached the target yet, use physics with correction
    if (current_time <= total_flight_time) {
        // Calculate the physically expected position using drag physics
        Vector3 physics_position = calculate_position_at_time(start_pos, launch_vector, current_time, drag_coefficient);
        
        // If we're at the end time or very close to it, return exactly the target position
        if (Math::is_equal_approx(current_time, total_flight_time) || 
            (total_flight_time - current_time) < 0.001) {
            return target_pos;
        }
        
        // Generate a correction factor that smoothly transitions from 0 to 1
        double t = current_time / total_flight_time;
        double correction_strength = t * t * t; // Smooth step function
        
        // Apply increasing correction as we get closer to the target
        Vector3 projected_error = target_pos - calculate_position_at_time(start_pos, launch_vector, total_flight_time, drag_coefficient);
        Vector3 corrected_position = physics_position + projected_error * correction_strength;
        
        return corrected_position;
    }
    
    // If we're past the target, extrapolate from end position using end velocity
    Vector3 impact_velocity = calculate_velocity_at_time(launch_vector, total_flight_time, drag_coefficient);
    double excess_time = current_time - total_flight_time;
    
    return target_pos + impact_velocity * excess_time;
}

Array ProjectilePhysicsWithDrag::calculate_launch_vector(
    const Vector3& start_pos, 
    const Vector3& target_pos, 
    double projectile_speed,
    double drag_coefficient
) {
    // Start with the non-drag physics as initial approximation
    Array initial_result = simple_calculate_launch_vector(start_pos, target_pos, projectile_speed);
    
    Variant initial_vec = initial_result[0];
    if (initial_vec.get_type() != Variant::VECTOR3) {
        Array result;
        result.push_back(Variant());
        result.push_back(-1);
        return result;
    }
    
    Vector3 initial_vector = initial_vec;
    
    // Calculate direction to target (azimuth angle - remains constant)
    Vector3 disp = target_pos - start_pos;
    double horiz_dist = Vector2(disp.x, disp.z).length();
    Vector2 horiz_dir = Vector2(disp.x, disp.z).normalized();
    
    // Extract elevation angle from initial vector
    double initial_speed_xz = Vector2(initial_vector.x, initial_vector.z).length();
    double elevation_angle = std::atan2(initial_vector.y, initial_speed_xz);
    
    double beta = drag_coefficient;
    double g = std::abs(GRAVITY);
    double theta = elevation_angle;
    
    // Newton-Raphson refinement loop
    const int REFINEMENT_ITERATIONS = 3;
    const double DELTA_THETA = 0.0001;
    
    for (int iteration = 0; iteration < REFINEMENT_ITERATIONS; iteration++) {
        // Calculate current trajectory error
        double v0_horiz = projectile_speed * std::cos(theta);
        double v0y = projectile_speed * std::sin(theta);
        
        // Calculate flight time using horizontal constraint
        double drag_factor = beta * horiz_dist / v0_horiz;
        if (drag_factor >= 0.99) {
            Array result;
            result.push_back(Variant());
            result.push_back(-1);
            return result;
        }
        
        double flight_time = -std::log(1.0 - drag_factor) / beta;
        
        // Calculate vertical position at this flight time
        double drag_decay = 1.0 - std::exp(-beta * flight_time);
        double calc_y = start_pos.y + (v0y / beta) * drag_decay - (g / beta) * flight_time + (g / (beta * beta)) * drag_decay;
        double f_val = calc_y - target_pos.y;
        
        // Calculate derivative numerically
        double theta_plus = theta + DELTA_THETA;
        double v0_horiz_plus = projectile_speed * std::cos(theta_plus);
        double v0y_plus = projectile_speed * std::sin(theta_plus);
        
        double drag_factor_plus = beta * horiz_dist / v0_horiz_plus;
        if (drag_factor_plus < 0.99) {
            double flight_time_plus = -std::log(1.0 - drag_factor_plus) / beta;
            double drag_decay_plus = 1.0 - std::exp(-beta * flight_time_plus);
            double calc_y_plus = start_pos.y + (v0y_plus / beta) * drag_decay_plus - (g / beta) * flight_time_plus + (g / (beta * beta)) * drag_decay_plus;
            double f_prime = (calc_y_plus - calc_y) / DELTA_THETA;
            
            if (std::abs(f_prime) > 1e-10) {
                theta = theta - f_val / f_prime;
            }
        }
    }
    
    // Create final launch vector
    Vector3 final_launch_vector = Vector3(
        projectile_speed * std::cos(theta) * horiz_dir.x,
        projectile_speed * std::sin(theta),
        projectile_speed * std::cos(theta) * horiz_dir.y
    );
    
    // Calculate final flight time
    double final_v0_horiz = projectile_speed * std::cos(theta);
    double final_drag_factor = beta * horiz_dist / final_v0_horiz;
    
    if (final_drag_factor >= 0.99) {
        Array result;
        result.push_back(Variant());
        result.push_back(-1);
        return result;
    }
    
    double final_flight_time = -std::log(1.0 - final_drag_factor) / beta;
    
    // Verify accuracy
    double final_drag_decay = 1.0 - std::exp(-beta * final_flight_time);
    double final_y = start_pos.y + (projectile_speed * std::sin(theta) / beta) * final_drag_decay - (g / beta) * final_flight_time + (g / (beta * beta)) * final_drag_decay;
    
    double error_distance = std::abs(final_y - target_pos.y);
    if (error_distance > POSITION_TOLERANCE) {
        Array result;
        result.push_back(Variant());
        result.push_back(-1);
        return result;
    }
    
    Array result;
    result.push_back(final_launch_vector);
    result.push_back(final_flight_time);
    return result;
}

Vector3 ProjectilePhysicsWithDrag::calculate_impact_position(
    const Vector3& start_pos, 
    const Vector3& launch_velocity, 
    double drag_coefficient
) {
    // Safety checks
    if (start_pos.y <= 0.0) {
        return start_pos;
    }
    
    if (drag_coefficient <= 0.0) {
        UtilityFunctions::push_error("Invalid drag coefficient: must be positive");
        return Vector3();
    }
    
    double y0 = start_pos.y;
    double v0y = launch_velocity.y;
    double v0x = launch_velocity.x;
    double v0z = launch_velocity.z;
    double beta = drag_coefficient;
    double g = std::abs(GRAVITY);
    
    // Get initial guess using ballistic formula (no drag)
    double no_drag_time = 0.0;
    if (v0y >= 0) {
        no_drag_time = (v0y + std::sqrt(v0y * v0y + 2.0 * g * y0)) / g;
    } else {
        double discriminant = v0y * v0y + 2.0 * g * y0;
        if (discriminant < 0) {
            return Vector3();
        }
        no_drag_time = (-v0y + std::sqrt(discriminant)) / g;
    }
    
    double t = no_drag_time;
    
    // Newton-Raphson steps
    // Step 1
    double exp_term = std::exp(-beta * t);
    double f_val = y0 + (v0y / beta) * (1.0 - exp_term) - (g / beta) * t + (g / (beta * beta)) * (1.0 - exp_term);
    double f_prime = (v0y + g / beta) * exp_term - g / beta;
    
    if (std::abs(f_prime) > 1e-10) {
        t = t - f_val / f_prime;
    }
    
    // Step 2
    exp_term = std::exp(-beta * t);
    f_val = y0 + (v0y / beta) * (1.0 - exp_term) - (g / beta) * t + (g / (beta * beta)) * (1.0 - exp_term);
    f_prime = (v0y + g / beta) * exp_term - g / beta;
    
    if (std::abs(f_prime) > 1e-10) {
        t = t - f_val / f_prime;
    }
    
    if (t <= 0) {
        return Vector3();
    }
    
    // Calculate final horizontal positions
    double drag_factor = 1.0 - std::exp(-beta * t);
    
    double final_x = start_pos.x + (v0x / beta) * drag_factor;
    double final_z = start_pos.z + (v0z / beta) * drag_factor;
    
    return Vector3(final_x, 0.0, final_z);
}

double ProjectilePhysicsWithDrag::estimate_time_of_flight(
    const Vector3& start_pos, 
    const Vector3& launch_vector, 
    double horiz_dist,
    double drag_coefficient
) {
    double v0_horiz = Vector2(launch_vector.x, launch_vector.z).length();
    double beta = drag_coefficient;
    
    double drag_factor = beta * horiz_dist / v0_horiz;
    
    if (drag_factor >= 0.99) {
        return std::numeric_limits<double>::infinity();
    }
    
    return -std::log(1.0 - drag_factor) / beta;
}

Vector3 ProjectilePhysicsWithDrag::calculate_position_at_time(
    const Vector3& start_pos, 
    const Vector3& launch_vector, 
    double time,
    double drag_coefficient
) {
    if (time <= 0.0) {
        return start_pos;
    }
    
    double v0x = launch_vector.x;
    double v0y = launch_vector.y;
    double v0z = launch_vector.z;
    double beta = drag_coefficient;
    double g = std::abs(GRAVITY);
    
    Vector3 position;
    
    // For x and z (horizontal components with drag)
    double drag_factor = 1.0 - std::exp(-beta * time);
    if (std::isnan(drag_factor)) {
        drag_factor = 0.0;
    }
    position.x = start_pos.x + (v0x / beta) * drag_factor;
    position.z = start_pos.z + (v0z / beta) * drag_factor;
    
    // For y (vertical component with drag and gravity)
    position.y = start_pos.y + (v0y / beta) * drag_factor - (g / beta) * time + (g / (beta * beta)) * drag_factor;
    
    return position;
}

Array ProjectilePhysicsWithDrag::calculate_leading_launch_vector(
    const Vector3& start_pos, 
    const Vector3& target_pos, 
    const Vector3& target_velocity,
    double projectile_speed,
    double drag_coefficient
) {
    // Start with non-drag estimation using the integrated simple method
    Array result = simple_calculate_launch_vector(start_pos, target_pos, projectile_speed);
    
    Variant launch_vec = result[0];
    if (launch_vec.get_type() != Variant::VECTOR3) {
        Array fail_result;
        fail_result.push_back(Variant());
        fail_result.push_back(-1);
        fail_result.push_back(Variant());
        return fail_result;
    }
    
    double time_estimate = result[1];
    
    // Refine the estimate iteratively
    for (int i = 0; i < 3; i++) {
        Vector3 predicted_pos = target_pos + target_velocity * time_estimate;
        
        result = calculate_launch_vector(start_pos, predicted_pos, projectile_speed, drag_coefficient);
        
        launch_vec = result[0];
        if (launch_vec.get_type() != Variant::VECTOR3) {
            Array fail_result;
            fail_result.push_back(Variant());
            fail_result.push_back(-1);
            fail_result.push_back(Variant());
            return fail_result;
        }
        
        time_estimate = result[1];
    }
    
    // Final calculation
    Vector3 final_target_pos = target_pos + target_velocity * time_estimate;
    result = calculate_launch_vector(start_pos, final_target_pos, projectile_speed, drag_coefficient);
    
    Array final_result;
    final_result.push_back(result[0]);
    final_result.push_back(result[1]);
    final_result.push_back(final_target_pos);
    return final_result;
}

double ProjectilePhysicsWithDrag::calculate_max_range_from_angle(
    double angle, 
    double projectile_speed,
    double drag_coefficient
) {
    Vector3 launch_vector = Vector3(
        projectile_speed * std::cos(angle),
        projectile_speed * std::sin(angle),
        0
    );
    
    double v0x = projectile_speed * std::cos(angle);
    
    double max_time = 100.0;
    double time_step = 0.1;
    double current_time = 0.0;
    Vector3 prev_pos = Vector3();
    Vector3 current_pos = Vector3();
    
    while (current_time < max_time) {
        current_pos = calculate_position_at_time(Vector3(), launch_vector, current_time, drag_coefficient);
        
        if (current_pos.y < 0 && prev_pos.y >= 0) {
            double t_ratio = prev_pos.y / (prev_pos.y - current_pos.y);
            double impact_time = current_time - time_step + (time_step * t_ratio);
            
            Vector3 impact_pos = calculate_position_at_time(Vector3(), launch_vector, impact_time, drag_coefficient);
            
            return Vector2(impact_pos.x, impact_pos.z).length();
        }
        
        prev_pos = current_pos;
        current_time += time_step;
    }
    
    // Asymptotic range
    return v0x / drag_coefficient;
}

double ProjectilePhysicsWithDrag::calculate_angle_from_max_range(
    double max_range, 
    double projectile_speed,
    double drag_coefficient
) {
    double beta = drag_coefficient;
    double g = std::abs(GRAVITY);
    
    double min_angle = 0.0;
    double max_angle = Math_PI / 4.0;
    
    // Find theoretical max range
    double max_possible_range = 0.0;
    double test_angles[] = {Math_PI / 6.0, Math_PI / 5.0, Math_PI / 4.0, Math_PI / 3.0};
    for (int i = 0; i < 4; i++) {
        double test_range = calculate_max_range_from_angle(test_angles[i], projectile_speed, beta);
        if (test_range > max_possible_range) {
            max_possible_range = test_range;
        }
    }
    
    if (max_range > max_possible_range) {
        return -1;
    }
    
    // Binary search
    for (int i = 0; i < MAX_ITERATIONS; i++) {
        double test_angle = (min_angle + max_angle) / 2.0;
        double test_range = calculate_max_range_from_angle(test_angle, projectile_speed, beta);
        
        double error = test_range - max_range;
        
        if (std::abs(error) < 0.1) {
            return test_angle;
        }
        
        if (error < 0) {
            min_angle = test_angle;
        } else {
            max_angle = test_angle;
        }
    }
    
    return (min_angle + max_angle) / 2.0;
}