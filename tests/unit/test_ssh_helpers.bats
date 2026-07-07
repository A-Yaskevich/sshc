#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "connection_post_cmd_remote preserves bang prefix" {
  assert_equal "/bin/true" "$(connection_post_cmd_remote "!/bin/true")"
}

@test "connection_post_cmd_remote appends shell for normal commands" {
  assert_equal "cd /tmp; exec \$SHELL -l" "$(connection_post_cmd_remote "cd /tmp")"
}

@test "connection_has_password and post_cmd" {
  local json
  json='{"name":"x","host":"h","user":"u","password":"enc","post_cmd":"ls"}'
  connection_has_password "$json"
  connection_has_post_cmd "$json"
  json='{"name":"x","host":"h","user":"u","password":"","post_cmd":""}'
  run connection_has_password "$json"
  assert_failure
  run connection_has_post_cmd "$json"
  assert_failure
}

@test "ssh_bg_local_command_args sets LocalCommand when color configured" {
  REMOTE_BG_COLOR="#101010"
  ssh_bg_local_command_args
  [[ ${#SSH_BG_OPTS[@]} -gt 0 ]]
  [[ "${SSH_BG_OPTS[*]}" == *PermitLocalCommand=yes* ]]
}

@test "is_in_known_hosts uses ssh-keygen mock" {
  export SSH_KEYGEN_MOCK_FOUND="known.example.com"
  printf 'host known.example.com\n' >"$KNOWN_HOSTS_FILE"
  is_in_known_hosts "known.example.com"
  run is_in_known_hosts "other.example.com"
  assert_failure
}
