#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "connection_normalize_for_storage joins array tags" {
  local json='{"name":"x","host":"h","user":"u","tags_string":["#a","#b"]}'
  local out
  out=$(connection_normalize_for_storage "$json")
  assert_equal "#a #b" "$(connection_field "$out" tags_string)"
}

@test "connection_prepare_for_storage clears empty password" {
  local json='{"name":"x","host":"h","user":"u","port":22,"password":"","post_cmd":"","tags_string":""}'
  local out
  out=$(connection_prepare_for_storage "$json")
  assert_equal "" "$(connection_field "$out" password)"
}

@test "connection_prepare_for_storage encrypts new password" {
  local json='{"name":"x","host":"h","user":"u","port":22,"password":"secret","post_cmd":"","tags_string":""}'
  local out stored
  out=$(connection_prepare_for_storage "$json")
  stored=$(connection_field "$out" password)
  [[ -n "$stored" ]]
  assert_equal "secret" "$(decrypt_secret "$stored")"
}

@test "connection_prepare_for_storage keeps ciphertext when password unchanged" {
  local json encrypted out stored
  json='{"name":"x","host":"h","user":"u","port":22,"password":"secret","post_cmd":"","tags_string":""}'
  encrypted=$(connection_prepare_for_storage "$json")
  encrypted=$(connection_field "$encrypted" password)
  json='{"name":"x","host":"h","user":"u","port":22,"password":"secret","post_cmd":"","tags_string":""}'
  out=$(connection_prepare_for_storage "$json" "$encrypted")
  stored=$(connection_field "$out" password)
  assert_equal "$encrypted" "$stored"
}
