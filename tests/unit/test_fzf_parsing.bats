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
  : >"$SSH_MOCK_LOG"
  : >"$FZF_MOCK_LOG"
  sshc_source_lib
  load_fixture_connections sample.json
}

@test "parse_fzf_result splits query key and selection" {
  local output=$'query\nctrl-e\nalpha'
  parse_fzf_result "$output"
  assert_equal "query" "$PARSE_FZF_QUERY"
  assert_equal "ctrl-e" "$PARSE_FZF_KEY"
  assert_equal "alpha" "$PARSE_FZF_SELECTION"
}

@test "parse_fzf_result returns failure on empty output" {
  run parse_fzf_result ""
  assert_failure
}

@test "fzf_action_from_key maps shortcuts" {
  assert_equal "ADD" "$(fzf_action_from_key ctrl-n)"
  assert_equal "EDIT" "$(fzf_action_from_key ctrl-e)"
  assert_equal "COPY" "$(fzf_action_from_key ctrl-y)"
  assert_equal "DELETE" "$(fzf_action_from_key ctrl-d)"
  assert_equal "KEY" "$(fzf_action_from_key alt-k)"
}

@test "format_connections sorts case-insensitively and includes tags" {
  run format_connections
  assert_success
  assert_output --partial "alpha"
  assert_output --partial "beta"
  assert_output --partial "saved:"
  assert_output --partial "#dev"
}

@test "build_display_line includes ref suffix" {
  local line
  line=$(build_display_line "saved:0")
  [[ "$line" == *$'\t'saved:0 ]]
}

@test "filtered_position_of finds position with mock fzf filter" {
  run filtered_position_of "alpha" ""
  assert_success
  assert_equal "1" "$output"
}
