#!/bin/bash
#
# sshc — interactive SSH connection picker built on fzf.
#
# Runtime data and configuration live in ~/.sshc/. Passwords are
# OpenSSL-encrypted with key material in ~/.sshc/key. JSON is read and written
# via jq.
# The fzf preview pane runs reachability checks (ICMP, SSH port, key auth) in
# background subprocesses.
#

set -o pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

SSHC_CONFIG_TEMPLATES=(
  sshc.general.parameters.template
  sshc.colors.dark.template
  sshc.colors.light.template
)

load_sshc_config() {
  local data_dir="$1" color_file

  data_dir=$(cd "$data_dir" && pwd)

  [[ -f "$data_dir/.sshc.general.parameters" ]] \
    || die "missing config: $data_dir/.sshc.general.parameters"
  # shellcheck source=/dev/null
  source "$data_dir/.sshc.general.parameters"

  if is_true "$DARK_MODE"; then
    color_file="$data_dir/.sshc.colors.dark"
    FZF_COLOR_SCHEME=dark
  else
    color_file="$data_dir/.sshc.colors.light"
    FZF_COLOR_SCHEME=light
  fi

  [[ -f "$color_file" ]] || die "missing config: $color_file"
  # shellcheck source=/dev/null
  source "$color_file"
}

ensure_sshc_data_dir() {
  [[ -d "$SSHC_DATA_DIR" ]] || mkdir -p "$SSHC_DATA_DIR" \
    || die "could not create $SSHC_DATA_DIR"
  chmod 700 "$SSHC_DATA_DIR" 2>/dev/null || true
}

seed_sshc_config_file() {
  local template="$1" config_name dest src

  config_name=".${template%.template}"
  dest="$SSHC_DATA_DIR/$config_name"
  src="$SSHC_SCRIPT_DIR/$template"

  [[ -f "$dest" ]] && return 0
  [[ -f "$src" ]] || die "missing bundled config template: $src"
  cp "$src" "$dest" || die "could not create $dest"
  echo "Created config file at '$dest'."
}

seed_sshc_data_dir() {
  local template

  ensure_sshc_data_dir
  for template in "${SSHC_CONFIG_TEMPLATES[@]}"; do
    seed_sshc_config_file "$template"
  done
}

migrate_legacy_data_files() {
  if [[ ! -f "$CONNECTIONS_FILE" && -f "$HOME/.sshc_connections.json" ]]; then
    mv "$HOME/.sshc_connections.json" "$CONNECTIONS_FILE" \
      || die "could not migrate $HOME/.sshc_connections.json"
    echo "Migrated connections to '$CONNECTIONS_FILE'."
    chmod 600 "$CONNECTIONS_FILE" 2>/dev/null || true
  fi

  if [[ ! -f "$ENCRYPTION_KEY_FILE" && -f "$HOME/.sshc.key" ]]; then
    mv "$HOME/.sshc.key" "$ENCRYPTION_KEY_FILE" \
      || die "could not migrate $HOME/.sshc.key"
    echo "Migrated encryption key to '$ENCRYPTION_KEY_FILE'."
    chmod 600 "$ENCRYPTION_KEY_FILE" 2>/dev/null || true
  fi
}

