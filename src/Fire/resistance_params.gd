extends Moddable
class_name ResistanceParams

@export var max_buildup: float = 100.0
@export var buildup_reduction_rate: float = 0.005 # 5% of max per second
@export_storage var reduction_block_rate: float = 1.0 # rate at which buildup reduction is blocked after shell hit, 1.0 means full block, 0.0 means no block
