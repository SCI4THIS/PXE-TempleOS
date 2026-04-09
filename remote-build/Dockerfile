FROM alpine:3.20

ARG UID=1000
ARG GID=1000
ARG USER=builduser
ARG GROUP=buildgroup

# Install Samba
RUN apk add --no-cache samba samba-common-tools shadow

# Create matching group + user
RUN addgroup -g ${GID} ${GROUP} && \
    adduser -D -u ${UID} -G ${GROUP} ${USER}

# Create shared directory owned by that user
RUN mkdir -p ${SHARED_DIRECTORY} && \
    chown -R ${UID}:${GID} ${SHARED_DIRECTORY} && \
    chmod 0775 ${SHARED_DIRECTORY}

# Create Samba config
RUN cat > /etc/samba/smb.conf << EOF
[global]
  workgroup = WORKGROUP
  server string = PXE Remote Build Samba Server
  security = user
  map to guest = Bad User
  guest account = ${USER}
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
  force user = ${USER}
EOF

EXPOSE 139 445
CMD [ "smbd", "--foreground",  "--no-process-group" ]

