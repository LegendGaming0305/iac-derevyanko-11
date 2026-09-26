#!/usr/bin/env bash

export PREFIX=derevyanko-11

for i in app-1 app-2; do
  yc compute instance delete "$PREFIX-$i"
done

yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"

yc compute instance list
yc vpc network list
yc compute disk list
