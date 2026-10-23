#!/usr/bin/env bash
# Menú GRUB de dos entradas. Por defecto sólo inspecciona y muestra el resultado.
# Linux + Windows UEFI; no modifica el sistema hasta recibir --apply.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

APPLY=false
KERNEL='' INITRD='' WINDOWS_EFI='' LINUX_NAME='' CONFIG=''
WORK='' BACKUP='' CHANGED=false COMMITTED=false
GRUB_DIR=/etc/grub.d

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Uso: sudo bash menu-dual.sh [opciones]
  --apply                Aplicar; sin esta opción sólo muestra una vista previa.
  --kernel RUTA          Ruta estable del kernel (autodetectada por defecto).
  --initrd RUTA          Ruta estable del initramfs (autodetectada por defecto).
  --windows-efi RUTA     bootmgfw.efi en una partición EFI ya montada.
  --linux-name NOMBRE    Título Linux (por defecto, nombre de la distribución).
  --config RUTA         grub.cfg existente; se detecta en /boot/grub{,2}.
  --help                 Mostrar esta ayuda.

Orden: Windows 11 (predeterminado), Linux. Conserva el timeout configurado.
Admite /boot separado, ext2/3/4, XFS, Btrfs y LVM sin cifrar.
Requiere GRUB con /etc/grub.d y arranque UEFI. Rechaza /boot cifrado,
raíces cifradas, RAID y ZFS; no instala GRUB ni monta particiones.
Las rutas de kernel/initrd deben ser estables y mantenerse al actualizar.
El nombre «Windows 11» es una etiqueta solicitada, no detección de su versión.
EOF
}

parse_arguments() {
    while (($#)); do
        case $1 in
            --apply) APPLY=true; shift ;;
            --help) usage; exit 0 ;;
            --kernel|--initrd|--windows-efi|--linux-name|--config)
                (($# >= 2)) || die "Falta el valor de $1"
                case $1 in
                    --kernel) KERNEL=$2 ;; --initrd) INITRD=$2 ;;
                    --windows-efi) WINDOWS_EFI=$2 ;; --linux-name) LINUX_NAME=$2 ;;
                    --config) CONFIG=$2 ;;
                esac
                shift 2 ;;
            *) die "Opción desconocida: $1" ;;
        esac
    done
}

find_tool() {
    local candidate
    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null; then command -v "$candidate"; return; fi
    done
    die "No se encontró ninguna de estas herramientas: $*"
}

