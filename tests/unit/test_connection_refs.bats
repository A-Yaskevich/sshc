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

@test "connection_ref_from_fzf_line extracts ref suffix" {
  local line=$'alpha\tsaved:0'
  assert_equal "saved:0" "$(connection_ref_from_fzf_line "$line")"
}

@test "connection_from_ref returns stored connection" {
  local json
  json=$(connection_from_ref "saved:0")
  assert_equal "alpha" "$(connection_field "$json" name)"
}

@test "connection_from_display resolves tabbed fzf line" {
  local line
  line=$(build_display_line "saved:0")
  assert_equal "saved:0" "$(connection_from_display "$line")"
}

@test "connection_from_display resolves plain display name" {
  assert_equal "saved:0" "$(connection_from_display "alpha")"
}
