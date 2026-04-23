Project Overview

This project creates a PXE netboot docker composition that is designed to run
on a raspberry pi and creates a netboot entry to load into TempleOS.  TempleOS hardware
requirements are so strict that it was easier to run via QEMU and Alpine Linux.
I was able to use virtualization, so it runs decently on oldish hardware and I was configure
the sound card so it can produce God songs.  The composition consists of dnsmasq, nginx, and 
samba containers which are driven by a .env file to get the IP address and UID/GID correctly.

- Dnsmasq

Dnsmasq container creates a TFTP system and uses the binaries at https://boot.ipxe.org to switch 
over to using a HTTP server (nginx) as quickly as possible.

- Samba

Samba container creates a shared network driver which some of the netboot options can automount.
This is used for the compilation of qemu with the configuration options that we need in order
to get the graphics and the sound card to work on the laptop we were using.

- Nginx

Nginx container creates a http server which accomplishes 3 things.  It provides a cached
proxy-pass system to access dl-cdn.alpinelinux.org and templeos.org so that the files will
stay locally for 30 days to speed things up and reduce the load on the public servers.  It
provides a boot.ipxe menu that configures the alpine linux netboot configurations.  Finally,
it hosts the custom Alpine Overlays which can run startup tasks via /etc/local.d/ such as
mount configurations.

The Dockerfile for this has a companion yaml2tar.py python script which consumes yaml
files contained in heredoc within the Dockerfile and output tarballs.  These are
then used as apkovl which are served over nginx during the netboot to create the custom
boot entries.

There are 4 boot options: Alpine Linux, Development, TempleOS, and iPXE Shell.

- Alpine Linux

Simple Alpine Linux with no customization.

- Development

This creates an Alpine Linux environment with the samba server share mounted at
/mnt.  There is also a tmpfs mounted at /run/overlay and an overlayFS mounted
with the following configuration:

/mnt                - lower
/run/overlay/work   - work
/run/overlay/merged - merged
/run/overlay/upper  - upper

This is setup to compile Qemu with the customization options needed to make it 
work.  Running through the scripts in /etc/qemu-build should result in a 
successful qemu compilation stored on the samba server along with an alpine
package (apk) that has the binary embedded and is used in the TempleOS setup.

- TempleOS

This Alpine Linux customization retrieves the custom Qemu binaries and also
the TempleOS.ISO from the proxy-pass nginx server.  It then launches it
before the login prompt to create a full screen TempleOS experience.

- iPXE Shell

Drops into an iPXE shell environmet for debugging.

Quickstart

# Raspberry Pi
sudo apt-get install docker-compose
git clone https://github.com/SCI4THIS/PXE-TempleOS
cd PXE-TempleOS
./gen-env.sh
docker compose up --build

# Laptop
ESC - custom boot options
F12 - netboot
Select Alpine Linux - Development <ENTER>
username: root
# no password
/etc/qemu-build/01-clone.sh
/etc/qemu-build/02-checkout-stable-10.2.sh
/etc/qemu-build/03-configure.sh
/etc/qemu-build/04-fixup-symlinks.sh
/etc/qemu-build/05-ninja-compile.sh
/etc/qemu-build/06-ninja-install.sh
/etc/qemu-build/07-create-abuild-user.sh
/etc/qemu-build/08-build-apk.sh

# Raspberry Pi
cd PXE-TempleOS
sudo ./cp-samba-apk-to-nginx.sh

# Laptop
ESC - custom boot options
F12 - netboot
Select TempleOS (Alpine Linux + QEMU) <ENTER>

