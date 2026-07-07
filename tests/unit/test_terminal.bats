#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "terminal_set_bg prints OSC 11 sequence when forced" {
  SSHC_FORCE_TTY=true
  run terminal_set_bg "#112233"
  assert_success
  assert_output --partial $'\033]11;#112233'
}

@test "terminal_set_title prints title escape when forced" {
  SSHC_FORCE_TTY=true
  run terminal_set_title "sshc-test"
  assert_success
  assert_output --partial "sshc-test"
}

@test "terminal_restore_title uses SSHC_TERMINAL_TITLE when forced" {
  SSHC_FORCE_TTY=true
  SSHC_TERMINAL_TITLE=sshc.sh
  run terminal_restore_title
  assert_success
  assert_output --partial "sshc.sh"
}
