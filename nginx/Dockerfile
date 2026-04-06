FROM alpine:3.20

RUN apk add --no-cache nginx

ENV STAGING_DIR=/tmp/staging

ARG PXE_SERVER_IP
ARG MENU_TIMEOUT=5000
ARG PROXY_PASS_TTL=30d

RUN mkdir -p /var/cache/nginx

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/etc/nginx/nginx.conf <<EOF
worker_processes 1;
events {
  worker_connections 1024;
}
http {
  include mime.types;
  default_type application/octet-stream;
  access_log /dev/stderr;
  error_log /dev/stderr;
  sendfile on;
  keepalive_timeout 65;
  proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=apkcache:10m max_size=1g inactive=${PROXY_PASS_TTL} use_temp_path=off;
  server {
    listen 80;
    root /var/www/htdocs;
    location /dl-cdn/ {
      rewrite ^/dl-cdn/(.*)\$ /\$1 break;
      try_files \$uri @mirror;
    }
    location @mirror {
      proxy_pass https://dl-cdn.alpinelinux.org;
      proxy_cache apkcache;
      proxy_cache_valid 200 302 ${PROXY_PASS_TTL};
      proxy_cache_valid 404 1m;
      add_header X-Cache-Status \$upstream_cache_status;
    }
  }
}
EOF

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/var/www/htdocs/x86_64-efi/boot.ipxe <<EOF
#!ipxe
menu Network Boot Menu
item --key s shell iPXE shell
choose --timeout ${MENU_TIMEOUT} --default shell target || goto shell
goto \${target}

:shell
shell
EOF

RUN install -Dm700 /dev/stdin /start.sh <<EOF
#!/bin/sh
echo "Copying files from staging to root"
cp -a ${STAGING_DIR}/* /
echo "Staging NGINX server"
exec nginx -g "daemon off;"
EOF

CMD ["/start.sh"]

