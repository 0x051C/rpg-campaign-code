#!/usr/bin/env bash
# Shortcut for tests/run_tests.gd: runs the enabled tests of tests/suite.cfg. See CLAUDE.md ("Tests").
#   tests/run_tests.sh                    every enabled test, at 16x speed
#   tests/run_tests.sh items quest        just these (suite.cfg section names)
#   tests/run_tests.sh --speed 1 --all    real time, disabled tests too;  --list shows the suite
# GODOT=/path/to/godot picks the Godot binary (default: godot on the PATH).
cd "$(dirname "$0")/.." || exit 1
exec "${GODOT:-godot}" --headless --path . --script res://tests/run_tests.gd -- "$@"
