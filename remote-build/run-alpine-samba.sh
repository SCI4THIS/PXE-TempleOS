#!/bin/sh

docker run --rm --network=host -v ./build:/shared alpine-samba
