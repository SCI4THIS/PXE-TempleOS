#!/bin/sh
set -eu

printf '%s\n' 'Copying image staging files to the bind-mounted web root'
cp -a /tmp/staging/* /

cp /rpi3b-pxe-nginx.conf /etc/nginx/nginx.conf

printf '%s\n' 'Starting NGINX server'
exec nginx -g 'daemon off;'
