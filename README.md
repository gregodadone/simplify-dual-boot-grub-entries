# Menú dual de GRUB en Bash

`menu-dual.sh` prepara dos entradas: **Windows 11**, primero y predeterminado,
y la distribución Linux actual. No contiene UUID, nombres de discos ni versiones
de kernel propios de una máquina. No cambia el menú activo sin `--apply`.

## Uso

```bash
# Inspección y vista previa, sin modificar GRUB:
sudo bash menu-dual.sh

# Guardar respaldo, aplicar y validar:
sudo bash menu-dual.sh --apply

# Seleccionar rutas cuando la detección sea ambigua:
sudo bash menu-dual.sh --kernel /boot/vmlinuz --initrd /boot/initrd.img \
  --windows-efi /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi \
  --linux-name Kubuntu
```

La vista previa requiere root para inspeccionar el cargador de Windows y ejecutar
`grub-probe`. Crea únicamente archivos temporales y un bloqueo de ejecución.
El título Windows 11 es una etiqueta; el script no identifica la edición instalada.

## Funciones principales

- `check_environment`: comprueba herramientas, UEFI y el archivo principal de GRUB.
- `read_settings`: lee nombre de distribución, timeout y parámetros del kernel.
- `detect_kernel`: obtiene UUID de raíz y arranque, sistema de archivos y rutas GRUB.
- `detect_windows`: busca el cargador en particiones FAT ya montadas.
- `write_menu`: genera las dos entradas y comprueba su sintaxis.
- `create_backup`: guarda la configuración anterior y un script para restaurarla.
- `apply_menu`: deshabilita otros generadores, instala `40_custom`, regenera y valida.
- `cleanup`: restaura el respaldo si falla la aplicación y elimina temporales.

`findmnt`, `lsblk`, `grub-probe` y `grub-mkrelpath` proporcionan los datos del sistema.
También se admiten herramientas con prefijo `grub2-`. Los enlaces finales del kernel
no se resuelven al escribir el menú: se mantiene la ruta estable. Se distinguen el
UUID de la raíz y el de /boot, que pueden ser diferentes.

## Alcance real

No existe una configuración única válida para cualquier sistema operativo o diseño
de arranque. Esta versión está destinada a Linux + Windows con GRUB, UEFI,
`/etc/grub.d` y `/etc/default/grub`. Contempla ext2/3/4, XFS, Btrfs, /boot separado y
LVM sin cifrar. Rechaza cifrado, RAID, ZFS y arranque BIOS. Los cargadores EFI deben
estar montados; si hay varios, se exige seleccionar uno mediante la opción indicada.
Los parámetros del kernel con comillas requieren adaptación manual. Los enlaces que
atraviesan sistemas de archivos también requieren seleccionar otra ruta estable.

Autodetecta `/boot/vmlinuz` + `/boot/initrd.img`, `/vmlinuz` + `/initrd.img` o el par
estable de Arch `/boot/vmlinuz-linux` + `/boot/initramfs-linux.img`. Para otros diseños
se deben indicar ambas rutas. La distribución debe mantenerlas al actualizar el
kernel; el script no crea ni actualiza enlaces. Las opciones explícitas también
permiten rutas versionadas, pero en ese caso dejan de seguir nuevas versiones.

Al aplicar, conserva `00_header` y `05_debian_theme`, sustituye `40_custom` y quita
el permiso de ejecución a los demás generadores. No modifica `/etc/default/grub`:
el menú personalizado fija el predeterminado y el timeout después del encabezado.
El tema se conserva, aunque sus iconos dependen de las clases que admita.
Una actualización de paquetes podría añadir o reactivar generadores; en ese caso
se debe revisar el menú y volver a aplicar. Al deshabilitar todos los demás
generadores tampoco se muestran entradas temporales de actualización de firmware.

El respaldo se guarda en `/var/backups/grub-two-entries-bash.*`. Para volver al estado
anterior se ejecuta con `sudo bash` el archivo `restaurar.sh` que el script imprime.
Conviene conservarlo hasta probar ambos sistemas. No se ejecuta `grub-install` ni se
modifican entradas de firmware UEFI.

## Validación realizada

```bash
bash -n menu-dual.sh
bash test-menu-dual.sh
```

Las pruebas generan menús con datos ficticios, validan su sintaxis con
`grub-script-check` y comprueban orden, predeterminado, rutas estables, /boot separado,
módulo LVM, parámetros Btrfs y rechazo de literales inválidos. No simulan un arranque
ni prueban físicamente esos diseños de disco. La aplicación completa requiere una
ejecución administrativa; no fue ejecutada sobre el sistema durante la conversión.

Referencias: [configuración de GRUB](https://www.gnu.org/software/grub/manual/grub/html_node/Simple-configuration.html)
y [búsqueda por UUID](https://www.gnu.org/software/grub/manual/grub/html_node/search.html).
