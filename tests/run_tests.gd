extends SceneTree

## Runs the game's tests: every enabled entry of tests/suite.cfg (see TestSuite), each in its
## own game window, at 16 times game speed. Prints one line per test and a summary, writes
## tests/output/<test>.log and tests/output/results.json (the Tests dock reads it), and exits
## with 1 if anything failed.
##
##   godot --headless --path . --script res://tests/run_tests.gd -- [options] [test ids]
##   tests/run_tests.sh [options] [test ids]          (the same, shorter)
##
## Options: --speed <n> (1 = real time), --all (disabled tests too), --list.
## Test ids are suite.cfg's section names ("items", "recorded/bridge_fight").

var _speed := TestSuite.DEFAULT_SPEED
var _include_disabled := false
var _only := PackedStringArray()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	var list_only := false
	while i < args.size():
		match args[i]:
			"--speed":
				i += 1
				_speed = float(args[i])
			"--all":
				_include_disabled = true
			"--list":
				list_only = true
			_:
				_only.append(args[i])
		i += 1
	var entries := TestSuite.entries()
	if list_only:
		for entry in entries:
			print("%-8s %-32s %s" % ["" if entry.enabled else "disabled", entry.id, entry.note])
		quit()
		return
	quit(_run(entries))


func _run(entries: Array[Dictionary]) -> int:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TestSuite.OUTPUT_DIR))
	var results := TestSuite.last_results()
	var counts := {"pass": 0, "fail": 0, "skipped": 0}
	var started := Time.get_ticks_msec()
	for entry in entries:
		if not _only.is_empty() and not _only.has(entry.id):
			continue
		if not entry.enabled and not _include_disabled and _only.is_empty():
			print("skip  %-34s %s" % [entry.id, entry.note])
			results[entry.id] = {"result": "skipped", "note": entry.note}
			counts.skipped += 1
			_write(results)
			continue
		var result := _run_one(entry)
		results[entry.id] = result
		counts[result.result if result.result == "pass" else "fail"] += 1
		_write(results)
		if result.result == "pass":
			print("pass  %-34s %6.1fs" % [entry.id, result.seconds])
		else:
			print("FAIL  %-34s %6.1fs  %s" % [entry.id, result.seconds, result.summary])
			for line: String in result.failed_checks.slice(0, 5):
				print("        " + line)
	print("%d passed, %d failed, %d skipped in %.0fs at %sx" % [counts.pass, counts.fail, counts.skipped,
			(Time.get_ticks_msec() - started) / 1000.0, _speed])
	return 1 if counts.fail > 0 else 0


## Starts the test as its own game and collects its output.
func _run_one(entry: Dictionary) -> Dictionary:
	var log_path := ProjectSettings.globalize_path(TestSuite.OUTPUT_DIR).path_join(TestSuite.safe_name(entry.id) + ".log")
	var command := TestSuite.command(entry, _speed)
	if command.is_empty():
		return {"result": "fail", "seconds": 0.0, "summary": "can't start it (missing recording?)", "failed_checks": [],
				"log": log_path}
	for key: String in command.env:
		OS.set_environment(key, str(command.env[key]))
	var started := Time.get_ticks_msec()
	var process := OS.execute_with_pipe(OS.get_executable_path(), command.args, false)
	var output := PackedByteArray()
	var timed_out := false
	var stopped := false
	# A script error in the test's own _initialize ends it without quitting Godot: don't wait for the timeout
	var dead_end := "at: _initialize (%s:" % entry.script if not (entry.script as String).is_empty() else ""
	if process.is_empty():
		output = ("could not start %s" % OS.get_executable_path()).to_utf8_buffer()
	else:
		var stdio: FileAccess = process.stdio
		var stderr: FileAccess = process.stderr
		while OS.is_process_running(process.pid):
			var before := output.size()
			output.append_array(stdio.get_buffer(65536))
			output.append_array(stderr.get_buffer(65536))
			if Time.get_ticks_msec() - started > TestSuite.TIMEOUT * 1000.0:
				OS.kill(process.pid)
				timed_out = true
				break
			if not dead_end.is_empty() and output.size() > before and output.get_string_from_utf8().contains(dead_end):
				OS.delay_msec(200)  # let it print the rest of the backtrace
				OS.kill(process.pid)
				stopped = true
				break
			OS.delay_msec(30)
		output.append_array(stdio.get_buffer(1 << 20))
		output.append_array(stderr.get_buffer(1 << 20))
	for key: String in command.env:
		OS.unset_environment(key)
	var text := output.get_string_from_utf8()
	var log_file := FileAccess.open(log_path, FileAccess.WRITE)
	log_file.store_string(text)
	var failures := -1
	var failed_checks := PackedStringArray()
	for line in text.split("\n"):
		if line.begins_with("FAILURES: "):
			failures = int(line.trim_prefix("FAILURES: "))
		elif line.begins_with("FAIL ") or line.begins_with("SCRIPT ERROR"):
			failed_checks.append(line.strip_edges())
	var summary := "FAILURES: %d" % failures
	if timed_out:
		summary = "timed out after %ds" % TestSuite.TIMEOUT
	elif stopped:
		summary = "stopped at a script error in the test"
	elif failures < 0:
		summary = "no result (it crashed?)"
	return {"result": "pass" if failures == 0 and not timed_out and not stopped else "fail", "failures": failures,
			"seconds": (Time.get_ticks_msec() - started) / 1000.0, "summary": summary,
			"failed_checks": failed_checks, "log": log_path}


func _write(results: Dictionary) -> void:
	var file := FileAccess.open(TestSuite.RESULTS_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
