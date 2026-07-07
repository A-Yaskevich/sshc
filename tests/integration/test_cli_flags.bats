#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "--set-remote-bg prints OSC 11 and exits 0" {
  SSHC_FORCE_TTY=true run run_sshc --set-remote-bg "#aabbcc"
  assert_success
  assert_output --partial $'\033]11;#aabbcc'
}

@test "--preview renders connection info with mocked network checks" {
  load_fixture_connections sample.json
  export PING_MOCK_EXIT=0
  export NC_MOCK_EXIT=0
  export SSH_MOCK_EXIT=0
  export PREVIEW_DEBOUNCE_SECS=0
  run run_sshc --preview "alpha"
  assert_success
  assert_output --partial "alice@alpha.example.com"
  assert_output --partial "ICMP availability"
}
