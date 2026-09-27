#!/usr/bin/env bash
set -euo pipefail


LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" \
  --format json | jq -r '.listeners[0].address')
PREFIX=${PREFIX:-derevyanko-11}
TARGET_HOST=${2:-$PREFIX-app-1}
GREETING=${GREETING:-devlab}

TARGET_IP=$(yc compute instance get "$TARGET_HOST" --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)

echo "==> До остановки nginx на $TARGET_HOST"
yc load-balancer network-load-balancer target-states \
  --name "$PREFIX-lb" --target-group-id "$TG_ID"

for i in $(seq 1 10); do
  curl -s "http://$LB_IP" | grep -m1 -o "${GREETING} on [a-z0-9-]*"
done
echo

echo "==> Останавливаю nginx на $TARGET_HOST ($TARGET_IP)"
ssh -o StrictHostKeyChecking=no "student@$TARGET_IP" "sudo systemctl stop nginx"
sleep 10

echo "===> После остановки nginx"
yc load-balancer network-load-balancer target-states \
  --name "$PREFIX-lb" --target-group-id "$TG_ID"

for i in $(seq 1 10); do
  curl -s "http://$LB_IP" | grep -m1 -o "${GREETING} on [a-z0-9-]*"
done
echo

echo "==> Возвращаю nginx на $TARGET_HOST"
ssh -o StrictHostKeyChecking=no "student@$TARGET_IP" "sudo systemctl start nginx"
sleep 10

echo "==> После восстановления nginx"
yc load-balancer network-load-balancer target-states \
  --name "$PREFIX-lb" --target-group-id "$TG_ID"

for i in $(seq 1 10); do
  curl -s "http://$LB_IP" | grep -m1 -o "${GREETING} on [a-z0-9-]*"
done
echo