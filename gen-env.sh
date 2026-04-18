#!/bin/sh

cat > .env << EOF
PXE_SERVER_IP=$(hostname -I | awk '{print $1}')
UID=$(id -u)
GID=$(id -g)
EOF
