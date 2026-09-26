#!/usr/bin/env bash

export PREFIX=derevyanko-11
export ZONE=ru-central1-b
export CIDR=10.21.1.0/24
export DISK_SIZE=20
export IMAGE=debian-12

yc vpc network create --name "$PREFIX-net"
yc vpc subnet create --name "$PREFIX-subnet" --network-name "$PREFIX-net" --zone "$ZONE" --range "$CIDR"

for i in app-1 app-2; do
  yc compute instance create \
    --name "$PREFIX-$i" \
    --zone "$ZONE" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE",type=network-hdd,size="$DISK_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
    --hostname "$PREFIX-$i" \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --labels created-by=cli
done

yc compute instance list
