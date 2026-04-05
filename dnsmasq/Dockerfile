FROM alpine:3.20

RUN apk add --no-cache dnsmasq

RUN cat << EOF > /etc/dnsmasq.conf
port=0
interface=eth0
bind-interfaces

dhcp-option=66,${PXE_SERVER_IP}
dhcp-range=proxy

pxe-service=X86-64_EFI,"UEFI PXE Boot",x86_64-efi/ipxe.efi
pxe-service=X86PC,"BIOS PXE Boot",x86_64-pcbios/unionly.kpxe

enable-tftp
tftp-root=/tftpboot

log-dhcp
log-queries
log-factility=-
EOF

RUN cat << EOF > /tftpboot/x86_64-efi/autoexec.ipxe
#!ipxe
dhcp
chain http://${PXE_SERVER_IP}/x86_64-efi/boot.ipxe
EOF

CMD ["dnsmasq", "-k"]