resolve_script_path() {
  local source="${BASH_SOURCE[0]:-$0}"
  local dir

  while [[ -L "$source" ]]; do
    dir=$(cd "$(dirname "$source")" && pwd)
    source=$(readlink "$source")
    [[ "$source" != /* ]] && source="$dir/$source"
  done

  dir=$(cd "$(dirname "$source")" && pwd)
  printf '%s' "$dir/$(basename "$source")"
}

# Linux ping uses -W for wait; BSD/macOS use -t. GNU nc uses -w; BSD nc uses -G.
case "$(uname -s)" in
  Darwin|FreeBSD|OpenBSD|NetBSD)
    PING_WAIT_FLAG=-t
    NC_WAIT_FLAG=-G
    ;;
  *)
    PING_WAIT_FLAG=-W
    NC_WAIT_FLAG=-w
    ;;
esac

# ---------------------------------------------------------------------------
# Small utilities (errors, temp files, portable sed)
# ---------------------------------------------------------------------------

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

safe_mktemp() {
  local tmp template="${1:-${TMPDIR:-/tmp}/sshc.XXXXXX}"
  tmp=$(mktemp "$template") || die "failed to create temporary file"
  printf '%s' "$tmp"
}

safe_mktemp_dir() {
  local tmp
  tmp=$(mktemp -d) || die "failed to create temporary directory"
  printf '%s' "$tmp"
}

atomic_replace_file() {
  local dest="$1" src="$2"
  if ! mv "$src" "$dest"; then
    rm -f "$src"
    warn "failed to update $dest"
    return 1
  fi
}

EMPTY_CONNECTIONS_DOC='{"connections":[]}'

connections_file_readable() {
  [[ -f "$1" && -r "$1" ]] || return 1
  jq empty "$1" 2>/dev/null
}

ensure_connections_json() {
  local path="$1"

  if [[ -f "$path" ]]; then
    connections_file_readable "$path" || die "invalid JSON in $path"
    return 0
  fi

  printf '%s\n' "$EMPTY_CONNECTIONS_DOC" >"$path" || die "could not create $path"
  if [[ "$path" == "$CONNECTIONS_FILE" ]]; then
    chmod 600 "$path" 2>/dev/null || true
  fi
  echo "Created empty connection file at '$path'."
}

connections_write_doc() {
  local path="$1" doc="$2"
  local tmp

  tmp=$(safe_mktemp) || return 1
  printf '%s\n' "$doc" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "refusing to write invalid JSON to $path"
    return 1
  fi
  atomic_replace_file "$path" "$tmp"
  if [[ "$path" == "$CONNECTIONS_FILE" ]]; then
    chmod 600 "$path" 2>/dev/null || true
  fi
}

connections_count() {
  jq '.connections | length' "$1" 2>/dev/null
}

connections_get_at() {
  local path="$1" index="$2"
  jq -c ".connections[$index]" "$path" 2>/dev/null
}

connections_append() {
  local path="$1" obj="$2"
  local doc

  doc=$(jq -c --argjson obj "$obj" '.connections += [$obj]' "$path") || return 1
  connections_write_doc "$path" "$doc"
}

connections_update_at() {
  local path="$1" index="$2" obj="$3"
  local doc

  doc=$(jq -c --argjson idx "$index" --argjson obj "$obj" \
    '.connections[$idx | tonumber] = $obj' "$path") || return 1
  connections_write_doc "$path" "$doc"
}

connections_remove_at() {
  local path="$1" index="$2"
  local doc

  doc=$(jq -c --argjson idx "$index" 'del(.connections[$idx | tonumber])' "$path") || return 1
  connections_write_doc "$path" "$doc"
}

connections_name_exists() {
  local path="$1" name="$2" exclude_index="${3:--1}"
  local count i existing

  count=$(connections_count "$path") || return 1
  for ((i = 0; i < count; i++)); do
    ((i == exclude_index)) && continue
    existing=$(jq -r ".connections[$i].name // \"\"" "$path")
    if [[ -n "$name" && "$existing" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

connection_field() {
  local json="$1" field="$2"
  jq -r ".$field // empty" <<<"$json"
}

connection_display_name() {
  local json="$1"
  local name host user

  name=$(connection_field "$json" name)
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
    return 0
  fi

  host=$(connection_field "$json" host)
  user=$(connection_field "$json" user)
  if [[ -n "$user" && -n "$host" ]]; then
    printf '%s@%s' "$user" "$host"
  elif [[ -n "$host" ]]; then
    printf '%s' "$host"
  else
    printf '%s' "?"
  fi
}

connection_ssh_target() {
  local json="$1"
  local user host

  user=$(connection_field "$json" user)
  host=$(connection_field "$json" host)

  if [[ -n "$user" ]]; then
    printf '%s@%s' "$user" "$host"
  else
    printf '%s@%s' "${SSH_RESOLVED_USER:-${USER:-$(whoami)}}" "$host"
  fi
}

connection_ssh_port() {
  local json="$1" port

  port=$(connection_field "$json" port)
  if [[ -n "$port" ]]; then
    printf '%s' "$port"
  else
    printf '%s' "22"
  fi
}

connection_tags_display() {
  local json="$1"
  jq -r 'if (.tags_string | type) == "array" then (.tags_string | join(" "))
         else (.tags_string // "") end' <<<"$json"
}

connection_ref_from_fzf_line() {
  local line="$1"
  line="${line##*$'\t'}"
  printf '%s' "$line"
}

connection_path_from_ref() {
  printf '%s' "$CONNECTIONS_FILE"
}

connection_index_from_ref() {
  local ref="$1"
  printf '%s' "${ref#*:}"
}

connection_from_ref() {
  local ref="$1" path index

  path=$(connection_path_from_ref "$ref") || return 1
  index=$(connection_index_from_ref "$ref")
  connections_get_at "$path" "$index"
}

connection_from_display() {
  local display="$1"
  local stripped ref path count i json shown

  stripped=$(strip_ansi "$display")
  stripped="${stripped%%$'\t'*}"

  if [[ "$display" == *$'\t'* ]]; then
    ref=$(connection_ref_from_fzf_line "$display")
    if connection_from_ref "$ref" >/dev/null; then
      printf '%s' "$ref"
      return 0
    fi
  fi

  connections_file_readable "$CONNECTIONS_FILE" || return 1
  count=$(connections_count "$CONNECTIONS_FILE") || return 1
  for ((i = 0; i < count; i++)); do
    json=$(connections_get_at "$CONNECTIONS_FILE" "$i") || continue
    shown=$(connection_display_name "$json")
    if [[ "$stripped" == "$shown" || "$stripped" == "$shown "* ]]; then
      printf 'saved:%s' "$i"
      return 0
    fi
  done

  return 1
}

NEW_CONNECTION_TEMPLATE='{
  "name": "",
  "host": "",
  "user": "",
  "port": 22,
  "password": "",
  "post_cmd": "",
  "tags_string": ""
}'

connection_to_editor_json() {
  local json="$1"
  local password decrypted

  password=$(connection_field "$json" password)
  if [[ -n "$password" ]]; then
    if decrypted=$(decrypt_secret "$password" 2>/dev/null); then
      json=$(jq -c --arg pw "$decrypted" '.password = $pw' <<<"$json")
    fi
  fi
  jq '.' <<<"$json"
}

connection_normalize_for_storage() {
  local json="$1"

  jq -c '
    .tags_string = (
      if (.tags_string | type) == "array" then (.tags_string | join(" "))
      elif (.tags_string | type) == "string" then .tags_string
      else "" end
    )
  ' <<<"$json"
}

connection_prepare_for_storage() {
  local json="$1" existing_encrypted="${2:-}"
  local password encrypted existing_plain

  json=$(connection_normalize_for_storage "$json")
  password=$(connection_field "$json" password)
  if [[ -z "$password" ]]; then
    jq -c '.password = ""' <<<"$json"
    return 0
  fi

  if [[ -n "$existing_encrypted" ]]; then
    existing_plain=$(decrypt_secret "$existing_encrypted" 2>/dev/null) || existing_plain=""
    if [[ "$password" == "$existing_plain" ]]; then
      jq -c --arg pw "$existing_encrypted" '.password = $pw' <<<"$json"
      return 0
    fi
  fi

  encrypted=$(encrypt_secret "$password") || return 1
  jq -c --arg pw "$encrypted" '.password = $pw' <<<"$json"
}

edit_json_in_vi() {
  local initial="$1"
  local tmp editor result

  tmp=$(safe_mktemp "${TMPDIR:-/tmp}/sshc-edit.XXXXXX") || return 1
  printf '%s\n' "$initial" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }

  editor="${VISUAL:-${EDITOR:-vi}}"
  if [[ -t 0 && -t 1 ]] && [[ -r /dev/tty && -w /dev/tty ]]; then
    if ! "$editor" "$tmp" </dev/tty >/dev/tty; then
      rm -f "$tmp"
      return 1
    fi
  elif ! "$editor" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  result=$(cat "$tmp")
  rm -f "$tmp"

  if ! jq empty <<<"$result" 2>/dev/null; then
    warn "edited content is not valid JSON"
    return 1
  fi

  printf '%s' "$result"
}

terminal_set_bg() {
  local color="$1"

  [[ -n "$color" ]] || return 0
  [[ -t 1 ]] || is_true "${SSHC_FORCE_TTY:-}" || return 0
  printf '\033]11;%s\033\\' "$color"
}

terminal_reset_bg() {
  [[ -t 1 ]] || is_true "${SSHC_FORCE_TTY:-}" || return 0
  printf '\033]111\033\\'
}

terminal_set_title() {
  local title="$1"

  [[ -n "$title" ]] || return 0
  [[ -t 1 ]] || is_true "${SSHC_FORCE_TTY:-}" || return 0
  printf '\033]0;%s\007' "$title"
}

terminal_restore_title() {
  terminal_set_title "$SSHC_TERMINAL_TITLE"
}

SSH_BG_OPTS=()

ssh_bg_local_command_args() {
  local script cmd

  SSH_BG_OPTS=()
  [[ -n "$REMOTE_BG_COLOR" ]] || return 0

  script="${SCRIPT_PATH:-$0}"
  script=$(cd "$(dirname "$script")" && pwd)/$(basename "$script")
  cmd="bash $(printf '%q' "$script") --set-remote-bg $(printf '%q' "$REMOTE_BG_COLOR")"
  SSH_BG_OPTS=(-o PermitLocalCommand=yes -o "LocalCommand=$cmd")
}

shell_escape_single() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

ensure_encryption_key() {
  if [[ -f "$ENCRYPTION_KEY_FILE" ]]; then
    [[ -r "$ENCRYPTION_KEY_FILE" ]] || die "encryption key $ENCRYPTION_KEY_FILE is not readable"
    return 0
  fi

  if ! openssl rand -base64 32 >"$ENCRYPTION_KEY_FILE"; then
    die "failed to create encryption key at $ENCRYPTION_KEY_FILE"
  fi
  chmod 600 "$ENCRYPTION_KEY_FILE" 2>/dev/null || true
}

encrypt_secret() {
  local plaintext="$1"

  ensure_encryption_key
  printf '%s' "$plaintext" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -pass "file:$ENCRYPTION_KEY_FILE" -base64 -A 2>/dev/null
}

decrypt_secret() {
  local ciphertext="$1"

  ensure_encryption_key
  printf '%s' "$ciphertext" | openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
    -pass "file:$ENCRYPTION_KEY_FILE" -base64 -A 2>/dev/null
}

connection_password_decrypted() {
  local json="$1"
  local password decrypted

  password=$(connection_field "$json" password)
  [[ -n "$password" ]] || return 1
  decrypted=$(decrypt_secret "$password") || return 1
  [[ -n "$decrypted" ]] || return 1
  printf '%s' "$decrypted"
}

connection_has_password() {
  local json="$1"
  [[ -n "$(connection_field "$json" password)" ]]
}

connection_has_post_cmd() {
  local json="$1"
  [[ -n "$(connection_field "$json" post_cmd)" ]]
}

connection_post_cmd_remote() {
  local post_cmd="$1"
  if [[ "$post_cmd" == !* ]]; then
    printf '%s' "${post_cmd:1}"
  else
    printf '%s; exec $SHELL -l' "$post_cmd"
  fi
}

ssh_invoke() {
  local conn_json="$1"
  shift
  local password rc ssh_args=() port port_args=()

  port=$(connection_ssh_port "$conn_json")
  if [[ "$port" != "22" && ( "$1" == "ssh" || "$1" == "ssh-copy-id" ) ]]; then
    port_args=(-p "$port")
  fi

  if password=$(connection_password_decrypted "$conn_json"); then
    if ! command -v sshpass &>/dev/null; then
      warn "sshpass is not installed; falling back to key authentication"
    else
      ssh_args=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
      if [[ "$1" == "ssh" ]]; then
        SSHPASS="$password" sshpass -e ssh "${ssh_args[@]}" ${port_args+"${port_args[@]}"} "${@:2}"
      else
        SSHPASS="$password" sshpass -e "$1" ${port_args+"${port_args[@]}"} "${@:2}"
      fi
      rc=$?
      unset SSHPASS password
      return "$rc"
    fi
  fi

  if [[ "$1" == "ssh" ]]; then
    ssh ${port_args+"${port_args[@]}"} "${@:2}"
  else
    "$1" ${port_args+"${port_args[@]}"} "${@:2}"
  fi
}

connect_ssh() {
  local conn_json="$1"
  local target port post_cmd post_esc
  local ssh_cleanup_active=0

  target=$(connection_ssh_target "$conn_json")
  port=$(connection_ssh_port "$conn_json")
  ssh_bg_local_command_args

  connect_ssh_cleanup() {
    [[ -n "$REMOTE_BG_COLOR" ]] && terminal_reset_bg
    terminal_restore_title
  }

  if [[ -t 1 ]]; then
    trap connect_ssh_cleanup EXIT INT TERM
    ssh_cleanup_active=1
  fi

  post_cmd=$(connection_field "$conn_json" post_cmd)

  if [[ -n "$post_cmd" ]]; then
    post_esc=$(shell_escape_single "$(connection_post_cmd_remote "$post_cmd")")
    if [[ "$port" != "22" ]]; then
      ssh_invoke "$conn_json" ssh "${SSH_BG_OPTS[@]}" -p "$port" -t "$target" \
        "${post_esc}"
    else
      ssh_invoke "$conn_json" ssh "${SSH_BG_OPTS[@]}" -t "$target" \
        "${post_esc}"
    fi
  else
    if [[ "$port" != "22" ]]; then
      ssh_invoke "$conn_json" ssh "${SSH_BG_OPTS[@]}" -p "$port" "$target"
    else
      ssh_invoke "$conn_json" ssh "${SSH_BG_OPTS[@]}" "$target"
    fi
  fi

  if ((ssh_cleanup_active)); then
    trap - EXIT INT TERM
    connect_ssh_cleanup
  fi
}

strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

parse_fzf_result() {
  local output="$1"
  local rest

  PARSE_FZF_QUERY="${output%%$'\n'*}"
  rest="${output#*$'\n'}"
  [[ "$rest" == "$output" ]] && rest=""

  PARSE_FZF_KEY="${rest%%$'\n'*}"
  PARSE_FZF_SELECTION="${rest#*$'\n'}"
  [[ "$PARSE_FZF_SELECTION" == "$rest" ]] && PARSE_FZF_SELECTION=""

  [[ -n "$PARSE_FZF_KEY" || -n "$PARSE_FZF_SELECTION" ]]
}

fzf_action_from_key() {
  case "$1" in
    ctrl-n) printf '%s' "ADD" ;;
    ctrl-e) printf '%s' "EDIT" ;;
    ctrl-y) printf '%s' "COPY" ;;
    ctrl-d) printf '%s' "DELETE" ;;
    alt-k) printf '%s' "KEY" ;;
    "") printf '%s' "" ;;
    *) return 1 ;;
  esac
}

connection_display_text() {
  local ref="$1" json

  json=$(connection_from_ref "$ref") || return 1
  connection_display_name "$json"
}

build_display_line() {
  local ref="$1" json display_name user_tags display

  json=$(connection_from_ref "$ref") || return 1
  display_name=$(connection_display_name "$json")
  user_tags=$(connection_tags_display "$json")

  display="$display_name"

  if [[ -n "$user_tags" ]]; then
    display="${display} ${COLOR_TAG}${user_tags}${COLOR_RESET}"
  fi

  printf '%s\t%s' "$display" "$ref"
}

edit_new_connection() {
  local edited stored name

  echo "Enter new SSH connection (${VISUAL:-${EDITOR:-vi}})..."
  edited=$(edit_json_in_vi "$NEW_CONNECTION_TEMPLATE") || {
    echo "Connection editing cancelled."
    return 1
  }

  edited=$(jq -c '.' <<<"$edited")

  name=$(connection_field "$edited" name)
  if connections_name_exists "$CONNECTIONS_FILE" "$name"; then
    echo "Connection name '$name' already exists." >&2
    return 1
  fi

  if ! stored=$(connection_prepare_for_storage "$edited"); then
    warn "could not prepare connection for storage"
    return 1
  fi

  if connections_append "$CONNECTIONS_FILE" "$stored"; then
    echo "Added '$name' to $CONNECTIONS_FILE."
  else
    warn "could not write to $CONNECTIONS_FILE"
    return 1
  fi
}

edit_connection() {
  local ref="$1"
  local path index json edited stored name old_name existing_password new_display

  path=$(connection_path_from_ref "$ref") || return 1
  index=$(connection_index_from_ref "$ref")
  json=$(connections_get_at "$path" "$index") || return 1
  old_name=$(connection_field "$json" name)
  existing_password=$(connection_field "$json" password)

  echo "Edit connection (${VISUAL:-${EDITOR:-vi}})..." >&2
  edited=$(edit_json_in_vi "$(connection_to_editor_json "$json")") || {
    echo "Connection editing cancelled." >&2
    return 1
  }

  edited=$(jq -c '.' <<<"$edited")

  name=$(connection_field "$edited" name)
  if connections_name_exists "$CONNECTIONS_FILE" "$name" "$index"; then
    echo "Connection name '$name' already exists." >&2
    return 1
  fi

  if ! stored=$(connection_prepare_for_storage "$edited" "$existing_password"); then
    warn "could not prepare connection for storage"
    return 1
  fi

  if ! connections_update_at "$path" "$index" "$stored"; then
    warn "could not save updated connection"
    return 1
  fi

  echo "Updated connection in $path." >&2
  new_display=$(connection_display_name "$stored")
  printf '%s' "$new_display"
}

copy_connection() {
  local ref="$1"
  local path index json edited stored name old_name existing_password new_display

  path=$(connection_path_from_ref "$ref") || return 1
  index=$(connection_index_from_ref "$ref")
  json=$(connections_get_at "$path" "$index") || return 1
  old_name=$(connection_field "$json" name)
  existing_password=$(connection_field "$json" password)

  json=$(jq -c --arg name "$old_name (copy)" '.name = $name' <<<"$json")

  echo "Copy connection (${VISUAL:-${EDITOR:-vi}})..." >&2
  edited=$(edit_json_in_vi "$(connection_to_editor_json "$json")") || {
    echo "Connection copying cancelled." >&2
    return 1
  }

  edited=$(jq -c '.' <<<"$edited")

  name=$(connection_field "$edited" name)
  if connections_name_exists "$CONNECTIONS_FILE" "$name"; then
    echo "Connection name '$name' already exists." >&2
    return 1
  fi

  if ! stored=$(connection_prepare_for_storage "$edited" "$existing_password"); then
    warn "could not prepare connection for storage"
    return 1
  fi

  if connections_append "$CONNECTIONS_FILE" "$stored"; then
    echo "Copied to '$name' in $CONNECTIONS_FILE." >&2
    new_display=$(connection_display_name "$stored")
    printf '%s' "$new_display"
  else
    warn "could not write to $CONNECTIONS_FILE"
    return 1
  fi
}

delete_connection() {
  local ref="$1"
  local path index name json

  path=$(connection_path_from_ref "$ref") || return 1
  index=$(connection_index_from_ref "$ref")
  json=$(connections_get_at "$path" "$index") || return 1
  name=$(connection_display_name "$json")

  if connections_remove_at "$path" "$index"; then
    echo "Removed '$name' from $path."
  else
    warn "could not remove connection from $path"
    return 1
  fi
}

format_connections() {
  connections_file_readable "$CONNECTIONS_FILE" || return 0
  jq -r --arg tag "$COLOR_TAG" --arg reset "$COLOR_RESET" '
    .connections
    | to_entries
    | map(
        .key as $i | .value as $c
        | {
            ref:  ("saved:" + ($i | tostring)),
            name: ($c.name // ""),
            host: ($c.host // ""),
            user: ($c.user // ""),
            tags: (
              ($c.tags_string // null) as $t
              | if   ($t | type) == "array"  then ($t | join(" "))
                elif ($t | type) == "string" then $t
                else "" end
            )
          }
      )
    | map(.display = (
        if   .name != ""                 then .name
        elif .user != "" and .host != "" then (.user + "@" + .host)
        elif .host != ""                 then .host
        else "?" end
      ))
    | sort_by(.display | ascii_downcase)
    | .[]
    | (if .tags != ""
       then .display + " " + $tag + .tags + $reset
       else .display end) + "\t" + .ref
  ' "$CONNECTIONS_FILE"
}

filtered_position_of() {
  local shown="$1" query="$2"
  local n=0 line stripped

  [[ -n "$shown" ]] || return 1

  while IFS= read -r line; do
    n=$((n + 1))
    stripped=$(strip_ansi "$line")
    stripped="${stripped%%$'\t'*}"
    if [[ "$stripped" == "$shown" || "$stripped" == "$shown "* ]]; then
      printf '%s' "$n"
      return 0
    fi
  done < <(format_connections | fzf --ansi --color="$FZF_COLOR_SCHEME" --with-nth 1..1 --filter="$query" 2>/dev/null)

  return 1
}

cache_key_for_target() {
  printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | awk '{print $1}'
}

is_in_known_hosts() {
  local host="$1"
  [[ -f "$KNOWN_HOSTS_FILE" && -r "$KNOWN_HOSTS_FILE" ]] || return 1
  ssh-keygen -F "$host" -f "$KNOWN_HOSTS_FILE" &>/dev/null
}

kill_preview_jobs() {
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done < <(jobs -p)
}

run_with_timeout() {
  local secs="$1"
  local pid deadline
  shift

  deadline=$((SECONDS + secs))
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -TERM "$pid" 2>/dev/null
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.05
  done
  wait "$pid"
}

check_icmp() {
  local host="$1"

  [[ -n "$host" ]] || return 1
  run_with_timeout 2 ping -c 1 "$PING_WAIT_FLAG" 2 "$host" &>/dev/null
}

check_ssh_available() {
  local host="$1"
  local port="${2:-22}"

  [[ -n "$host" ]] || return 1

  if command -v nc &>/dev/null; then
    run_with_timeout "$PREVIEW_NETWORK_CHECK_TIMEOUT" nc -z "$NC_WAIT_FLAG" 2 "$host" "$port" &>/dev/null
    return $?
  fi

  run_with_timeout "$PREVIEW_NETWORK_CHECK_TIMEOUT" bash -c "echo >/dev/tcp/$host/$port" &>/dev/null
}

key_auth_cache_path() {
  [[ -n "$KEY_AUTH_CACHE_DIR" && -d "$KEY_AUTH_CACHE_DIR" ]] || return 1
  printf '%s/%s' "$KEY_AUTH_CACHE_DIR" "$(cache_key_for_target "$1")"
}

check_key_auth() {
  local target="$1"
  local port="${2:-22}"
  local cache_file rc port_args=()

  if [[ "$port" != "22" ]]; then
    port_args=(-p "$port")
  fi

  if cache_file=$(key_auth_cache_path "$target"); then
    if [[ -f "$cache_file" ]]; then
      case "$(cat "$cache_file")" in
        yes) return 0 ;;
        no) return 1 ;;
      esac
    fi
  fi

  run_with_timeout "$PREVIEW_KEY_CHECK_TIMEOUT" ssh \
    ${port_args+"${port_args[@]}"} \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ConnectionAttempts=1 \
    -o GSSAPIAuthentication=no \
    -o StrictHostKeyChecking=no \
    "$target" exit </dev/null &>/dev/null
  rc=$?

  if ((rc == 0)); then
    [[ -n "$cache_file" ]] && printf 'yes' >"$cache_file" 2>/dev/null
    return 0
  fi

  if ((rc != 124)) && [[ -n "$cache_file" ]]; then
    printf 'no' >"$cache_file" 2>/dev/null
  fi
  return "$rc"
}

preview_write_check_result() {
  local file="$1"
  local rc=1

  "$2" "${@:3}"
  rc=$?

  case "$rc" in
    0) printf 'yes' >"$file" ;;
    124) printf 'timeout' >"$file" ;;
    *) printf 'no' >"$file" ;;
  esac
}

preview_status_line() {
  local label="$1"
  local state="$2"

  case "$state" in
    loading)
      printf '%s: %s...%s\n' "$label" "$COLOR_DIM" "$COLOR_RESET"
      ;;
    yes)
      printf '%s: %sYes%s\n' "$label" "$COLOR_GREEN" "$COLOR_RESET"
      ;;
    no)
      printf '%s: %sNo%s\n' "$label" "$COLOR_RED" "$COLOR_RESET"
      ;;
    timeout)
      printf '%s: %sTimeout%s\n' "$label" "$COLOR_YELLOW" "$COLOR_RESET"
      ;;
  esac
}

preview_read_check() {
  local file="$1"

  [[ -f "$file" ]] || return 1
  cat "$file"
}

preview_key_cached_state() {
  local target="$1"
  local cache_file cached

  cache_file=$(key_auth_cache_path "$target") || return 1
  [[ -f "$cache_file" ]] || return 1
  cached=$(cat "$cache_file")
  [[ "$cached" == "yes" || "$cached" == "no" ]] || return 1
  printf '%s' "$cached"
}

preview_apply_results_from_files() {
  local tmp="$1"

  [[ -f "$tmp/icmp" ]] && icmp_state=$(preview_read_check "$tmp/icmp")
  [[ -f "$tmp/ssh" ]] && ssh_state=$(preview_read_check "$tmp/ssh")
  [[ -f "$tmp/key" ]] && key_state=$(preview_read_check "$tmp/key")
}

preview_finalize_loading_states() {
  if [[ "${icmp_state:-}" == "loading" ]]; then icmp_state=timeout; fi
  if [[ "${ssh_state:-}" == "loading" ]]; then ssh_state=timeout; fi
  if [[ "${key_state:-}" == "loading" ]]; then key_state=timeout; fi
}

preview_states_signature() {
  printf '%s|%s|%s|%s' "$icmp_state" "$ssh_state" "$key_state" "$known_state"
}

preview_render() {
  local resolved_conn="$1"
  local icmp_state="$2"
  local ssh_state="$3"
  local key_state="$4"
  local password_state="$5"
  local known_state="$6"
  local command_state="$7"

  printf '\033[H\033[2J'
  printf '%s\n' "$resolved_conn"
  preview_status_line "ICMP availability" "$icmp_state"
  preview_status_line "SSH availability" "$ssh_state"
  preview_status_line "Key exchanged" "$key_state"
  preview_status_line "Password set" "$password_state"
  preview_status_line "Known host" "$known_state"
  preview_status_line "Command set" "$command_state"
}

preview_connection() {
  local display="$1"
  local ref conn_json resolved_conn host port tmp
  local icmp_state=loading ssh_state=loading key_state=loading password_state=no known_state=no command_state=no
  local deadline last_signature=""

  trap 'exit 0' TERM

  ref=$(connection_from_display "$display") || return 0
  conn_json=$(connection_from_ref "$ref") || return 0
  resolved_conn=$(connection_ssh_target "$conn_json")
  host=$(connection_field "$conn_json" host)
  port=$(connection_ssh_port "$conn_json")

  [[ -n "$host" ]] || return 0

  connection_has_password "$conn_json" && password_state=yes
  connection_has_post_cmd "$conn_json" && command_state=yes
  is_in_known_hosts "$host" && known_state=yes

  if cached_key_state=$(preview_key_cached_state "$resolved_conn"); then
    key_state="$cached_key_state"
  fi

  preview_render "$resolved_conn" "$icmp_state" "$ssh_state" "$key_state" "$password_state" "$known_state" "$command_state"
  sleep "$PREVIEW_DEBOUNCE_SECS"

  tmp=$(safe_mktemp_dir) || return 0
  trap 'kill_preview_jobs; rm -rf "$tmp"' EXIT INT TERM

  [[ "$icmp_state" == "loading" ]] &&
    (preview_write_check_result "$tmp/icmp" check_icmp "$host") &
  [[ "$ssh_state" == "loading" ]] &&
    (preview_write_check_result "$tmp/ssh" check_ssh_available "$host" "$port") &
  [[ "$key_state" == "loading" ]] &&
    (preview_write_check_result "$tmp/key" check_key_auth "$resolved_conn" "$port") &

  deadline=$((SECONDS + PREVIEW_KEY_CHECK_TIMEOUT + 1))
  last_signature=$(preview_states_signature)

  while ((SECONDS < deadline)); do
    preview_apply_results_from_files "$tmp"

    if [[ "$(preview_states_signature)" != "$last_signature" ]]; then
      preview_render "$resolved_conn" "$icmp_state" "$ssh_state" "$key_state" "$password_state" "$known_state" "$command_state"
      last_signature=$(preview_states_signature)
    fi

    [[ "$icmp_state" != "loading" && "$ssh_state" != "loading" && "$key_state" != "loading" ]] && break
    sleep 0.05
  done

  kill_preview_jobs
  wait 2>/dev/null || true
  preview_apply_results_from_files "$tmp"
  preview_finalize_loading_states
  preview_render "$resolved_conn" "$icmp_state" "$ssh_state" "$key_state" "$password_state" "$known_state" "$command_state"
}

# ---------------------------------------------------------------------------
# Bootstrap and main entry
# ---------------------------------------------------------------------------

sshc_bootstrap() {
  SSHC_SCRIPT_DIR=$(cd "$(dirname "$(resolve_script_path)")" && pwd)
  SSHC_DATA_DIR="${SSHC_DATA_DIR:-$HOME/.sshc}"
  seed_sshc_data_dir
  load_sshc_config "$SSHC_DATA_DIR"
  migrate_legacy_data_files
  SCRIPT_PATH=$(resolve_script_path)
  SSHC_TERMINAL_TITLE=$(basename "$SCRIPT_PATH")
  KEY_AUTH_CACHE_DIR=""
}

sshc_main() {
  ensure_connections_json "$CONNECTIONS_FILE"

  if ! command -v jq &>/dev/null; then
    die "'jq' is not installed. Please install it and try again."
  fi

  if ! command -v fzf &>/dev/null; then
    die "'fzf' is not installed. Please install it and try again."
  fi

  if [[ "${1:-}" == "--preview" ]]; then
    KEY_AUTH_CACHE_DIR="${SSHC_KEY_AUTH_CACHE_DIR:-}"
    preview_connection "${2:-}"
    return 0
  fi

  if [[ "${1:-}" == "--set-remote-bg" ]]; then
    terminal_set_bg "${2:-}"
    return 0
  fi

  KEY_AUTH_CACHE_DIR=$(safe_mktemp_dir)
  trap 'rm -rf "$KEY_AUTH_CACHE_DIR"' EXIT
  export SSHC_KEY_AUTH_CACHE_DIR="$KEY_AUTH_CACHE_DIR"
  SSH_RESOLVED_USER="${USER:-$(whoami)}"

  terminal_restore_title

  # ---------------------------------------------------------------------------
  # Main loop: fzf picker + actions
  # ---------------------------------------------------------------------------

  local search_query="" restore_shown=""
  local fzf_output action selected_ref selected_json
  local restore_pos pos_bind new_restore target port

  while true; do
  pos_bind=()
  if [[ -n "$restore_shown" ]]; then
    if restore_pos=$(filtered_position_of "$restore_shown" "$search_query"); then
      pos_bind=(--bind "load:pos($restore_pos)")
    fi
    restore_shown=""
  fi

  fzf_output=$(format_connections | fzf \
    --delimiter=$'\t' \
    --no-sort \
    --color="$FZF_COLOR_SCHEME" \
    --with-nth 1..1 \
    --preview "stdbuf -oL bash $(printf '%q' "$SCRIPT_PATH") --preview {}" \
    --preview-window 'up:7:nowrap' \
    --ansi \
    --prompt="Select an SSH connection: " \
    --layout=reverse \
    --pointer '->' \
    --header=$'[ Ctrl-N: Add | Ctrl-E: Edit | Ctrl-Y: Copy | Ctrl-D: Delete | Alt-K: Key | Esc: Exit ]' \
    --print-query \
    --query="$search_query" \
    "${pos_bind[@]}" \
    --expect=ctrl-n,ctrl-e,ctrl-y,ctrl-d,alt-k)

  if ! parse_fzf_result "$fzf_output"; then
    echo "Exiting."
    break
  fi

  search_query="$PARSE_FZF_QUERY"

  if ! action=$(fzf_action_from_key "$PARSE_FZF_KEY"); then
    echo "Unknown key: $PARSE_FZF_KEY"
    continue
  fi

  selected_ref=""
  selected_json=""

  if [[ -n "$PARSE_FZF_SELECTION" ]]; then
    if ! selected_ref=$(connection_from_display "$PARSE_FZF_SELECTION"); then
      warn "could not resolve selection; try again"
      continue
    fi
    selected_json=$(connection_from_ref "$selected_ref") || {
      warn "could not load selected connection; try again"
      continue
    }
  fi

  if [[ -n "$selected_ref" && "$action" != "DELETE" && "$action" != "EDIT" && "$action" != "COPY" ]]; then
    restore_shown=$(connection_display_text "$selected_ref")
  fi

  case "$action" in
    ADD)
      edit_new_connection
      ;;
    EDIT)
      if [[ -n "$selected_ref" ]]; then
        if new_restore=$(edit_connection "$selected_ref"); then
          [[ -n "$new_restore" ]] && restore_shown="$new_restore"
        fi
      else
        echo "No connection selected for editing."
      fi
      ;;
    COPY)
      if [[ -n "$selected_ref" ]]; then
        if new_restore=$(copy_connection "$selected_ref"); then
          [[ -n "$new_restore" ]] && restore_shown="$new_restore"
        fi
      else
        echo "No connection selected for copying."
      fi
      ;;
    DELETE)
      if [[ -n "$selected_ref" ]]; then
        delete_connection "$selected_ref"
      else
        echo "No connection selected for deletion."
      fi
      ;;
    KEY)
      if [[ -n "$selected_json" ]]; then
        target=$(connection_ssh_target "$selected_json")
        port=$(connection_ssh_port "$selected_json")
        echo "Adding SSH key to $target..."
        if [[ "$port" != "22" ]]; then
          ssh_invoke "$selected_json" ssh-copy-id -p "$port" "$target"
        else
          ssh_invoke "$selected_json" ssh-copy-id "$target"
        fi
      else
        echo "No connection selected for adding key."
      fi
      ;;
    "")
      if [[ -n "$selected_json" ]]; then
        target=$(connection_ssh_target "$selected_json")
        echo "Connecting to $target..."
        connect_ssh "$selected_json"
      else
        echo "Exiting."
        break
      fi
      ;;
    *)
      echo "Unknown action. Exiting."
      break
      ;;
  esac
  done
}

if [[ "${SSHC_LIB_ONLY:-}" == 1 ]]; then
  :
elif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sshc_bootstrap
  sshc_main "$@"
fi
