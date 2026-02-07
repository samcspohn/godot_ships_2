extends StatCounter

class_name HitCounter

# Backwards compatibility wrapper for HitCounter
# All functionality is now provided by StatCounter base class

# Alias for backwards compatibility
var hit_type: String:
	get:
		return counter_type
	set(value):
		counter_type = value
