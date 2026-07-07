#!/usr/bin/env bats

load '../test_helper'
load_bats_libraries

@test "encrypt_secret and decrypt_secret roundtrip" {
  local cipher plain
  cipher=$(encrypt_secret "hello-world")
  [[ -n "$cipher" ]]
  plain=$(decrypt_secret "$cipher")
  assert_equal "hello-world" "$plain"
}

@test "ensure_encryption_key creates readable key file" {
  rm -f "$ENCRYPTION_KEY_FILE"
  ensure_encryption_key
  [[ -f "$ENCRYPTION_KEY_FILE" ]]
  [[ -r "$ENCRYPTION_KEY_FILE" ]]
}

@test "connection_password_decrypted returns plaintext" {
  local json cipher
  cipher=$(encrypt_secret "pw123")
  json=$(jq -nc --arg pw "$cipher" '{name:"x",host:"h",user:"u",password:$pw}')
  assert_equal "pw123" "$(connection_password_decrypted "$json")"
}
