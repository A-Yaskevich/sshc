#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "sshc dies when jq is missing" {
  run env -i HOME="$HOME" USER="${USER:-test}" PATH="/bin" \
    SSHC_DATA_DIR="$SSHC_DATA_DIR" bash "$PROJECT_ROOT/sshc.sh" 2>&1
  assert_failure
  assert_output --partial "jq"
}

@test "sshc dies when fzf is missing but jq is available" {
  local jq_dir
  jq_dir=$(dirname "$(command -v jq)")
  run env -i HOME="$HOME" USER="${USER:-test}" PATH="$jq_dir:/bin" \
    SSHC_DATA_DIR="$SSHC_DATA_DIR" bash "$PROJECT_ROOT/sshc.sh" 2>&1
  assert_failure
  assert_output --partial "fzf"
}
