#!/bin/sh

docker run --rm -p 445:445 -p 139:139 -v ./build:/shared alpine-samba
