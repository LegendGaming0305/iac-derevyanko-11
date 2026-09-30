#!/usr/bin/env bash
set -euo pipefail

PREFIX=${PREFIX:-derevyanko-11}
APP_PORT=${APP_PORT:-8033}
GREETING=${GREETING:-devlab}

fail=0
ok()   { echo "✓ $*"; }
bad()  { echo "✗ $*"; fail=1; }

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json 2>/dev/null \
    | jq -r '.listeners[0].address')

if [[ -z "${LB_IP:-}" || "$LB_IP" == "null" ]]; then
  bad "балансировщик $PREFIX-lb не найден"
  exit 1
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LB_IP" || true)
if [[ "$code" == "200" ]]; then
  ok "балансировщик отвечает: $code"
else
  bad "балансировщик отвечает: ${code:-нет ответа}"
fi

hosts=$(
    for _ in $(seq 1 12); do
        curl -s --max-time 5 "http://$LB_IP" | grep -o "$GREETING on [a-z0-9-]*" || true
    done | awk '{print $NF}' | sort -u | tr '\n' ' '
)
count=$(wc -w <<< "$hosts")

if [[ "$count" -gt 1 ]]; then
  ok "ответили машины: ${hosts% }"
else
  bad "ответила одна машина: ${hosts:-нет ответов}"
fi

WEB_IP=$(yc compute instance get "$PREFIX-web-1" --format json 2>/dev/null \
    | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
APP_IP=$(yc compute instance get "$PREFIX-app-1" --format json 2>/dev/null \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
answer=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
    "student@$WEB_IP" "curl -s --max-time 5 http://$APP_IP:$APP_PORT" 2>/dev/null || true)

if grep -q "$GREETING" <<< "$answer"; then
  ok "сервер приложения отвечает с $PREFIX-web-1: $answer"
else
  bad "сервер приложения недоступен с $PREFIX-web-1"
fi

if curl -s --max-time 5 -o /dev/null "http://$APP_IP:$APP_PORT"; then
  bad "сервер приложения виден снаружи — это нарушение требования"
else
  ok "сервер приложения снаружи недоступен"
fi

exit "$fail"
