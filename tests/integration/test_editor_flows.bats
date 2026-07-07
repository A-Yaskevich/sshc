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

@test "edit_json_in_vi returns edited JSON from mock editor" {
  mock_editor_writes '{"name":"new","host":"h","user":"u","port":22,"password":"","post_cmd":"","tags_string":""}'
  run edit_json_in_vi "$NEW_CONNECTION_TEMPLATE"
  assert_success
  assert_output --partial '"name":"new"'
}

@test "edit_new_connection appends connection" {
  mock_editor_writes '{"name":"zeta","host":"z.example","user":"z","port":22,"password":"","post_cmd":"","tags_string":""}'
  run edit_new_connection
  assert_success
  assert_connections_count 4
  connections_name_exists "$CONNECTIONS_FILE" "zeta"
}

@test "edit_connection updates existing entry" {
  mock_editor_writes '{"name":"alpha-renamed","host":"alpha.example.com","user":"alice","port":22,"password":"","post_cmd":"","tags_string":"#dev"}'
  run edit_connection "saved:0"
  assert_success
  assert_equal "alpha-renamed" "$(jq -r '.connections[0].name' "$CONNECTIONS_FILE")"
}

@test "copy_connection duplicates entry" {
  mock_editor_writes '{"name":"alpha-copy","host":"alpha.example.com","user":"alice","port":22,"password":"","post_cmd":"","tags_string":"#dev"}'
  run copy_connection "saved:0"
  assert_success
  assert_connections_count 4
}

@test "delete_connection removes entry" {
  run delete_connection "saved:0"
  assert_success
  assert_connections_count 2
}
