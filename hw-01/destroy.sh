#!/usr/bin/env bash
set -euo pipefail

PREFIX=${PREFIX:-derevyanko-11}

drop() {
  local kind="$1" name
  yc $kind list --format json \
    | jq -r ".[] | select(.name != null and (.name | startswith(\"$PREFIX\"))) | .name" \
    | while read -r name; do
        echo "Удаляю $kind $name"
        yc $kind delete "$name"
      done
}

echo "==> Балансировщики"
drop "load-balancer network-load-balancer"

echo "==> Целевые группы"
drop "load-balancer target-group"

echo "==> Машины"
drop "compute instance"

echo "==> Диски"
drop "compute disk"

echo "==> Адреса"
drop "vpc address"

yc vpc subnet list --format json \
  | jq -r ".[] | select(.name != null and (.name | startswith(\"$PREFIX\"))) | .name" \
  | while read -r name; do yc vpc subnet update --name "$name" --route-table-id "" >/dev/null 2>&1 || true; done

echo "==> Таблицы маршрутизации"
drop "vpc route-table"

echo "==> NAT-шлюзы"
drop "vpc gateway"

echo "==> Подсети"
drop "vpc subnet"

echo "==> Сети"
drop "vpc network"

echo "==> Осталось ресурсов с префиксом $PREFIX"
for kind in "compute instance" "compute disk" "vpc address" "vpc subnet" \
    "vpc network" "load-balancer network-load-balancer" \
    "load-balancer target-group"; do
  printf "%-42s " "$kind"

  yc $kind list --format json \
    | jq -r "[.[] | select(.name != null and (.name | startswith(\"$PREFIX\")))] | length"
done
