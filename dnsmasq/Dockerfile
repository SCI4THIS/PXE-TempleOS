FROM alpine:3.20

RUN apk add --no-cache dnsmasq

ARG PXE_SERVER_IP
ENV NETWORK="${PXE_SERVER_IP%.*}.0"

COPY --chmod=0644 tftp/x86_64-pcbios/ipxe.pxe /tftpboot/x86_64-pcbios/ipxe.pxe
COPY --chmod=0644 tftp/x86_64-pcbios/undionly.kpxe /tftpboot/x86_64-pcbios/undionly.kpxe
COPY --chmod=0644 tftp/x86_64-efi/ipxe.efi /tftpboot/x86_64-efi/ipxe.efi

RUN test -s /tftpboot/x86_64-pcbios/ipxe.pxe \
    && test -s /tftpboot/x86_64-pcbios/undionly.kpxe \
    && test -s /tftpboot/x86_64-efi/ipxe.efi

RUN install -Dm644 /dev/stdin /etc/dnsmasq.conf <<EOF
port=0
interface=eth0

dhcp-range=${NETWORK},proxy
dhcp-match=set:ipxe,175
dhcp-host=00:21:70:f3:ed:f0,set:problemnic


dhcp-boot=tag:!problemnic,tag:!ipxe,x86_64-pcbios/undionly.kpxe,,${PXE_SERVER_IP}
dhcp-boot=tag:problemnic,tag:!ipxe,x86_64-pcbios/ipxe.pxe,,${PXE_SERVER_IP}
dhcp-boot=tag:ipxe,x86_64-efi/autoexec.ipxe,,${PXE_SERVER_IP}

pxe-service=X86-64_EFI,"UEFI PXE Boot",x86_64-efi/ipxe.efi

enable-tftp
tftp-root=/tftpboot

log-dhcp
log-queries
log-facility=-
EOF

RUN install -Dm644 /dev/stdin /tftpboot/x86_64-efi/autoexec.ipxe <<EOF
#!ipxe
dhcp
chain http://${PXE_SERVER_IP}/x86_64-efi/boot.ipxe
EOF

CMD ["dnsmasq", "-k", "-d"]
