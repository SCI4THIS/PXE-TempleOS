#!/bin/sh

docker build \
  --build-arg UID=$(id -u) \
  --build-arg GID=$(id -g) \
  --network=host \
  -t alpine-samba \
  .
