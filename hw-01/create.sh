#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PREFIX=${PREFIX:-derevyanko-11}
ENV_NAME=${ENV_NAME:-test}
ZONE_A=${ZONE_A:-ru-central1-b}
ZONE_B=${ZONE_B:-ru-central1-d}
CIDR_A=${CIDR_A:-10.21.1.0/24}
CIDR_B=${CIDR_B:-10.21.2.0/24}
APP_PORT=${APP_PORT:-8033}
GREETING=${GREETING:-devlab}
WEB_COUNT=${WEB_COUNT:-2}
BOOT_SIZE=${BOOT_SIZE:-20}
IMAGE_FAMILY=${IMAGE_FAMILY:-ubuntu-2404-lts}
SSH_KEY_FILE=${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=${2:?"не задано значение для $1"};    shift 2 ;;
    --env) ENV_NAME=${2:?"не задано значение для $1"};  shift 2 ;;
    --web-count) WEB_COUNT=${2:?"не задано значение для $1"}; shift 2 ;;
    --port) APP_PORT=${2:?"не задано значение для $1"};  shift 2 ;;
    --greeting) GREETING=${2:?"не задано значение для $1"};  shift 2 ;;
    --zone-a) ZONE_A=${2:?"не задано значение для $1"};    shift 2 ;;
    --zone-b) ZONE_B=${2:?"не задано значение для $1"};    shift 2 ;;
    --cidr-a) CIDR_A=${2:?"не задано значение для $1"};    shift 2 ;;
    --cidr-b) CIDR_B=${2:?"не задано значение для $1"};    shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$WEB_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "--web-count должно быть целым числом больше нуля, получено: $WEB_COUNT" >&2
  exit 1
fi

LABELS="env=$ENV_NAME,owner=$PREFIX"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")
CIDRS=("$CIDR_A" "$CIDR_B")

exists_network() { yc vpc network get "$1" &>/dev/null; }
exists_subnet() { yc vpc subnet get "$1" &>/dev/null; }
exists_gateway() { yc vpc gateway get "$1" &>/dev/null; }
exists_rt() { yc vpc route-table get "$1" &>/dev/null; }
exists_instance() { yc compute instance get "$1" &>/dev/null; }
exists_tg() { yc load-balancer target-group get --name "$1" &>/dev/null; }
exists_lb() { yc load-balancer network-load-balancer get --name "$1" &>/dev/null; }
skip() { echo "$1 уже есть, пропускаю"; }

echo "==> Сеть"
if exists_network "$PREFIX-net"; then
  skip "$PREFIX-net"
else
  yc vpc network create --name "$PREFIX-net" --labels "$LABELS"
fi

echo "==> Подсети"
create_subnet() {
  local name=$1 zone=$2 cidr=$3
  if exists_subnet "$name"; then
    skip "$name"
    return 0
  fi
  yc vpc subnet create --name "$name" --network-name "$PREFIX-net" \
    --zone "$zone" --range "$cidr" --labels "$LABELS"
}
for i in 0 1; do
  create_subnet "${SUBNETS[$i]}" "${ZONES[$i]}" "${CIDRS[$i]}"
done

echo "==> NAT-шлюз"
if exists_gateway "$PREFIX-nat"; then
  skip "$PREFIX-nat"
else
  yc vpc gateway create --name "$PREFIX-nat" --labels "$LABELS"
fi
GW_ID=$(yc vpc gateway get "$PREFIX-nat" --format json | jq -r .id)

echo "==> Таблица маршрутизации"
if exists_rt "$PREFIX-rt"; then
  skip "$PREFIX-rt"
else
  yc vpc route-table create --name "$PREFIX-rt" --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" --labels "$LABELS"
fi
RT_ID=$(yc vpc route-table get "$PREFIX-rt" --format json | jq -r .id)

CURRENT_RT=$(yc vpc subnet get "${SUBNETS[0]}" --format json | jq -r '.route_table_id // ""')
if [ "$CURRENT_RT" = "$RT_ID" ]; then
  echo "$PREFIX-rt уже привязана к ${SUBNETS[0]}, пропускаю"
else
  yc vpc subnet update "${SUBNETS[0]}" --route-table-name "$PREFIX-rt"
fi

echo "==> Файл настройки из шаблона"
SSH_KEY=$(cat "$SSH_KEY_FILE")
export APP_PORT GREETING SSH_KEY
CLOUD_INIT="$SCRIPT_DIR/cloud-init.yaml"
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < "$SCRIPT_DIR/cloud-init.tpl.yaml" > "$CLOUD_INIT"

echo "==> Веб-серверы"
create_vm() {
  local name=$1 zone=$2 subnet=$3 access=$4

  if exists_instance "$name"; then
    # прерываемую машину облако может остановить
    local status
    status=$(yc compute instance get "$name" --format json | jq -r .status)
    if [ "$status" = "STOPPED" ]; then
      echo "$name остановлена, запускаю"
      yc compute instance start "$name"
    else
      skip "$name"
    fi
    return 0
  fi

  local nic="subnet-name=$subnet"
  if [ "$access" = "public" ]; then
    nic="$nic,nat-ip-version=ipv4"
  fi

  yc compute instance create \
    --name "$name" \
    --zone "$zone" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk "name=$name-boot,image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE" \
    --network-interface "$nic" \
    --hostname "$name" \
    --labels "$LABELS" \
    --metadata-from-file user-data="$CLOUD_INIT"
}

for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  create_vm "$PREFIX-web-$i" "${ZONES[$idx]}" "${SUBNETS[$idx]}" "public"
done

echo "==> Сервер приложения (без публичного адреса)"
create_vm "$PREFIX-app-1" "$ZONE_A" "$PREFIX-subnet-a" "private"

echo "==> Целевая группа"
TARGETS=""
for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-web-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done

if exists_tg "$PREFIX-tg"; then
  # группа уже есть, то не добавляем только тех, кого в ней нет
  skip "$PREFIX-tg"
else
  yc load-balancer target-group create --name "$PREFIX-tg" --labels "$LABELS" $TARGETS
fi

echo "==> Балансировщик"
if exists_lb "$PREFIX-lb"; then
  skip "$PREFIX-lb"
else
  TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)
  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --region-id ru-central1 \
    --labels "$LABELS" \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/
fi

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json \
  | jq -r '.listeners[0].address')

echo "==> Готово"
yc compute instance list
yc load-balancer network-load-balancer list
echo "Балансировщик: http://$LB_IP/"