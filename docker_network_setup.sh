#!/bin/bash

set -uo pipefail

# .envから必須のCIDRを読み込む
read_cidr() {
  local name="$1"
  local value
  value=$(grep "^${name}=" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  if [[ -z "${value}" ]]; then
    echo "Error: ${name} is not set in .env." >&2
    exit 1
  fi
  echo "${value}"
}

# アプリを追加したときに既存ホストで再実行できるよう、作成済みのネットワークは飛ばす
create_network() {
  local name="$1"
  shift
  if docker network inspect "${name}" >/dev/null 2>&1; then
    echo "${name} already exists, skipped."
    return
  fi
  docker network create "$@" "${name}" || exit 1
}

# アプリごとのネットワーク。アプリを追加するときは、.envとcompose.yamlと合わせてここにも追加する
TRAEFIK_NETWORK_1_CIDR=$(read_cidr TRAEFIK_NETWORK_1_CIDR) || exit 1
create_network traefik_network_1 --subnet="${TRAEFIK_NETWORK_1_CIDR}"
TRAEFIK_NETWORK_2_CIDR=$(read_cidr TRAEFIK_NETWORK_2_CIDR) || exit 1
create_network traefik_network_2 --subnet="${TRAEFIK_NETWORK_2_CIDR}"
