#!/bin/bash

#URL=http://tinycorelinux.net/17.x/x86/release
URL=http://tinycorelinux.net/17.x/x86_64/release
ISO_FILE=CorePure64-17.0.iso

if [ ! -f ${ISO_FILE} ]; then
  curl ${URL}/${ISO_FILE} -o ${ISO_FILE}
fi

VMLINUZ_FS=`bsdtar -tf ${ISO_FILE} | grep -E 'vmlinuz'`
CORE_FS=`bsdtar -tf ${ISO_FILE} | grep -E 'core.*\.gz'`

bsdtar -xf ${ISO_FILE} ${VMLINUZ_FS}
bsdtar -xf ${ISO_FILE} ${CORE_FS}

mv boot www/tinycore
