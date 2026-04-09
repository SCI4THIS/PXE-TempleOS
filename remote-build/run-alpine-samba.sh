#!/bin/sh

docker run --rm --network=host -v ./shared:/shared alpine-samba
