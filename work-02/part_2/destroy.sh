#!/usr/bin/env bash
set -euo pipefail

PREFIX=${PREFIX:-derevyanko-11}

exists_instance()  { yc compute instance get "$1" &>/dev/null; }
exists_disk()      { yc compute disk get "$1" &>/dev/null; }
exists_tg()        { yc load-balancer target-group get --name "$1" &>/dev/null; }
exists_lb()        { yc load-balancer network-load-balancer get --name "$1" &>/dev/null; }
exists_subnet()    { yc vpc subnet get "$1" &>/dev/null; }
exists_network()   { yc vpc network get "$1" &>/dev/null; }

echo "==> Балансировщик"
if exists_lb "$PREFIX-lb"; then
  yc load-balancer network-load-balancer delete "$PREFIX-lb"
else
  echo "$PREFIX-lb уже отсутствует, пропускаю"
fi

echo "==> Целевая группа"
if exists_tg "$PREFIX-tg"; then
  yc load-balancer target-group delete "$PREFIX-tg"
else
  echo "$PREFIX-tg уже отсутствует, пропускаю"
fi

echo "==> Машины (ищем по префиксу в облаке)"
mapfile -t VM_NAMES < <(yc compute instance list --format json \
  | jq -r '.[].name')

if [ "${#VM_NAMES[@]}" -eq 0 ]; then
  echo "Машин с префиксом $PREFIX-app- не найдено"
else
  for name in "${VM_NAMES[@]}"; do
    echo "Удаляю $name"
    if ! yc compute instance delete "$name"; then
      echo "ОШИБКА при удалении $name (см. вывод yc выше)"
    fi
  done
fi

echo "==> Диск"
if exists_disk "$PREFIX-data"; then
  yc compute disk delete "$PREFIX-data"
else
  echo "$PREFIX-data уже отсутствует, пропускаю"
fi

echo "==> Подсети"
for subnet in "$PREFIX-subnet-a" "$PREFIX-subnet-b"; do
  if exists_subnet "$subnet"; then
    yc vpc subnet delete "$subnet"
  else
    echo "$subnet уже отсутствует, пропускаю"
  fi
done

echo "==> Сеть"
if exists_network "$PREFIX-net"; then
  yc vpc network delete "$PREFIX-net"
else
  echo "$PREFIX-net уже отсутствует, пропускаю"
fi

echo "==> Готово"
yc compute instance list
yc vpc network list
yc vpc subnet list
yc compute disk list
yc load-balancer network-load-balancer list
