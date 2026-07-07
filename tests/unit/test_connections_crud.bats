#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "ensure_connections_json creates empty file" {
  rm -f "$CONNECTIONS_FILE"
  ensure_connections_json "$CONNECTIONS_FILE"
  assert_equal '{"connections":[]}' "$(tr -d '\n' <"$CONNECTIONS_FILE")"
}

@test "connections_file_readable rejects invalid JSON" {
  printf 'not json' >"$BATS_TEST_TMPDIR/bad.json"
  run connections_file_readable "$BATS_TEST_TMPDIR/bad.json"
  assert_failure
}

@test "connections append update remove roundtrip" {
  load_fixture_connections sample.json
  assert_connections_count 3

  local obj
  obj='{"name":"delta","host":"delta.example.com","user":"dan","port":22,"password":"","post_cmd":"","tags_string":""}'
  connections_append "$CONNECTIONS_FILE" "$obj"
  assert_connections_count 4

  obj='{"name":"delta","host":"delta.example.com","user":"dan","port": 2222,"password":"","post_cmd":"","tags_string":"#new"}'
  connections_update_at "$CONNECTIONS_FILE" 3 "$obj"
  assert_equal "2222" "$(jq -r '.connections[3].port' "$CONNECTIONS_FILE")"

  connections_remove_at "$CONNECTIONS_FILE" 3
  assert_connections_count 3
}

@test "connections_write_doc rejects invalid JSON" {
  load_fixture_connections sample.json
  run connections_write_doc "$CONNECTIONS_FILE" '{bad'
  assert_failure
  assert_connections_count 3
}

@test "connections_name_exists detects duplicates" {
  load_fixture_connections sample.json
  connections_name_exists "$CONNECTIONS_FILE" "alpha"
  run connections_name_exists "$CONNECTIONS_FILE" "alpha" 0
  assert_failure
  run connections_name_exists "$CONNECTIONS_FILE" "missing"
  assert_failure
}
