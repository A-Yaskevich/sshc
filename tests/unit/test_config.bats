#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "seed_sshc_data_dir creates dot-config files from templates" {
  rm -rf "$SSHC_DATA_DIR"
  seed_sshc_data_dir
  [[ -f "$SSHC_DATA_DIR/.sshc.general.parameters" ]]
  [[ -f "$SSHC_DATA_DIR/.sshc.colors.light" ]]
  [[ -f "$SSHC_DATA_DIR/.sshc.colors.dark" ]]
}

@test "seed_sshc_config_file is idempotent" {
  rm -rf "$SSHC_DATA_DIR"
  seed_sshc_data_dir
  local first
  first=$(md5 -q "$SSHC_DATA_DIR/.sshc.general.parameters" 2>/dev/null \
    || md5sum "$SSHC_DATA_DIR/.sshc.general.parameters" | awk '{print $1}')
  seed_sshc_config_file sshc.general.parameters.template
  local second
  second=$(md5 -q "$SSHC_DATA_DIR/.sshc.general.parameters" 2>/dev/null \
    || md5sum "$SSHC_DATA_DIR/.sshc.general.parameters" | awk '{print $1}')
  assert_equal "$first" "$second"
}

@test "load_sshc_config loads light theme by default" {
  assert_equal "light" "$FZF_COLOR_SCHEME"
  [[ -n "$COLOR_GREEN" ]]
}

@test "load_sshc_config loads dark theme when DARK_MODE=true" {
  sed -i.bak 's/^DARK_MODE=.*/DARK_MODE=true/' "$SSHC_DATA_DIR/.sshc.general.parameters"
  load_sshc_config "$SSHC_DATA_DIR"
  assert_equal "dark" "$FZF_COLOR_SCHEME"
}

@test "ensure_sshc_data_dir sets mode 700" {
  rm -rf "$SSHC_DATA_DIR"
  ensure_sshc_data_dir
  [[ -d "$SSHC_DATA_DIR" ]]
}

@test "migrate_legacy_data_files moves old connections file" {
  printf '%s\n' '{"connections":[]}' >"$HOME/.sshc_connections.json"
  rm -f "$CONNECTIONS_FILE"
  migrate_legacy_data_files
  [[ -f "$CONNECTIONS_FILE" ]]
  [[ ! -f "$HOME/.sshc_connections.json" ]]
}

@test "migrate_legacy_data_files moves old encryption key" {
  printf 'legacy-key' >"$HOME/.sshc.key"
  rm -f "$ENCRYPTION_KEY_FILE"
  migrate_legacy_data_files
  [[ -f "$ENCRYPTION_KEY_FILE" ]]
  [[ ! -f "$HOME/.sshc.key" ]]
}
