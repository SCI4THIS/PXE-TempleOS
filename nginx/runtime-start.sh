#!/bin/sh
set -eu

saved_boot=/tmp/rpi3b-pxe-boot.ipxe

if [ -f /var/www/htdocs/x86_64-efi/boot.ipxe ]; then
    cp /var/www/htdocs/x86_64-efi/boot.ipxe "$saved_boot"
fi

printf '%s\n' 'Copying image staging files to the bind-mounted web root'
cp -a /tmp/staging/* /

if [ -f "$saved_boot" ]; then
    mkdir -p /var/www/htdocs/x86_64-efi
    cp "$saved_boot" /var/www/htdocs/x86_64-efi/boot.ipxe
fi

cp /rpi3b-pxe-nginx.conf /etc/nginx/nginx.conf

printf '%s\n' 'Starting NGINX server'
exec nginx -g 'daemon off;'
