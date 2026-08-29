# Omarchy - Boot Repair

`Omarchy - Boot Repair` is a PXE rescue environment for an installed Omarchy
system that completed installation but cannot boot through Limine on legacy
BIOS hardware.

## PXE environment

The PXE entry boots Alpine Linux 3.23 and requests these APKs automatically:

- `bash`
- `newt` (`whiptail`)
- `cryptsetup`
- `btrfs-progs`
- `grub-bios`
- `lsblk`
- `blkid`
- `findmnt`
- `mount`
- `umount`
- `sfdisk`
- `kbd` (`openvt` / `chvt`)

The APKoVL launches the TUI automatically on virtual terminal 8.
`start.sh` generates the archive from `nginx/omarchy-repair-overlay-src` in
the per-user runtime directory and nginx serves it through an explicit alias.
It is not stored in the bind-mounted `nginx/www` working-data directory.

## TUI workflow

1. **Diagnostics**
   - Selects the local disk if more than one exists.
   - Locates the FAT `/boot` partition and LUKS root.
   - Prompts once for the LUKS passphrase.
   - Mounts Btrfs `@` and `/boot` read-only.
   - Reads UUIDs directly from disk.
   - Detects `encrypt` versus `sd-encrypt` from `mkinitcpio` configuration.
   - Finds the installed kernel, initramfs and CPU microcode.
   - Checks whether an existing GRUB configuration matches the detected hook.

2. **Dry Run**
   - Makes no disk changes.
   - Generates the exact proposed `grub.cfg`.
   - Shows the exact `grub-install` command.
   - Runs `grub-script-check`.

3. **Commit**
   - Supported automatically only for the tested **legacy BIOS + MBR/dos** case.
   - Requires a yes/no warning followed by typing `REPAIR`.
   - Backs up the first 1 MiB of the disk, partition table, Limine config and any
     previous GRUB config.
   - Installs GRUB with:
     `grub-install --target=i386-pc --boot-directory=<mounted /boot> --recheck <disk>`
   - Writes the generated configuration.
   - Syncs, unmounts, and closes LUKS.

## Encryption arguments

The repair does not hard-code the initramfs encryption scheme.

For an installed `sd-encrypt` hook it generates:

```text
rd.luks.name=<actual-LUKS-UUID>=root root=/dev/mapper/root
```

For an installed `encrypt` hook it generates:

```text
cryptdevice=UUID=<actual-LUKS-UUID>:root root=/dev/mapper/root
```

This is intentionally detected from the installed system rather than copied
manually.

## Safety boundaries

The Commit action currently refuses UEFI systems and refuses GPT disks.
The tested repair case is legacy BIOS + MBR/dos + FAT `/boot` + LUKS2 + Btrfs `@`.

Diagnostics and Dry Run remain useful on other layouts, but do not commit
changes automatically.
