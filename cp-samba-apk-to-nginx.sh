#!/bin/sh
mkdir -p nginx/www/apk
cp -r samba/shared/apk/packages/abuild/* nginx/www/apk
cp samba/shared/abuild.rsa.pub nginx/www/apk/
