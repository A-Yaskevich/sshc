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
  export SSH_MOCK_EXIT=0
}

@test "ssh_invoke calls ssh for key-based connection" {
  local json
  json=$(connection_from_ref "saved:0")
  ssh_invoke "$json" ssh alice@alpha.example.com
  assert_file_contains "$SSH_MOCK_LOG" "alice@alpha.example.com"
}

@test "ssh_invoke uses sshpass when password is set" {
  local json cipher stored
  cipher=$(encrypt_secret "pw")
  json=$(jq -nc --arg pw "$cipher" \
    '{name:"pw-host",host:"pw.example",user:"u",port:22,password:$pw,post_cmd:"",tags_string:""}')
  ssh_invoke "$json" ssh u@pw.example
  assert_file_contains "$SSH_MOCK_LOG" "sshpass"
}

@test "ssh_invoke falls back to ssh when sshpass missing" {
  local json cipher path_no_sshpass
  cipher=$(encrypt_secret "pw")
  json=$(jq -nc --arg pw "$cipher" \
    '{name:"pw-host",host:"pw.example",user:"u",port:22,password:$pw,post_cmd:"",tags_string:""}')
  path_no_sshpass=$(echo "$PATH" | tr ':' '\n' | grep -v 'sshpass' | paste -sd: -)
  PATH="$path_no_sshpass" ssh_invoke "$json" ssh u@pw.example
  assert_file_contains "$SSH_MOCK_LOG" "u@pw.example"
}

@test "connect_ssh invokes ssh with post_cmd" {
  local json
  json=$(connection_from_ref "saved:1")
  run connect_ssh "$json"
  assert_success
  assert_file_contains "$SSH_MOCK_LOG" "beta.example.com"
  assert_file_contains "$SSH_MOCK_LOG" "-p 2222"
}
