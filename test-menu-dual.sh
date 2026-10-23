#!/usr/bin/env bash
# Pruebas sin privilegios: no leen ni escriben la configuración activa.
set -Eeuo pipefail
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$BASE/menu-dual.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
CHECK=$(command -v grub-script-check || command -v grub2-script-check)
TIMEOUT=20 LINUX_NAME=Kubuntu
WINDOWS_UUID=ABCD-1234 WINDOWS_GRUB=/EFI/Microsoft/Boot/bootmgfw.efi
ROOT_UUID=11111111-2222-3333-4444-555555555555 BOOT_UUID=$ROOT_UUID
BOOT_FS=ext2 BOOT_ABSTRACTION='' ROOT_FLAGS=''
KERNEL_GRUB=/boot/vmlinuz INITRD_GRUB=/boot/initrd.img
CMDLINE='quiet splash root=old initrd=old BOOT_IMAGE=old'
write_menu
grep -Fq 'set default=windows-11' "$WORK/menu.cfg"
grep -Fq "linux '/boot/vmlinuz' 'root=UUID=$ROOT_UUID' ro 'quiet' 'splash'" "$WORK/menu.cfg"
! grep -q '=old' "$WORK/menu.cfg"
[[ $(grep '^menuentry' "$WORK/menu.cfg" | head -n 1) == *"'Windows 11'"* ]]
[[ $(grep -c '^menuentry' "$WORK/menu.cfg") == 2 ]]
printf 'OK: orden, predeterminado, rutas estables y parámetros.\n'

BOOT_UUID=66666666-7777-8888-9999-000000000000
KERNEL_GRUB=/vmlinuz INITRD_GRUB=/initrd.img BOOT_ABSTRACTION=lvm
write_menu
grep -Fq -- "--set=root '$BOOT_UUID'" "$WORK/menu.cfg"
grep -Fq "'root=UUID=$ROOT_UUID'" "$WORK/menu.cfg"
grep -Fq 'insmod lvm' "$WORK/menu.cfg"
printf 'OK: /boot separado y módulo LVM.\n'

BOOT_FS=btrfs BOOT_ABSTRACTION='' ROOT_FLAGS=rootflags=subvol=/@
KERNEL_GRUB=/@/boot/vmlinuz INITRD_GRUB=/@/boot/initrd.img
LINUX_NAME='Mi Linux'
write_menu
grep -Fq "'rootflags=subvol=/@'" "$WORK/menu.cfg"
grep -Fq "menuentry 'Mi Linux'" "$WORK/menu.cfg"
printf 'OK: rutas y parámetros Btrfs; título con espacios.\n'

if (LINUX_NAME="nombre' inválido"; write_menu) 2>/dev/null; then
    printf 'ERROR: se aceptó un nombre no representable.\n' >&2; exit 1
fi
printf 'OK: rechazo de valores no representables.\n'
