#!/usr/bin/env bash

set -euo pipefail

bats_require_minimum_version 1.5.0

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
FIXTURES_BIN="$TESTS_ROOT/fixtures/bin"

export BATS_LIB_PATH="${TESTS_ROOT}/test_helper${BATS_LIB_PATH:+:${BATS_LIB_PATH}}"

load_bats_libraries() {
  bats_load_library bats-support
  bats_load_library bats-assert
}

sshc_reset_globals() {
  unset SSHC_SCRIPT_DIR SCRIPT_PATH SSHC_TERMINAL_TITLE KEY_AUTH_CACHE_DIR
  unset CONNECTIONS_FILE ENCRYPTION_KEY_FILE KNOWN_HOSTS_FILE
  unset DARK_MODE FZF_COLOR_SCHEME REMOTE_BG_COLOR
  unset COLOR_GREEN COLOR_YELLOW COLOR_RED COLOR_DIM COLOR_TAG COLOR_RESET
  unset PREVIEW_NETWORK_CHECK_TIMEOUT PREVIEW_KEY_CHECK_TIMEOUT PREVIEW_DEBOUNCE_SECS
  unset PING_WAIT_FLAG NC_WAIT_FLAG SSH_RESOLVED_USER SSH_BG_OPTS
  unset PARSE_FZF_QUERY PARSE_FZF_KEY PARSE_FZF_SELECTION
}

sshc_source_lib() {
  sshc_reset_globals
  export SSHC_LIB_ONLY=1
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/sshc.sh"
  sshc_bootstrap
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  export SSHC_DATA_DIR="$HOME/.sshc"
  export PATH="$FIXTURES_BIN:$PATH"
  export SSH_MOCK_LOG="$BATS_TEST_TMPDIR/ssh_mock.log"
  export FZF_MOCK_LOG="$BATS_TEST_TMPDIR/fzf_mock.log"
  : >"$SSH_MOCK_LOG"
  : >"$FZF_MOCK_LOG"
  sshc_source_lib
}

teardown() {
  sshc_reset_globals
}

load_fixture_connections() {
  local fixture="$1"
  cp "$TESTS_ROOT/fixtures/connections/$fixture" "$CONNECTIONS_FILE"
  chmod 600 "$CONNECTIONS_FILE" 2>/dev/null || true
}

mock_editor_writes() {
  local json="$1"
  export EDITOR_OUTPUT="$json"
  export EDITOR="$FIXTURES_BIN/mock-editor"
  export VISUAL="$EDITOR"
}

run_sshc() {
  env -i \
    HOME="$HOME" \
    PATH="$PATH" \
    USER="${USER:-testuser}" \
    SSHC_DATA_DIR="$SSHC_DATA_DIR" \
    SSHC_FORCE_TTY="${SSHC_FORCE_TTY:-}" \
    SSH_MOCK_LOG="$SSH_MOCK_LOG" \
    FZF_MOCK_LOG="$FZF_MOCK_LOG" \
    FZF_MOCK_COUNT_FILE="${FZF_MOCK_COUNT_FILE:-}" \
    FZF_MOCK_OUTPUT="${FZF_MOCK_OUTPUT:-}" \
    FZF_MOCK_OUTPUT_1="${FZF_MOCK_OUTPUT_1:-}" \
    FZF_MOCK_OUTPUT_2="${FZF_MOCK_OUTPUT_2:-}" \
    FZF_MOCK_OUTPUT_3="${FZF_MOCK_OUTPUT_3:-}" \
    FZF_MOCK_EXIT="${FZF_MOCK_EXIT:-0}" \
    FZF_MOCK_EXIT_1="${FZF_MOCK_EXIT_1:-0}" \
    FZF_MOCK_EXIT_2="${FZF_MOCK_EXIT_2:-1}" \
    FZF_MOCK_EXIT_3="${FZF_MOCK_EXIT_3:-1}" \
    SSH_MOCK_EXIT="${SSH_MOCK_EXIT:-0}" \
    PING_MOCK_EXIT="${PING_MOCK_EXIT:-0}" \
    NC_MOCK_EXIT="${NC_MOCK_EXIT:-0}" \
    SSHPASS_MOCK_EXIT="${SSHPASS_MOCK_EXIT:-0}" \
    SSH_KEYGEN_MOCK_FOUND="${SSH_KEYGEN_MOCK_FOUND:-}" \
    TERM="${TERM:-xterm-256color}" \
    bash "$PROJECT_ROOT/sshc.sh" "$@"
}

assert_connections_count() {
  local expected="$1"
  local actual
  actual=$(connections_count "$CONNECTIONS_FILE")
  assert_equal "$expected" "$actual"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file"
}
