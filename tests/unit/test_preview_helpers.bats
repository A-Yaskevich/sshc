#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "preview_status_line formats states" {
  run preview_status_line "ICMP availability" yes
  assert_success
  assert_output --partial "Yes"
  run preview_status_line "ICMP availability" no
  assert_output --partial "No"
  run preview_status_line "ICMP availability" timeout
  assert_output --partial "Timeout"
  run preview_status_line "ICMP availability" loading
  assert_output --partial "..."
}

@test "preview_finalize_loading_states converts loading to timeout" {
  icmp_state=loading
  ssh_state=loading
  key_state=yes
  preview_finalize_loading_states
  assert_equal timeout "$icmp_state"
  assert_equal timeout "$ssh_state"
  assert_equal yes "$key_state"
}

@test "preview_states_signature joins states" {
  icmp_state=yes
  ssh_state=no
  key_state=timeout
  known_state=yes
  assert_equal "yes|no|timeout|yes" "$(preview_states_signature)"
}

@test "preview_write_check_result writes yes on success" {
  local tmp="$BATS_TEST_TMPDIR/preview"
  mkdir -p "$tmp"
  preview_write_check_result "$tmp/icmp" true
  assert_equal yes "$(cat "$tmp/icmp")"
}

@test "preview_apply_results_from_files reads check files" {
  local tmp="$BATS_TEST_TMPDIR/preview2"
  mkdir -p "$tmp"
  printf 'yes' >"$tmp/icmp"
  printf 'no' >"$tmp/ssh"
  printf 'timeout' >"$tmp/key"
  icmp_state=loading
  ssh_state=loading
  key_state=loading
  preview_apply_results_from_files "$tmp"
  assert_equal yes "$icmp_state"
  assert_equal no "$ssh_state"
  assert_equal timeout "$key_state"
}

@test "preview_render prints connection and status lines" {
  run preview_render "alice@host" yes no timeout yes no yes
  assert_success
  assert_output --partial "alice@host"
  assert_output --partial "ICMP availability"
  assert_output --partial "SSH availability"
}
