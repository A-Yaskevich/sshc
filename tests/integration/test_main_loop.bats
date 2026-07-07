#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  export SSHC_DATA_DIR="$HOME/.sshc"
  export PATH="$BATS_TEST_DIRNAME/../fixtures/bin:$PATH"
  export SSH_MOCK_LOG="$BATS_TEST_TMPDIR/ssh_mock.log"
  export FZF_MOCK_LOG="$BATS_TEST_TMPDIR/fzf_mock.log"
  export FZF_MOCK_COUNT_FILE="$BATS_TEST_TMPDIR/fzf.count"
  : >"$SSH_MOCK_LOG"
  : >"$FZF_MOCK_LOG"
  rm -f "$FZF_MOCK_COUNT_FILE"
  sshc_source_lib
  load_fixture_connections sample.json
  export SSH_MOCK_EXIT=0
}

@test "main loop connects when Enter selects a connection" {
  export FZF_MOCK_OUTPUT_1=$'\n\nalpha'
  export FZF_MOCK_OUTPUT_2=""
  export FZF_MOCK_EXIT_2=1
  run run_sshc
  assert_success
  assert_output --partial "Connecting to"
  assert_file_contains "$SSH_MOCK_LOG" "alpha.example.com"
}

@test "main loop exits when fzf returns empty result" {
  export FZF_MOCK_OUTPUT_1=""
  export FZF_MOCK_EXIT_1=1
  run run_sshc
  assert_success
  assert_output --partial "Exiting"
}

@test "main loop deletes connection on ctrl-d" {
  export FZF_MOCK_OUTPUT_1=$'\nctrl-d\nalpha'
  export FZF_MOCK_OUTPUT_2=""
  export FZF_MOCK_EXIT_2=1
  run run_sshc
  assert_success
  assert_output --partial "Removed"
  assert_equal 2 "$(jq '.connections | length' "$CONNECTIONS_FILE")"
}
