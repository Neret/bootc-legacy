#!/usr/bin/env bash
# install.sh - installazione pulita da live Fedora per PC fisso UEFI (GRUB via bootupd + HDD)
#
# Layout GPT: 1=ESP | 2=root ext4 | 3=scratch temporanea (storage podman) a fine disco.
# A fine installazione la scratch viene eliminata e la root la riassorbe.
#
# Uso:
#   DISK=/dev/sda IMAGE=ghcr.io/neret/fedora-bootc-legacy-intel-os:latest bash install.sh

set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

# ---------------- CONFIGURAZIONE ----------------
DISK="${DISK:-/dev/sda}"
IMAGE="${IMAGE:-ghcr.io/neret/fedora-bootc-legacy-intel-os:latest}"
ESP_SIZE="${ESP_SIZE:-512M}"
SCRATCH_SIZE="${SCRATCH_SIZE:-32G}"
ASSUME_YES="${ASSUME_YES:-0}"

SCRATCH_MAP="scratchtmp"
MNT="/mnt/target"
SCR="/mnt/scratch"
GPT_BACKUP="/root/gpt-prima-del-grow.bak"
BOOTC_LOG="/root/bootc-install.log"

if [[ "$DISK" =~ [0-9]$ ]]; then PFX="${DISK}p"; else PFX="$DISK"; fi
ESP="${PFX}1"
ROOT="${PFX}2"
SCRATCH="${PFX}3"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'ATTENZIONE: %s\n' "$*" >&2; }
die()  { printf '\nERRORE: %s\n' "$*" >&2; exit 1; }

ROOT_START=""
ROOT_GUID=""
ROOT_UUID=""

unmount_all() {
  local m
  for m in "$MNT/boot/efi" "$MNT/boot" "$MNT" /var/tmp /var/lib/containers "$SCR"; do
    mountpoint -q "$m" && umount "$m" || true
  done
  cryptsetup status "$SCRATCH_MAP" >/dev/null 2>&1 && cryptsetup close "$SCRATCH_MAP" || true
  return 0
}
trap unmount_all EXIT

# ---------------- 1. PREREQUISITI ----------------
log "[1/9] Prerequisiti (ambiente UEFI)"
[[ -d /sys/firmware/efi ]] || die "la macchina NON e' avviata in UEFI: riavvia la live in modalita' UEFI"
dnf install -y --setopt=install_weak_deps=False \
  podman gdisk e2fsprogs util-linux cryptsetup dosfstools efibootmgr

# ---------------- 2. CONFERMA ----------------
log "[2/9] Conferma"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK"
if [[ "$ASSUME_YES" != 1 ]]; then
  read -rp "Questo CANCELLA TUTTO su $DISK. Scrivi 'cancella' per continuare: " ans
  [[ "$ans" == "cancella" ]] || die "annullato"
fi

# ---------------- 3. PARTIZIONAMENTO GPT (ESP + Root + Scratch) ----------------
log "[3/9] Partizionamento GPT: ESP $ESP_SIZE + root + scratch temporanea ($SCRATCH_SIZE)"
unmount_all

if lsblk -nrpo MOUNTPOINTS "$DISK" | grep -q .; then
  die "partizioni di $DISK ancora montate (e' il disco della live?)"
fi

wipefs -a -f "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n1:2048:+"$ESP_SIZE" -t1:ef00 -c1:esp "$DISK"
sgdisk -n3:-"$SCRATCH_SIZE":0 -t3:8300 -c3:scratch "$DISK"
sgdisk -n2:0:0 -t2:8300 -c2:root "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 1

[[ -b "$ESP" && -b "$ROOT" && -b "$SCRATCH" ]] || die "partizioni non create correttamente: $ESP $ROOT $SCRATCH"

ROOT_START="$(sgdisk -i2 "$DISK" | awk '/^First sector:/ {print $3}')"
ROOT_GUID="$(sgdisk -i2 "$DISK" | awk '/^Partition unique GUID:/ {print $4}')"
[[ -n "$ROOT_START" && -n "$ROOT_GUID" ]] || die "impossibile leggere inizio/GUID della root"

# ---------------- 4. SCRATCH TEMPORANEA ----------------
log "[4/9] Storage Podman su scratch (cifrata con chiave casuale, usa e getta)"
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
  --key-file /dev/urandom --batch-mode "$SCRATCH" "$SCRATCH_MAP"

mkfs.ext4 -F -q -L scratch "/dev/mapper/$SCRATCH_MAP"
mkdir -p "$SCR" /var/lib/containers
mount "/dev/mapper/$SCRATCH_MAP" "$SCR"
mkdir -p "$SCR/containers" "$SCR/tmp"
chmod 1777 "$SCR/tmp"

