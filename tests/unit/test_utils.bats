#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "is_true accepts common truthy values" {
  is_true true
  is_true TRUE
  is_true yes
  is_true 1
}

@test "is_true rejects falsy values" {
  run is_true false
  assert_failure
  run is_true ""
  assert_failure
  run is_true nope
  assert_failure
}

@test "die prints to stderr and exits non-zero" {
  run --separate-stderr bash -c 'export SSHC_LIB_ONLY=1; source "$1"; die "boom"' bash "$PROJECT_ROOT/sshc.sh"
  assert_failure
  assert_stderr "Error: boom"
}

@test "warn prints to stderr" {
  run --separate-stderr warn "heads up"
  assert_success
  assert_stderr "Warning: heads up"
}

@test "safe_mktemp creates a readable file" {
  local tmp
  tmp=$(safe_mktemp)
  [[ -f "$tmp" ]]
  printf 'x' >"$tmp"
  assert_equal "x" "$(cat "$tmp")"
  rm -f "$tmp"
}

@test "safe_mktemp_dir creates a directory" {
  local tmp
  tmp=$(safe_mktemp_dir)
  [[ -d "$tmp" ]]
  rmdir "$tmp"
}

@test "atomic_replace_file replaces destination" {
  local dest src
  dest="$BATS_TEST_TMPDIR/dest.txt"
  src="$BATS_TEST_TMPDIR/src.txt"
  printf 'old' >"$dest"
  printf 'new' >"$src"
  atomic_replace_file "$dest" "$src"
  assert_equal "new" "$(cat "$dest")"
  [[ ! -f "$src" ]]
}

@test "shell_escape_single escapes single quotes" {
  run shell_escape_single "it's fine"
  assert_success
  assert_output "it'\''s fine"
}

@test "strip_ansi removes color codes" {
  local colored=$'\033[32mgreen\033[0m'
  run strip_ansi "$colored"
  assert_success
  assert_output "green"
}

@test "run_with_timeout returns 124 on slow command" {
  run run_with_timeout 1 sleep 5
  assert_failure
  assert_equal 124 "$status"
}

@test "run_with_timeout returns command exit code on success" {
  run run_with_timeout 2 true
  assert_success
}

@test "cache_key_for_target is stable for the same input" {
  local a b
  a=$(cache_key_for_target "user@host")
  b=$(cache_key_for_target "user@host")
  assert_equal "$a" "$b"
  [[ -n "$a" ]]
}
