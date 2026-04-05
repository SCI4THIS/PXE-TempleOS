FROM alpine:3.20

RUN apk add --no-cache lighttpd

RUN cat << EOF > /etc/lighttpd/lighttpd.conf
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

RUN mkdir -p /var/www/localhost/htdocs/x86_64-efi
RUN cat << EOF > /var/www/localhost/htdocs/x86_64-efi/boot.ipxe
#!ipxe

set menu-timeout 5000
set baseurl http://${PXE_SERVER_IP}

menu Network Boot Menu

item --key s shell iPXE shell

choose --timeout $(menu-timeout) --default shell || goto shell
goto ${target}

:shell
shell

EOF

CMD ["lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
