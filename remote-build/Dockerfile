FROM alpine:3.20

# Install Samba
RUN apk add --no-cache samba samba-common-tools

# Create shared directory
RUN mkdir -p /shared && chmod 777 /shared

# Create Samba config
RUN cat > /etc/samba/smb.conf << EOF
[global]
  workgroup = WORKGROUP
  server string = PXE Remote Build Samba Server
  security = user
  map to guest = Bad User
  guest account = nobody
  log file = /dev/stdout
  max log size = 50
  load printers = no
  disable spoolss = yes

[build]
  path = /shared
  browseable = yes
  writeable = yes
  guest ok = yes
  read only = no
  force user = nobody
EOF

EXPOSE 139 445
CMD [ "sh", "-c", "smbd --foreground --no-process-group" ]