check_environment() {
    ((EUID == 0)) || die 'Ejecutá con sudo; incluso la inspección necesita leer la partición EFI.'
    [[ -d /sys/firmware/efi ]] || die 'Esta versión admite sólo arranque UEFI.'
    local tool
    for tool in findmnt lsblk find realpath mktemp cp chmod mv awk grep flock; do
        command -v "$tool" >/dev/null || die "Falta $tool"
    done
    PROBE=$(find_tool grub-probe grub2-probe)
    RELPATH=$(find_tool grub-mkrelpath grub2-mkrelpath)
    MKCONFIG=$(find_tool grub-mkconfig grub2-mkconfig)
    CHECK=$(find_tool grub-script-check grub2-script-check)
    [[ -x $GRUB_DIR/00_header && -f /etc/default/grub ]] || die 'No se reconoce la configuración de GRUB.'
    if [[ -z $CONFIG ]]; then
        local -a configs=()
        for tool in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
            [[ ! -f $tool ]] || configs+=("$tool")
        done
        ((${#configs[@]} == 1)) || die 'No hay un grub.cfg único; indicá --config.'
        CONFIG=${configs[0]}
    fi
    CONFIG=$(realpath -e -- "$CONFIG")
    [[ -f $CONFIG && $CONFIG == /boot/* && $CONFIG != /boot/efi/* ]] || die 'Se requiere el grub.cfg principal en /boot, no un archivo de redirección EFI.'
    grep -q 'BEGIN /etc/grub.d/00_header' "$CONFIG" || die 'El archivo indicado no parece el grub.cfg principal.'
    exec 9>/run/lock/grub-two-entries.lock
    flock -n 9 || die 'Hay otra instancia de este script en ejecución.'
}

read_settings() {
    local settings
    # Archivos del sistema, con sintaxis shell, igual que grub-mkconfig.
    source /etc/default/grub
    for settings in /etc/default/grub.d/*.cfg; do
        [[ ! -f $settings ]] || source "$settings"
    done
    TIMEOUT=${GRUB_TIMEOUT:-20}
    [[ $TIMEOUT =~ ^[0-9]+$ ]] || die 'GRUB_TIMEOUT debe ser un número no negativo.'
    if [[ -z $LINUX_NAME ]]; then
        LINUX_NAME=${GRUB_DISTRIBUTOR:-}
        if [[ -z $LINUX_NAME ]]; then
            source /etc/os-release
            LINUX_NAME=${NAME:-Linux}
        fi
    fi
    CMDLINE="${GRUB_CMDLINE_LINUX:-} ${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    # No se evalúa la línea de parámetros: se aceptan tokens simples y se citan.
    [[ $CMDLINE != *\"* && $CMDLINE != *\'* && $CMDLINE != *$'\n'* ]] || die 'La línea de parámetros contiene comillas/saltos de línea; necesita adaptación manual.'
}

detect_kernel() {
    if [[ -z $KERNEL && -z $INITRD ]]; then
        if [[ -f /boot/vmlinuz && -f /boot/initrd.img ]]; then
            KERNEL=/boot/vmlinuz; INITRD=/boot/initrd.img
        elif [[ -f /vmlinuz && -f /initrd.img ]]; then
            KERNEL=/vmlinuz; INITRD=/initrd.img
        elif [[ -f /boot/vmlinuz-linux && -f /boot/initramfs-linux.img ]]; then
            KERNEL=/boot/vmlinuz-linux; INITRD=/boot/initramfs-linux.img
        else
            die 'No encuentro un par de rutas estables; indicá --kernel y --initrd.'
        fi
    fi
    [[ $KERNEL == /* && $INITRD == /* && -f $KERNEL && -f $INITRD ]] || die 'Kernel/initrd inválidos: indicá ambas rutas absolutas.'
    ROOT_UUID=$(findmnt -nro UUID /)
    ROOT_FS=$(findmnt -nro FSTYPE /)
    ROOT_DEVICE=$(findmnt -nro SOURCE /); ROOT_DEVICE=${ROOT_DEVICE%%\[*}
    [[ -n $ROOT_UUID && -b $ROOT_DEVICE ]] || die 'No se pudo identificar la raíz mediante UUID.'
    case $ROOT_FS in ext2|ext3|ext4|xfs|btrfs) ;; *) die "Raíz no soportada: $ROOT_FS" ;; esac
    if lsblk -snro TYPE "$ROOT_DEVICE" | grep -Eq 'crypt|raid|md'; then
        die 'Raíz cifrada o RAID: se necesita configuración específica.'
    fi
    BOOT_UUID=$("$PROBE" --target=fs_uuid "$KERNEL")
    [[ $BOOT_UUID == "$("$PROBE" --target=fs_uuid "$INITRD")" ]] || die 'Kernel e initrd deben estar en el mismo sistema de archivos.'
    [[ $BOOT_UUID == "$("$PROBE" --target=fs_uuid "$(dirname -- "$KERNEL")")" &&
       $BOOT_UUID == "$("$PROBE" --target=fs_uuid "$(dirname -- "$INITRD")")" ]] || die 'Los enlaces cruzan sistemas de archivos; elegí rutas estables dentro de la partición /boot.'
    BOOT_FS=$("$PROBE" --target=fs "$KERNEL")
    BOOT_ABSTRACTION=$("$PROBE" --target=abstraction "$KERNEL")
    [[ -z $BOOT_ABSTRACTION || $BOOT_ABSTRACTION == lvm ]] || die "Abstracción de /boot no soportada: $BOOT_ABSTRACTION"
    # Se convierte el directorio a una ruta GRUB, sin resolver el enlace final.
    KERNEL_GRUB=$("$RELPATH" "$(dirname -- "$KERNEL")")/${KERNEL##*/}
    INITRD_GRUB=$("$RELPATH" "$(dirname -- "$INITRD")")/${INITRD##*/}
    KERNEL_GRUB=/${KERNEL_GRUB#/}; KERNEL_GRUB=${KERNEL_GRUB//\/\//\/}
    INITRD_GRUB=/${INITRD_GRUB#/}; INITRD_GRUB=${INITRD_GRUB//\/\//\/}
    ROOT_FLAGS=''
    if [[ $ROOT_FS == btrfs ]]; then
        local subvolume
        subvolume=$(findmnt -nro FSROOT /)
        [[ $subvolume == / ]] || ROOT_FLAGS="rootflags=subvol=$subvolume"
        [[ $CMDLINE != *rootflags=* ]] || die 'Btrfs con rootflags personalizados requiere adaptación manual.'
    fi
}

detect_windows() {
    if [[ -z $WINDOWS_EFI ]]; then
        local mountpoint candidate
        local -a candidates=()
        while IFS= read -r mountpoint; do
            # findmnt escapa espacios; en ese caso usar la opción explícita.
            [[ $mountpoint != *\\* ]] || continue
            while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(
                find "$mountpoint" -maxdepth 5 -type f -ipath '*/efi/microsoft/boot/bootmgfw.efi' -print0
            )
        done < <(findmnt -rn -t vfat -o TARGET)
        ((${#candidates[@]} == 1)) || die 'No hay un cargador Windows único en las particiones montadas; indicá --windows-efi.'
        WINDOWS_EFI=${candidates[0]}
    fi
    [[ $WINDOWS_EFI == /* && -f $WINDOWS_EFI ]] || die 'Cargador de Windows inexistente.'
    WINDOWS_UUID=$("$PROBE" --target=fs_uuid "$WINDOWS_EFI")
    WINDOWS_FS=$("$PROBE" --target=fs "$WINDOWS_EFI")
    [[ $WINDOWS_FS == fat && -n $WINDOWS_UUID ]] || die 'El cargador Windows debe estar en una partición FAT.'
    WINDOWS_GRUB=$("$RELPATH" "$WINDOWS_EFI")
}

grub_quote() {
    # Rechazar caracteres con reglas de escape ambiguas; nunca interpolar código.
    [[ $1 != *\'* && $1 != *$'\n'* && $1 != *$'\r'* ]] || die 'Valor no representable como literal GRUB.'
    printf "'%s'" "$1"
}

write_menu() {
    local argument
    local -a arguments=()
    read -r -a arguments <<< "$CMDLINE"
    for argument in "$LINUX_NAME" "$WINDOWS_UUID" "$WINDOWS_GRUB" "$BOOT_FS" "$BOOT_UUID" "$KERNEL_GRUB" "$ROOT_UUID" "$ROOT_FLAGS" "$INITRD_GRUB" "${arguments[@]}"; do
        grub_quote "$argument" >/dev/null
    done
    {
        printf 'set default=windows-11\nset timeout_style=menu\nset timeout=%s\n' "$TIMEOUT"
        printf "menuentry 'Windows 11' --class windows --class os --id windows-11 {\n"
        printf '    insmod part_gpt\n    insmod part_msdos\n    insmod fat\n'
        printf '    search --no-floppy --fs-uuid --set=root %s\n' "$(grub_quote "$WINDOWS_UUID")"
        printf '    chainloader %s\n}\n\n' "$(grub_quote "$WINDOWS_GRUB")"
        printf 'menuentry %s --class gnu-linux --class os --id linux-stable {\n' "$(grub_quote "$LINUX_NAME")"
        printf '    insmod part_gpt\n    insmod part_msdos\n'
        [[ -z $BOOT_ABSTRACTION ]] || printf '    insmod lvm\n'
        printf '    insmod %s\n    insmod gzio\n' "$(grub_quote "$BOOT_FS")"
        printf '    search --no-floppy --fs-uuid --set=root %s\n' "$(grub_quote "$BOOT_UUID")"
        printf '    linux %s %s ro' "$(grub_quote "$KERNEL_GRUB")" "$(grub_quote "root=UUID=$ROOT_UUID")"
        [[ -z $ROOT_FLAGS ]] || printf ' %s' "$(grub_quote "$ROOT_FLAGS")"
        for argument in "${arguments[@]}"; do
            [[ $argument != root=* && $argument != initrd=* && $argument != BOOT_IMAGE=* ]] || continue
            printf ' %s' "$(grub_quote "$argument")"
        done
        printf '\n    initrd %s\n}\n' "$(grub_quote "$INITRD_GRUB")"
    } > "$WORK/menu.cfg"
    "$CHECK" "$WORK/menu.cfg"
}

create_backup() {
    mkdir -p /var/backups
    BACKUP=$(mktemp -d /var/backups/grub-two-entries-bash.XXXXXXXX)
    cp -a -- "$GRUB_DIR" "$BACKUP/grub.d"
    cp -a -- "$CONFIG" "$BACKUP/grub.cfg"
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'backup=%q\nconfig=%q\n' "$BACKUP" "$CONFIG"
        printf 'cp -a -- "$backup/grub.d/." /etc/grub.d/\n'
        [[ -e $GRUB_DIR/40_custom ]] || printf 'rm -f -- /etc/grub.d/40_custom\n'
        printf 'cp -a -- "$backup/grub.cfg" "$config"\n'
    } > "$BACKUP/restaurar.sh"
    info "Respaldo: $BACKUP"
}

apply_menu() {
    create_backup
    CHANGED=true
    local script
    # Se conservan encabezado y tema. Los otros generadores quedan deshabilitados.
    for script in "$GRUB_DIR"/*; do
        [[ -f $script ]] || continue
        case ${script##*/} in 00_header|05_debian_theme|40_custom) continue ;; esac
        chmod a-x -- "$script"
    done
    [[ ! -L $GRUB_DIR/40_custom ]] || die '40_custom es un enlace simbólico; revisar manualmente.'
    { printf '#!/bin/sh\nexec tail -n +3 "$0"\n'; cat "$WORK/menu.cfg"; } > "$GRUB_DIR/40_custom"
    chmod 755 "$GRUB_DIR/40_custom"
    # Archivo temporal en la misma partición para reemplazo atómico.
    CANDIDATE=$(mktemp "${CONFIG}.candidate.XXXXXXXX")
    "$MKCONFIG" -o "$CANDIDATE"
    "$CHECK" "$CANDIDATE"
    local count
    count=$(grep -Ec '^[[:space:]]*menuentry[[:space:]]' "$CANDIDATE")
    [[ $count == 2 ]] || die "Se generaron $count entradas, se esperaban dos."
    ! grep -Eq '^[[:space:]]*submenu[[:space:]]' "$CANDIDATE" || die 'Apareció un submenú inesperado.'
    grep -Fq -- '--id windows-11' "$CANDIDATE" || die 'Falta Windows.'
    grep -Fq -- '--id linux-stable' "$CANDIDATE" || die 'Falta Linux.'
    chmod 600 "$CANDIDATE"
    mv -f -- "$CANDIDATE" "$CONFIG"
    COMMITTED=true
    info "Menú aplicado y validado. Para restaurar: sudo bash $BACKUP/restaurar.sh"
}

cleanup() {
    local status=$?
    trap - EXIT
    if $CHANGED && ! $COMMITTED; then
        info 'Se produjo un error; restaurando la configuración anterior…'
        if ! bash "$BACKUP/restaurar.sh"; then
            info "Falló la restauración automática. Respaldo disponible en $BACKUP"
            status=1
        fi
    fi
    [[ -z ${CANDIDATE:-} ]] || rm -f -- "$CANDIDATE"
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$status"
}

main() {
    parse_arguments "$@"
    check_environment
    WORK=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    read_settings
    detect_kernel
    detect_windows
    write_menu
    info "Kernel: $KERNEL → $(readlink -f -- "$KERNEL")"
    info "Initrd: $INITRD → $(readlink -f -- "$INITRD")"
    info "Windows: $WINDOWS_EFI"
    cat "$WORK/menu.cfg"
    if $APPLY; then apply_menu; else info 'Vista previa: no se cambió GRUB. Usá --apply para aplicar.'; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
