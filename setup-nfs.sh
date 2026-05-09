#!/bin/sh

apt install nfs-kernel-server

echo "$(pwd)/samba/shared 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

exportfs -rav
systemctl restart nfs-kernel-server
