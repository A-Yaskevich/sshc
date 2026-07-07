#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "connection_field reads JSON fields" {
  local json='{"name":"srv","host":"h.example","user":"u","port":2222}'
  assert_equal "srv" "$(connection_field "$json" name)"
  assert_equal "h.example" "$(connection_field "$json" host)"
  assert_equal "2222" "$(connection_field "$json" port)"
}

@test "connection_display_name prefers name" {
  local json='{"name":"mybox","host":"h","user":"u"}'
  assert_equal "mybox" "$(connection_display_name "$json")"
}

@test "connection_display_name falls back to user@host" {
  local json='{"name":"","host":"h.example","user":"alice"}'
  assert_equal "alice@h.example" "$(connection_display_name "$json")"
}

@test "connection_display_name falls back to host only" {
  local json='{"name":"","host":"h.example","user":""}'
  assert_equal "h.example" "$(connection_display_name "$json")"
}

@test "connection_ssh_target uses SSH_RESOLVED_USER when user empty" {
  local json='{"name":"x","host":"h.example","user":""}'
  SSH_RESOLVED_USER=testrunner
  assert_equal "testrunner@h.example" "$(connection_ssh_target "$json")"
}

@test "connection_ssh_port defaults to 22" {
  local json='{"name":"x","host":"h","user":"u"}'
  assert_equal "22" "$(connection_ssh_port "$json")"
}

@test "connection_tags_display handles string and array" {
  local json
  json='{"tags_string":"#a #b"}'
  assert_equal "#a #b" "$(connection_tags_display "$json")"
  json='{"tags_string":["#x","#y"]}'
  assert_equal "#x #y" "$(connection_tags_display "$json")"
}
