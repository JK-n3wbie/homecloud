#!/usr/bin/env bash
set -euo pipefail

# ==== KONFIGURATION ====
SHARE="//<ip_for_smb_share_host>/<smb_share_name>"
MOUNT_POINT="/mnt/share"
CREDENTIALS="/etc/samba/backup-cred"
LOG_DIR="/var/log/backup"
LOG_FILE="$LOG_DIR/backup_$(date +'%Y-%m-%d').log"

# Rsync kilder hvorfra den tager backup
RSYNC_SOURCES=(
  "/etc"
  "/home"
  "/opt"
)

# Rsync indstillinger
RSYNC_OPTS=(
  "-avh"                # arkiv, verbose, human-readable
  "--delete"            # fjern filer som ikke længere findes på kilden
  "--progress"
  "--partial"           # bevar delvist overførte filer ved afbrud
  "--inplace"           # opdater filer på plads (godt til store filer)
  "--numeric-ids"       # bevar UID/GID numerisk
  "--no-owner"          # sæt ikke ejer på destination
  "--no-group"          # sæt ikke gruppe
  "--no-perms"          # sæt ikke POSIX-permissions
  "--links"             # bevar symlinks som symlinks (kan give issues på Windows)
  "--exclude=.cache/"
  "--exclude=*.sock"    # sockets kan ikke kopieres
  "--exclude=lost+found/"
  "--exclude=.Trash-*/"
)

# CIFS mount options 
CIFS_OPTS=(
  "vers=3.0"
  "sec=ntlmssp"
  "credentials=$CREDENTIALS"
  "uid=$(id -u)"
  "gid=$(id -g)"
  "file_mode=0777"
  "dir_mode=0777"
)

# ==== HJÆLPEFUNKTIONER ====
log() {
  printf "[%s] %s\n" "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"
}

ensure_prereqs() {
  mkdir -p "$MOUNT_POINT"
  mkdir -p "$LOG_DIR"
}

host_up() {
  # Hurtigt netværkstjek – ping 2 gange.
  ping -c 2 -W 2 192.168.0.154 >/dev/null 2>&1
}

is_mounted() {
  mountpoint -q "$MOUNT_POINT"
}

mount_share() {
  if is_mounted; then
    log "Share er allerede mountet på $MOUNT_POINT."
    return
  fi
  local opts
  opts=$(IFS=, ; echo "${CIFS_OPTS[*]}")
  log "Monterer CIFS: $SHARE -> $MOUNT_POINT (opts: $opts)"
  mount -t cifs "$SHARE" "$MOUNT_POINT" -o "$opts"
}

umount_share() {
  if is_mounted; then
    log "Unmount af $MOUNT_POINT"
    umount "$MOUNT_POINT" || {
      log "Advarsel: umount fejlede – forsøger lazy umount."
      umount -l "$MOUNT_POINT" || true
    }
  else
    log "Share var ikke mountet; springer umount over."
  fi
}

run_rsync() {
  log "Starter rsync til $MOUNT_POINT …"
  set +e
  rsync "${RSYNC_OPTS[@]}" -- "${RSYNC_SOURCES[@]}" "$MOUNT_POINT" | tee -a "$LOG_FILE"
  local rc=$?
  set -e
# undgår exit ved error 23
  if [[ $rc -eq 0 ]]; then
    log "Rsync færdig (rc=0)."
  elif [[ $rc -eq 23 ]]; then
    log "Rsync færdig med advarsler (rc=23): nogle filer/attributter blev ikke kopieret. Se log for detaljer."
    return 0  # behandl som succes, så systemd ikke markerer fejl
  else
    log "Rsync fejl (rc=$rc)."
    return $rc
  fi
}

# ==== MAIN ====
main() {
  ensure_prereqs

  # Trap så vi altid forsøger at unmount ved exit
  trap 'log "Script afsluttes – rydder op."; umount_share' EXIT

  # Netværkstjek og retry-loop (fx op til 10 min)
  local attempts=0
  local max_attempts=10
  local sleep_seconds=60

  until host_up; do
    attempts=$((attempts + 1))
    log "Windows-host ikke tilgængelig (forsøg $attempts/$max_attempts). Prøver igen om ${sleep_seconds}s…"
    if (( attempts >= max_attempts )); then
      log "Opgiver denne omgang – destination utilgængelig."
      return 0  # Returnér 0, så systemd/timer ikke markerer fejl (vi prøver igen senere)
    fi
    sleep "$sleep_seconds"
  done

  # Monter, kør rsync, unmount (via trap)
  mount_share
  run_rsync
  log "Backup gennemført."
}

main "$@"
