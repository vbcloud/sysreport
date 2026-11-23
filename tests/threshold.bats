#!/usr/bin/env bats
# Threshold boundaries and exit codes for sysreport.sh (issue #3).
# Exit codes: 0 under threshold, 1 a check exceeded it, 2 usage error.
# The -t 0 and -t 99 tests depend on the host: 0 needs some usage above 0%,
# 99 needs everything under 99%.

SCRIPT="$BATS_TEST_DIRNAME/../sysreport.sh"

@test "-t 99 exits 0 when everything is under 99%" {
  run "$SCRIPT" -t 99
  [ "$status" -eq 0 ]
}

@test "-t 0 exits 1 because something is always above 0%" {
  run "$SCRIPT" -t 0
  [ "$status" -eq 1 ]
}

@test "-t 100 is rejected with exit 2" {
  run "$SCRIPT" -t 100
  [ "$status" -eq 2 ]
  [[ "$output" == *"threshold must be between 0 and 99"* ]]
}

@test "-t 101 is rejected with exit 2" {
  run "$SCRIPT" -t 101
  [ "$status" -eq 2 ]
}

@test "-t abc is rejected with exit 2" {
  run "$SCRIPT" -t abc
  [ "$status" -eq 2 ]
}

@test "-t with no value is a usage error (exit 2)" {
  run "$SCRIPT" -t
  [ "$status" -eq 2 ]
}

@test "-h exits 0" {
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
}
