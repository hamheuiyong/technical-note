#!/usr/bin/env bash
# sftp-backup.sh - archive SFTP users' uploaded files to a backup location.
# Meant to run from cron (e.g. monthly or every 2 months). For each user it
# creates one compressed tarball under a timestamped folder, writes a checksum
# manifest, and prunes old backup sets beyond the retention limit.
#
# Paths can be overridden via environment variables for testing.
set -euo pipefail

SRV_BASE="${SRV_BASE:-/srv}"                 # where per-user homes live (/srv/<user>)
SUBDIR="${SUBDIR:-uploads}"                   # sub-folder holding the uploaded files
BACKUP_ROOT="${BACKUP_ROOT:-/backup/sftp}"    # destination (ideally a separate disk/mount)
RETENTION="${RETENTION:-6}"                   # number of timestamped backup sets to keep
LOG="${LOG:-/var/log/sftp-backup.log}"

ts="$(date +%Y%m%d-%H%M%S)"
dest="$BACKUP_ROOT/$ts"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG" ; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
mkdir -p "$dest"

log "=== SFTP backup start -> $dest ==="

count=0
for home in "$SRV_BASE"/*/ ; do
    [[ -d "$home" ]] || continue
    user="$(basename "$home")"
    src="${home}${SUBDIR}"
    [[ -d "$src" ]] || { log "skip $user (no '$SUBDIR' dir)"; continue; }

    # skip empty uploads folders
    if [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        log "skip $user (empty)"; continue
    fi

    archive="$dest/${user}.tar.gz"
    if tar -czf "$archive" -C "$home" "$SUBDIR" 2>>"$LOG"; then
        size="$(du -h "$archive" | cut -f1)"
        log "backed up $user -> ${user}.tar.gz ($size)"
        count=$((count+1))
    else
        log "ERROR archiving $user"
    fi
done

# integrity manifest
( cd "$dest" && sha256sum ./*.tar.gz > SHA256SUMS 2>/dev/null || true )
log "archived $count user(s)"

# --- retention: keep only the newest $RETENTION backup sets ---
mapfile -t sets < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | sort)
if (( ${#sets[@]} > RETENTION )); then
    remove=$(( ${#sets[@]} - RETENTION ))
    for old in "${sets[@]:0:remove}"; do
        log "prune old backup $(basename "$old")"
        rm -rf "$old"
    done
fi

log "=== SFTP backup done (kept up to $RETENTION sets) ==="
