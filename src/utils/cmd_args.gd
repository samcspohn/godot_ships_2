class_name CmdArgs


static func has(flag: String) -> bool:
	return flag in OS.get_cmdline_args() or flag in OS.get_cmdline_user_args()


## Value after `flag`, or `fallback` when absent or followed by another flag.
static func value(flag: String, fallback: String = "") -> String:
	for args in [OS.get_cmdline_args(), OS.get_cmdline_user_args()]:
		var i: int = args.find(flag)
		if i >= 0 and i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
			return args[i + 1]
	return fallback
