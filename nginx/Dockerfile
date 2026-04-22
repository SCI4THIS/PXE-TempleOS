FROM alpine:3.20

RUN apk add --no-cache nginx python3 py3-yaml py3-jsonschema

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
    location /templeos.org/Downloads/TempleOS.ISO {
      proxy_pass https://templeos.org/Downloads/TempleOS.ISO;
      proxy_cache apkcache;
      proxy_cache_valid 200 302 ${PROXY_PASS_TTL};
      proxy_cache_valid 404 1m;
      add_header X-Cache-Status \$upstream_cache_status;
    }
    location /dl-cdn.alpinelinux.org/ {
      rewrite ^/dl-cdn.alpinelinux.org/(.*)\$ /\$1 break;
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

RUN install -Dm644 /dev/stdin /tmp/dev-apkovl.yaml <<EOF
files:
  - name: etc/motd
    type: "file"
    mode: "0644"
    content: |
      Welcome to Alpine!  This is a netboot configuration specifically designed for
      compiling qemu.  Compiling qemu needs symlinks which are not supported by samba.
      OverlayFS is used to overcome this.  The system is setup as follows:
        /mnt/               -- samba     (lower)
        /run/overlay/work   -- OverlayFS (work)
        /run/overlay/merged -- OverlayFS (merged)
        /run/overlay/upper  -- OverlayFS (upper)
      There are some scripting chunks to help guide through the process in
        /etc/qemu-build/    -- build scripts

  - name: etc/local.d/mount.start
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Add samba mount
      mount -t cifs //${PXE_SERVER_IP}/shared /mnt -o guest
      # Create local overlayFS to handle symlinks
      mkdir /run/overlay
      mount -t tmpfs tmpfs /run/overlay
      mkdir /run/overlay/upper
      mkdir /run/overlay/work
      mkdir /run/overlay/merged
      mount -t overlay overlay -o lowerdir=/mnt,upperdir=/run/overlay/upper,workdir=/run/overlay/work /run/overlay/merged

  - name: etc/runlevels/default/local
    type: "symlink"
    mode: "0777"
    target: "/etc/init.d/local"

  - name: etc/qemu-build/01-clone.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Clone qemu project in the lowerdir
      cd /mnt
      git clone https://gitlab.com/qemu-project/qemu.git
      cd -

  - name: etc/qemu-build/02-checkout-stable-10.2.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Checkout stable-10.2 release
      cd /mnt/qemu
      git checkout stable-10.2
      cd -

  - name: etc/qemu-build/03-configure.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # In merged dir, configure build to only make what we need
      cd /run/overlay/merged/qemu
      ./configure \
      --prefix=/usr \
      --target-list=x86_64-softmmu \
      --enable-sdl \
      --enable-libudev \
      --enable-opengl \
      --audio-drv-list=alsa \
      --disable-jack \
      --disable-oss \
      --disable-docs
      cd -

  - name: etc/qemu-build/04-fixup-symlinks.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # qemu configure outputs symlinks as regular files.  This fixes them.
      cd /run/overlay/merged/qemu
      find . -type f | while read f; do
        target=\$(head -n 1 "\$f")
        if echo "\$target" | grep -qE '^(\.\./|/)' && [ \$(wc -l < "\$f") -eq 0 ]; then
          echo "Converting \$f -> \$target"
          rm "\$f"
          ln -s "\$target" "\$f"
        fi
      done
      cd -

  - name: etc/qemu-build/05-ninja-compile.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Run through the compilation
      cd /run/overlay/merged/qemu/build
      ninja
      cd -

  - name: etc/qemu-build/06-ninja-install.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Install back to lower dir
      cd /run/overlay/merged/qemu/build
      mkdir -p /mnt/qemu-install
      rm -rf /mnt/qemu-install/*
      DESTDIR=/mnt/qemu-install ninja install
      cd -

  - name: etc/qemu-build/07-create-abuild-user.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Create abuild group and user check if abuild.key is on samba share
      # if it is copy it over, otherwise generate it and store it on the samba share
      adduser -D -G abuild abuild
      if [ -f /mnt/abuild.rsa ] && [ -f /mnt/abuild.rsa.pub ] && [ -f /mnt/abuild.conf ]; then
        mkdir /home/abuild/.abuild/
        cp /mnt/abuild.rsa /home/abuild/.abuild/abuild.rsa
        cp /mnt/abuild.rsa.pub /home/abuild/.abuild/abuild.rsa.pub
        cp /mnt/abuild.conf /home/abuild/.abuild/abuild.conf
        chown -R abuild:abuild /home/abuild/.abuild/
      else
        su abuild -c "echo /home/abuild/.abuild/abuild.rsa | abuild-keygen -a"
        cp /home/abuild/.abuild/abuild.rsa /mnt/abuild.rsa
        cp /home/abuild/.abuild/abuild.rsa.pub /mnt/abuild.rsa.pub
        cp /home/abuild/.abuild/abuild.conf /mnt/abuild.conf
      fi
      cp /home/abuild/.abuild/abuild.rsa.pub /etc/apk/keys
      mkdir -p /home/abuild/qemu-templeos
      cat > /home/abuild/qemu-templeos/APKBUILD << EOF
      pkgname=qemu-templeos
      pkgver=10.2.0
      pkgrel=0
      pkgdesc="Custom QEMU build (SDL, ALSA, no OSS/JACK)"
      url="https://sci4this.com"
      arch="x86_64"
      license="GPL-2.0-or-later"
      depends="glib pixman sdl2 alsa-lib mesa-dev alsa-utils"
      options="!strip !check"
      source=""
      builddir=""
      package() {
        mkdir -p "\\\$pkgdir"
        cp -a /mnt/qemu-install/* "\\\$pkgdir"/
      }
      EOF
      chown -R abuild:abuild /home/abuild/qemu-templeos
      umount /run/overlay/merged
      umount /run/overlay
      umount /mnt
      mount -t cifs //${PXE_SERVER_IP}/shared /mnt -o guest,uid=\$(id -u abuild),gid=\$(id -g abuild)

  - name: etc/qemu-build/08-build-apk.sh
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # This will build the apk
      cd /home/abuild/qemu-templeos
      su abuild -c "abuild checksum"
      su abuild -c "mkdir -p /mnt/apk/packages"
      su abuild -c "ln -s /mnt/apk/packages /home/abuild/packages"
      su abuild -c "abuild -r"
      cd -

  - name: etc/.default_boot_services
    type: "file"
    mode: "0644"
    content: |

EOF

RUN install -Dm644 /dev/stdin /tmp/templeos-apkovl.yaml <<EOF
files:
  - name: etc/motd
    type: "file"
    mode: "0644"
    content: |
      Welcome to Alpine!  This is a netboot variant that is setup to run a custom
      qemu compilation that has been tailored to handle the audio and reduced graphics
      of TempleOS.  It should auto boot into TempleOS.

  - name: etc/local.d/mount.start
    type: "file"
    mode: "0755"
    content: |
      #!/bin/sh
      # Add samba mount
      mkdir /iso
      wget -O /iso/TempleOS.ISO http://${PXE_SERVER_IP}/templeos.org/Downloads/TempleOS.ISO
      wget -O /etc/apk/keys/abuild.rsa.pub http://${PXE_SERVER_IP}/apk/abuild.rsa.pub
      apk update
      apk add sdl2 qemu-templeos qemu-ui-sdl

  - name: etc/apk/repositories
    type: "file"
    mode: "0644"
    content: |
      http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main
      http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community
      http://${PXE_SERVER_IP}/apk

  - name: etc/start-qemu-templeos.sh
    type: "file"
    mode: "0755"
    content: |
      modprobe kvm_amd
      amixer -c 1 set Master 80\% unmute
      qemu-system-x86_64 \
      -m 512 \
      --enable-kvm \
      -cpu max \
      -M pc \
      -cdrom /iso/TempleOS.ISO \
      -boot d \
      -nic none \
      -display sdl \
      -audiodev "{ 'driver': 'alsa', 'id': 'snd0', 'out': { 'dev': 'hw:1,0' } }" \
      -machine pcspk-audiodev=snd0 \
      -serial none \
      -parallel none \
      -monitor none

  - name: etc/runlevels/default/local
    type: "symlink"
    mode: "0777"
    target: "/etc/init.d/local"

  - name: etc/.default_boot_services
    type: "file"
    mode: "0644"
    content: |
EOF

COPY yaml2tar.py /tmp/yaml2tar.py
RUN python3 /tmp/yaml2tar.py /tmp/dev-apkovl.yaml | gzip > /tmp/dev-apkovl.tar.gz
RUN python3 /tmp/yaml2tar.py /tmp/templeos-apkovl.yaml | gzip > /tmp/templeos-apkovl.tar.gz
RUN install -Dm644 /tmp/dev-apkovl.tar.gz ${STAGING_DIR}/var/www/htdocs/dev-apkovl.tar.gz
RUN install -Dm644 /tmp/templeos-apkovl.tar.gz ${STAGING_DIR}/var/www/htdocs/templeos-apkovl.tar.gz

RUN install -Dm644 /dev/stdin ${STAGING_DIR}/var/www/htdocs/x86_64-efi/boot.ipxe <<EOF
#!ipxe
menu Network Boot Menu
item --key a alpine Alpine Linux
item --key t templeos Temple OS (Alpine Linux + QEMU)
item --key d alpine-dev Alpine Linux - Development
item --key s shell iPXE shell
choose --default alpine target || goto alpine
goto \${target}

:templeos
echo Booting TempleOS...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \
  modules=loop,squashfs quiet nomodeset \
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \
  apkovl=http://${PXE_SERVER_IP}/templeos-apkovl.tar.gz \
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \
  ntp=pool.ntp.org \
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot


:alpine
echo Booting Alpine...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \
  modules=loop,squashfs quiet nomodeset \
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \
  ntp=pool.ntp.org \
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot

:alpine-dev
echo Booting Alpine Development...
kernel http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/vmlinuz-lts \
  modules=loop,squashfs quiet nomodeset \
  alpine_repo=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/main,http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/alpine/v3.23/community \
  apkovl=http://${PXE_SERVER_IP}/dev-apkovl.tar.gz \
  modloop=http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/modloop-lts \
  pkgs=build-base,git,python3,meson,ninja,pkgconf,glib-dev,pixman-dev,zlib-dev,libaio-dev,util-linux-dev,alsa-lib-dev,sdl2-dev,eudev-dev,libdrm-dev,linux-headers,cifs-utils,alpine-sdk,sudo,mesa-dev,mesa-egl,mesa-gbm,libepoxy-dev \
  ntp=pool.ntp.org \
  ip=dhcp
initrd http://${PXE_SERVER_IP}/dl-cdn.alpinelinux.org/v3.23/releases/x86_64/netboot-3.23.3/initramfs-lts
boot

:shell
shell
EOF


RUN install -Dm700 /dev/stdin /start.sh <<EOF
#!/bin/sh
echo "Copying files from staging to root"
cp -a ${STAGING_DIR}/* /
echo "Starting NGINX server"
exec nginx -g "daemon off;"
EOF

CMD ["/start.sh"]

