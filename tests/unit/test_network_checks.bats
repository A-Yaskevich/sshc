#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "check_icmp succeeds when ping mock exits 0" {
  export PING_MOCK_EXIT=0
  check_icmp example.com
}

@test "check_icmp fails when ping mock exits 1" {
  export PING_MOCK_EXIT=1
  run check_icmp example.com
  assert_failure
}

@test "check_ssh_available uses nc mock when available" {
  export NC_MOCK_EXIT=0
  check_ssh_available example.com 22
  export NC_MOCK_EXIT=1
  run check_ssh_available example.com 22
  assert_failure
}

@test "check_key_auth caches result" {
  export SSH_MOCK_EXIT=0
  KEY_AUTH_CACHE_DIR=$(safe_mktemp_dir)
  check_key_auth "user@host" 22
  local cache
  cache=$(key_auth_cache_path "user@host")
  assert_equal yes "$(cat "$cache")"
  assert_equal yes "$(preview_key_cached_state "user@host")"
}

@test "key_auth_cache_path returns empty when cache dir unset" {
  KEY_AUTH_CACHE_DIR=""
  run key_auth_cache_path "user@host"
  assert_failure
}