mount --bind "$SCR/tmp" /var/tmp
mount --bind "$SCR/containers" /var/lib/containers

mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<EOT
[storage]
driver="overlay"
graphroot="/var/lib/containers/storage"
runroot="/run/containers/storage"
EOT

podman system reset -f || true

export TMPDIR="/var/tmp" TEMP="/var/tmp" TMP="/var/tmp"

groot="$(podman info --format '{{ .Store.GraphRoot }}')"
[[ "$groot" == "/var/lib/containers/storage" ]] || die "GraphRoot errato: $groot"
df -h /var/lib/containers

# ---------------- 5. PULL DELL'IMMAGINE ----------------
log "[5/9] Pull dell'immagine bootc ($IMAGE)"
podman pull "$IMAGE" || die "pull fallito (verifica connessione o credenziali)"

# ---------------- 6. FILESYSTEM ----------------
log "[6/9] Formattazione ESP (FAT32) e root (ext4)"
mkfs.vfat -F32 -n EFI "$ESP"
mkfs.ext4 -F -m 1 -O verity -L root "$ROOT"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
[[ -n "$ROOT_UUID" ]] || die "UUID della root non leggibile"

# ---------------- 7. BOOTC INSTALL (UEFI) ----------------
log "[7/9] bootc install to-filesystem (bootloader: shim + GRUB via bootupd)"
mkdir -p "$MNT"
mount "$ROOT" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESP" "$MNT/boot/efi"

set +e
podman run --rm --privileged --pid=host --security-opt label=disable \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v /var/tmp:/var/tmp \
  -e TMPDIR=/var/tmp \
  -v "$MNT":/target \
  "$IMAGE" \
  bootc install to-filesystem \
    --root-mount-spec="UUID=${ROOT_UUID}" \
    --skip-finalize \
    /target 2>&1 | tee "$BOOTC_LOG"
rc=${PIPESTATUS[0]}
set -e
(( rc == 0 )) || die "bootc install fallito (vedi $BOOTC_LOG)"

# ---------------- 8. VERIFICA BOOTLOADER UEFI ----------------
log "[8/9] Verifica ESP, fallback UEFI e voce NVRAM"
EFI_DIR="$MNT/boot/efi/EFI"
[[ -f "$EFI_DIR/fedora/shimx64.efi" ]] || \
  die "shim non trovato nella ESP: NON riavviare, controlla $BOOTC_LOG"

compgen -G "$MNT/boot/loader/entries/*.conf" >/dev/null || \
  warn "nessuna voce BLS in $MNT/boot/loader/entries: controlla $BOOTC_LOG prima di riavviare"

# Percorso di fallback per firmware che ignorano le voci NVRAM
if [[ ! -f "$EFI_DIR/BOOT/BOOTX64.EFI" ]]; then
  mkdir -p "$EFI_DIR/BOOT"
  cp -r "$EFI_DIR/fedora/." "$EFI_DIR/BOOT/"
  mv "$EFI_DIR/BOOT/shimx64.efi" "$EFI_DIR/BOOT/BOOTX64.EFI"
fi

efibootmgr -c -d "$DISK" -p 1 -L "Fedora bootc" -l '\EFI\fedora\shimx64.efi' || \
  warn "voce NVRAM non creata: scegli il disco dal menu di boot del firmware (usa il fallback)"

sync

# ---------------- 9. RITORNO DELLO SPAZIO SCRATCH ALLA ROOT ----------------
log "[9/9] Pulizia scratch ed espansione della root"
unmount_all

grow_root() {
  local rc=0
  sgdisk --backup="$GPT_BACKUP" "$DISK" >/dev/null || return 1

  sgdisk -d3 -d2 \
    -n2:"${ROOT_START}":0 \
    -t2:8300 \
    -c2:root \
    -u2:"$ROOT_GUID" \
    "$DISK" >/dev/null || return 1

  partprobe "$DISK" || true
  udevadm settle

  e2fsck -f -y "$ROOT" || rc=$?
  (( rc <= 1 )) || return 1

  resize2fs "$ROOT" || return 1
}

if grow_root; then
  echo "Root allargata: spazio scratch riassorbito."
else
  warn "Allargamento non completato. Puoi farlo dopo con resize2fs."
fi

sync

echo
echo "=================================================="
echo " INSTALLAZIONE COMPLETATA"
echo " Immagine: $IMAGE"
echo " Disco:    $DISK (UEFI, GPT, ESP + ext4)"
echo "=================================================="
lsblk -f "$DISK"
