#!/usr/bin/env bash
# install-legacy.sh - installazione pulita da live CD Fedora per PC Fisso (BIOS/Legacy + GRUB + HDD)
#
# Usa una partizione SCRATCH temporanea a fine disco per lo storage di podman.
# A fine installazione la elimina e riassorbe lo spazio nella partizione root ext4.
#
# Uso:
#   DISK=/dev/sda IMAGE=ghcr.io/neret/fedora-bootc-legacy-intel-os:latest bash install.sh

set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"

# ---------------- CONFIGURAZIONE ----------------
DISK="${DISK:-/dev/sda}"
IMAGE="${IMAGE:-ghcr.io/neret/fedora-bootc-legacy-intel-os:latest}"
SCRATCH_SIZE="${SCRATCH_SIZE:-32G}"
ASSUME_YES="${ASSUME_YES:-0}"

SCRATCH_MAP="scratchtmp"
MNT="/mnt/target"
SCR="/mnt/scratch"
GPT_BACKUP="/root/gpt-prima-del-grow.bak"
BOOTC_LOG="/root/bootc-install.log"

if [[ "$DISK" =~ [0-9]$ ]]; then PFX="${DISK}p"; else PFX="$DISK"; fi
ROOT="${PFX}1"
SCRATCH="${PFX}2"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'ATTENZIONE: %s\n' "$*" >&2; }
die()  { printf '\nERRORE: %s\n' "$*" >&2; exit 1; }

STAGE=""
ROOT_START=""
ROOT_GUID=""

unmount_all() {
  set +e
  mountpoint -q "$MNT/boot" && umount "$MNT/boot"
  mountpoint -q "$MNT" && umount "$MNT"
  mountpoint -q /var/tmp && umount /var/tmp
  mountpoint -q /var/lib/containers && umount /var/lib/containers
  mountpoint -q "$SCR" && umount "$SCR"
  cryptsetup status "$SCRATCH_MAP" >/dev/null 2>&1 && cryptsetup close "$SCRATCH_MAP"
  return 0
}

cleanup() {
  set +e
  unmount_all
  [[ -n "$STAGE" ]] && rm -rf "$STAGE"
  return 0
}
trap cleanup EXIT

# ---------------- 1. PREREQUISITI ----------------
log "[1/9] Prerequisiti (Ambiente BIOS Legacy)"
[[ -d /sys/firmware/efi/efivars ]] && die "la macchina e' avviata in UEFI, usa uno script UEFI anziche' legacy"
dnf install -y --setopt=install_weak_deps=False \
  podman gdisk e2fsprogs util-linux grub2-pc grub2-tools

# ---------------- 2. CONFERMA ----------------
log "[2/9] Conferma"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$DISK"
if [[ "$ASSUME_YES" != 1 ]]; then
  read -rp "Questo CANCELLA TUTTO su $DISK. Scrivi 'cancella' per continuare: " ans
  [[ "$ans" == "cancella" ]] || die "annullato"
fi

# ---------------- 3. PARTIZIONAMENTO GPT (BIOS: Root + Scratch) ----------------
log "[3/9] Partizionamento GPT MBR-hybrid: Root + scratch temporanea ($SCRATCH_SIZE)"
unmount_all

if lsblk -nrpo MOUNTPOINTS "$DISK" | grep -q .; then
  die "partizioni di $DISK ancora montate (e' il disco della live?)"
fi

wipefs -a -f "$DISK"
sgdisk --zap-all "$DISK"

# Partizione 2: Scratch temporanea in fondo al disco
sgdisk -n2:-"$SCRATCH_SIZE":0 -t2:8300 -c2:scratch "$DISK"
# Partizione 1: Root che occupa tutto lo spazio rimanente all'inizio
sgdisk -n1:2048:-$((${SCRATCH_SIZE%G} * 1024 * 1024 * 1024 / 512 + 2048)):0 -t1:8300 -c1:root "$DISK" || \
sgdisk -n1:2048:0 -t1:8300 -c1:root "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 1

# Ridefiniamo le variabili con il nuovo ordine logico (Root=1, Scratch=2)
ROOT="${PFX}1"
SCRATCH="${PFX}2"

[[ -b "$ROOT" && -b "$SCRATCH" ]] || die "partizioni non create correttamente: $ROOT $SCRATCH"

ROOT_START="$(sgdisk -i1 "$DISK" | awk '/^First sector:/ {print $3}')"
ROOT_GUID="$(sgdisk -i1 "$DISK" | awk '/^Partition unique GUID:/ {print $4}')"
[[ -n "$ROOT_START" && -n "$ROOT_GUID" ]] || die "impossibile leggere inizio/GUID della root"

# ---------------- 4. SCRATCH TEMPORANEA ----------------
log "[4/9] Configurazione storage Podman su scratch non cifrata"
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
  --key-file /dev/urandom --batch-mode "$SCRATCH" "$SCRATCH_MAP"

