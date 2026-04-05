FROM alpine:3.20

RUN apk add --no-cache lighttpd

ENV STAGING_DIR=/tmp/staging
ARG PXE_SERVER_IP
ARG MENU_TIMEOUT=5000

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
  "mod_access",
  "mod_accesslog"
)

mimetype.assign = (
  ".gz" => "application/gzip",
  ".tgz" => "application/gzip",
  ".tar.gz" => "application/gzip"
)

server.document-root = "/var/www/localhost/htdocs"
server.port = 80

accesslog.filename = "/dev/stderr"
server.errorlog = "/dev/stderr"
EOF

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/var/www/localhost/htdocs/x86_64-efi/boot.ipxe <<EOF
#!ipxe

set baseurl http://${PXE_SERVER_IP}

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
echo "Starting lighttpd server"
exec lighttpd -D -f /etc/lighttpd/lighttpd.conf
EOF

CMD ["/start.sh"]
