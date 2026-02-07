extends Node
class_name RollbackProfiler
## Hooks into NetworkRollback to measure resimulation cost per frame.
## Drop this node into any game scene to profile rollback spikes.
##
## Usage:
##   Add as a child node in your scene tree.
##   Call print_report() at any time to see accumulated stats.
##   Call get_summary() for programmatic access.

## Resimulation depth (in ticks) above which a frame is counted as a "spike".
@export var spike_threshold_ticks: int = 5

# Per-frame state (reset each loop)
var _frame_resim_ticks: int = 0
var _frame_resim_start_us: int = 0

# Accumulated stats
var resim_tick_counts := PackedInt32Array()
var resim_durations_us := PackedInt64Array()

var spike_count: int = 0
var max_resim_depth: int = 0
var max_resim_duration_us: int = 0
var total_frames_profiled: int = 0

func _ready():
	NetworkRollback.before_loop.connect(_on_before_loop)
	NetworkRollback.on_process_tick.connect(_on_process_tick)
	NetworkRollback.after_loop.connect(_on_after_loop)

func _on_before_loop():
	_frame_resim_ticks = 0
	_frame_resim_start_us = Time.get_ticks_usec()

func _on_process_tick(_tick: int):
	_frame_resim_ticks += 1

func _on_after_loop():
	var dur := Time.get_ticks_usec() - _frame_resim_start_us
	total_frames_profiled += 1

	resim_tick_counts.append(_frame_resim_ticks)
	resim_durations_us.append(dur)

	if _frame_resim_ticks > max_resim_depth:
		max_resim_depth = _frame_resim_ticks
	if dur > max_resim_duration_us:
		max_resim_duration_us = dur
	if _frame_resim_ticks > spike_threshold_ticks:
		spike_count += 1

func get_avg_resim_ticks() -> float:
	if resim_tick_counts.is_empty():
		return 0.0
	var sum := 0
	for c in resim_tick_counts:
		sum += c
	return float(sum) / resim_tick_counts.size()

func get_avg_resim_duration_us() -> float:
	if resim_durations_us.is_empty():
		return 0.0
	var sum := 0
	for d in resim_durations_us:
		sum += d
	return float(sum) / resim_durations_us.size()

func get_p99_resim_ticks() -> int:
	if resim_tick_counts.is_empty():
		return 0
	var sorted := PackedInt32Array(resim_tick_counts)
	sorted.sort()
	return sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)]

func get_p99_resim_duration_us() -> int:
	if resim_durations_us.is_empty():
		return 0
	var sorted := PackedInt64Array(resim_durations_us)
	sorted.sort()
	return sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)]

func get_summary() -> Dictionary:
	return {
		"total_frames": total_frames_profiled,
		"avg_resim_ticks": get_avg_resim_ticks(),
		"max_resim_depth": max_resim_depth,
		"p99_resim_ticks": get_p99_resim_ticks(),
		"avg_resim_duration_us": get_avg_resim_duration_us(),
		"max_resim_duration_us": max_resim_duration_us,
		"p99_resim_duration_us": get_p99_resim_duration_us(),
		"spike_count": spike_count,
		"spike_threshold": spike_threshold_ticks,
	}

func print_report():
	var s = get_summary()
	print("=== RollbackProfiler Report ===")
	print("  Frames profiled:       %d" % s["total_frames"])
	print("  Avg resim ticks/frame: %.2f" % s["avg_resim_ticks"])
	print("  Max resim depth:       %d ticks" % s["max_resim_depth"])
	print("  P99 resim depth:       %d ticks" % s["p99_resim_ticks"])
	print("  Avg resim duration:    %.1f us" % s["avg_resim_duration_us"])
	print("  Max resim duration:    %d us" % s["max_resim_duration_us"])
	print("  P99 resim duration:    %d us" % s["p99_resim_duration_us"])
	print("  Spikes (>%d ticks):    %d" % [s["spike_threshold"], s["spike_count"]])
	print("===============================")

func reset():
	resim_tick_counts = PackedInt32Array()
	resim_durations_us = PackedInt64Array()
	spike_count = 0
	max_resim_depth = 0
	max_resim_duration_us = 0
	total_frames_profiled = 0