mkfs.ext4 -F -q -L scratch "/dev/mapper/$SCRATCH_MAP"
mkdir -p "$SCR" /var/lib/containers
mount "/dev/mapper/$SCRATCH_MAP" "$SCR"
mkdir -p "$SCR/containers" "$SCR/runroot" "$SCR/tmp"
chmod 1777 "$SCR/tmp"

mount --bind "$SCR/tmp" /var/tmp
mount --bind "$SCR/containers" /var/lib/containers

mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<EOF
[storage]
driver="overlay"
graphroot="/var/lib/containers/storage"
runroot="/run/containers/storage"
EOF

podman system reset -f || true

export TMPDIR="/var/tmp"
export TEMP="/var/tmp"
export TMP="/var/tmp"

log "Verifica Podman storage:"
groot="$(podman info --format '{{ .Store.GraphRoot }}')"
[[ "$groot" == "/var/lib/containers/storage" ]] || die "GraphRoot errato: $groot"
df -h /var/lib/containers

# ---------------- 5. PULL DELL'IMMAGINE ----------------
log "[5/9] Pull dell'immagine bootc ($IMAGE)"
podman pull "$IMAGE" || die "pull fallito (verifica connessione o credenziali)"

# ---------------- 6. FILESYSTEM ROOT ----------------
log "[6/9] Formattazione Root ext4 (con supporto composefs)"
mkfs.ext4 -F -m 1 -L root "/dev/mapper/root" 2>/dev/null || mkfs.ext4 -F -m 1 -L root "$ROOT"

# ---------------- 7. BOOTC INSTALL (BIOS / GRUB) ----------------
log "[7/9] Installazione bootc to-filesystem (Target: GRUB BIOS)"
mkdir -p "$MNT"
mount "$ROOT" "$MNT"

podman run --rm --privileged --pid=host --security-opt label=disable \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v "$SCR":/scratch \
  -v /var/tmp:/var/tmp \
  -e TMPDIR=/var/tmp \
  -e TEMP=/var/tmp \
  -e TMP=/var/tmp \
  -e CONTAINER_TMPDIR=/var/tmp \
  -v "$MNT":/target \
  "$IMAGE" \
  bash -ec '
    set -euo pipefail
    export TMPDIR=/var/tmp
    export TEMP=/var/tmp
    export TMP=/var/tmp
    export CONTAINER_TMPDIR=/var/tmp

    echo "==> Esecuzione bootc install..."
    bootc install to-filesystem \
      --composefs-backend \
      --bootloader grub \
      --root-mount-spec="" \
      --skip-finalize \
      /target
  ' 2>&1 | tee "$BOOTC_LOG"

rc=${PIPESTATUS[0]}
(( rc == 0 )) || die "bootc install fallito (vedi $BOOTC_LOG)"

# ---------------- 8. INSTALLAZIONE GRUB NEL MBR ----------------
log "[8/9] Installazione del bootloader GRUB nel MBR di $DISK"
mount --bind /dev "$MNT/dev"
mount --bind /sys "$MNT/sys"
mount --bind /proc "$MNT/proc"

chroot "$MNT" grub2-install --target=i386-pc "$DISK"
chroot "$MNT" grub2-mkconfig -o /boot/grub2/grub.cfg

umount "$MNT/dev" "$MNT/sys" "$MNT/proc"
mount -o remount,ro "$MNT"

# ---------------- 9. RITORNO DELLO SPAZIO SCRATCH ALLA ROOT ----------------
log "[9/9] Pulizia scratch e espansione partizione root"
sync
unmount_all

grow_root() {
  local rc=0
  sgdisk --backup="$GPT_BACKUP" "$DISK" >/dev/null || return 1

  # Rimuoviamo la partizione scratch e ingrandiamo la root fino a fine disco
  sgdisk -d2 -d1 \
    -n1:"${ROOT_START}":0 \
    -t1:8300 \
    -c1:root \
    -u1:"$ROOT_GUID" \
    "$DISK" >/dev/null || return 1

  partprobe "$DISK" || true
  udevadm settle

  e2fsck -f -y "$ROOT" || rc=$?
  (( rc <= 1 )) || return 1

  resize2fs "$ROOT" || return 1
}

if grow_root; then
  echo "Root allargata con successo: spazio scratch riassorbito."
else
  warn "Allargamento automatico non completato. Puoi farlo in seguito con resize2fs."
fi

sync

echo
echo "=================================================="
echo " INSTALLAZIONE COMPLETATA CON SUCCESSO!"
echo " Immagine: $IMAGE"
echo " Disco:    $DISK (BIOS Legacy MBR + GRUB)"
echo "=================================================="
lsblk -f "$DISK"
