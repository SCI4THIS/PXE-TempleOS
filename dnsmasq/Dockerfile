FROM alpine:3.20

RUN apk add --no-cache dnsmasq

ARG PXE_SERVER_IP
ENV STAGING_DIR=/tmp/staging
ENV NETWORK="${PXE_SERVER_IP%.*}.0"

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/etc/dnsmasq.conf <<EOF
port=0
interface=eth0
bind-interfaces

dhcp-option=66,${PXE_SERVER_IP}
dhcp-range=${NETWORK},proxy

pxe-service=X86-64_EFI,"UEFI PXE Boot",x86_64-efi/ipxe.efi
pxe-service=X86PC,"BIOS PXE Boot",x86_64-pcbios/unionly.kpxe

enable-tftp
tftp-root=/tftpboot

log-dhcp
log-queries
log-facility=-
EOF

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/tftpboot/x86_64-efi/autoexec.ipxe <<EOF
#!ipxe
dhcp
chain http://${PXE_SERVER_IP}/x86_64-efi/boot.ipxe
EOF

RUN install -Dm700 /dev/stdin /start.sh <<EOF
#!/bin/sh
echo "Copying files from staging to root"
cp -a ${STAGING_DIR}/* /
echo "Starting dnsmasq server"
exec dnsmasq -k -d
EOF

CMD ["/start.sh"]
