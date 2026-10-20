#!/usr/bin/env bash
# Usage: sudo ./create-sftp-users.sh users.txt
# Each line of users.txt: "userID, serial, name"
#   - Creates an SFTP account (no shell, chroot-jailed to /srv/<id>)
#   - The account's HOME (passwd field) is "/uploads" -> after chroot the user
#     lands directly in the writable uploads folder (no read-only landing).
#   - Records serial + name in the account comment (GECOS) field
#   - Each user belongs to a different organization -> mutually inaccessible
#
# Directory layout per user:
#   /srv/<id>            root:root  755   (chroot jail root; not writable by user)
#   /srv/<id>/uploads    <id>:<id>  700   (writable; this is the login home "/uploads")
#
# Re-running is SAFE:
#   - existing users: comment/group/home are updated, password is KEPT
#   - the credentials file is APPENDED, never truncated (only new passwords are added)
#   - set RESET_PASSWORD=true to force-generate a NEW password for existing users too
set -euo pipefail

SFTP_GROUP=sftpusers                 # must match sshd_config "Match Group" (selector only, not file owner)
SRV_BASE=/srv                        # parent path for chroot jails (/srv/<id>)
WRITABLE=uploads                     # writable folder name inside the jail
HOME_IN_JAIL="/$WRITABLE"            # passwd home (relative to chroot) -> login lands here
GEN_PASSWORD="${GEN_PASSWORD:-true}"      # true: auto-generate a random password for NEW users
RESET_PASSWORD="${RESET_PASSWORD:-false}" # true: also reset password for EXISTING users (env-overridable)
CRED_FILE=./sftp-credentials.csv     # record of generated credentials (appended, keep secure)

# --- preflight ---
USER_LIST="${1:-}"
[[ $EUID -eq 0 ]]                        || { echo "Run as root (sudo)."           >&2; exit 1; }
[[ -n "$USER_LIST" && -f "$USER_LIST" ]] || { echo "Usage: sudo $0 <userlist.txt>" >&2; exit 1; }

getent group "$SFTP_GROUP" >/dev/null || groupadd "$SFTP_GROUP"

# credentials file: create with header ONLY if missing; never truncate an existing one
if [[ "$GEN_PASSWORD" == true && ! -f "$CRED_FILE" ]]; then
    echo "user,serial,name,password" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
fi

# trim leading/trailing whitespace
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
valid='^[a-z_][a-z0-9_-]*$'           # allowed Linux username format

while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue          # comment line
    [[ -z "${raw//[[:space:]]/}" ]] && continue          # blank line

    IFS=',' read -r f_uid f_serial f_name <<< "$raw"
    user="$(trim "$f_uid")"; serial="$(trim "$f_serial")"; name="$(trim "$f_name")"
    user="${user,,}"                     # force username to lowercase

    if [[ ! "$user" =~ $valid ]]; then
        echo "  ! '$user' : invalid username -> skipped" >&2; continue
    fi
    [[ -z "$serial" ]] && echo "  ! $user : empty serial (continuing)" >&2

    # GECOS uses comma/colon as separators -> sanitize; spaces/tabs in name -> _
    csafe_serial="${serial//[:,]/_}"
    csafe_name="${name//[:,]/_}"
    csafe_name="${csafe_name//[[:space:]]/_}"
    while [[ "$csafe_name" == *__* ]]; do csafe_name="${csafe_name//__/_}"; done
    comment="serial=${csafe_serial} name=${csafe_name}"

    jail="$SRV_BASE/$user"               # chroot root
    writable="$jail/$WRITABLE"           # /srv/<id>/uploads
    set_pw=false

    if ! id "$user" &>/dev/null; then
        # primary group = per-user private group (auto) / sftpusers as supplementary (-G)
        # home (passwd) = /uploads / no shell / no home skeleton (-M) / record comment (-c)
        useradd -G "$SFTP_GROUP" -d "$HOME_IN_JAIL" -s /usr/sbin/nologin -M -c "$comment" "$user"
        echo "  + created $user  [$comment]"
        set_pw=true
    else
        usermod -aG "$SFTP_GROUP" -d "$HOME_IN_JAIL" -s /usr/sbin/nologin -c "$comment" "$user"
        if [[ "$RESET_PASSWORD" == true ]]; then
            echo "  ~ exists $user -> updated + PASSWORD RESET  [$comment]"; set_pw=true
        else
            echo "  ~ exists $user -> comment/group/home updated (password kept)  [$comment]"
        fi
    fi

    if [[ "$GEN_PASSWORD" == true && "$set_pw" == true ]]; then
        pw="$(openssl rand -base64 12)"
        printf '%s:%s\n' "$user" "$pw" | chpasswd
        printf '%s,%s,%s,%s\n' "$user" "$csafe_serial" "$csafe_name" "$pw" >> "$CRED_FILE"
    fi

    # chroot jail root: must be root:root, not writable by the user
    mkdir -p "$jail"; chown root:root "$jail"; chmod 755 "$jail"
    # writable uploads dir (= login home): owned by the user's private group + 700
    mkdir -p "$writable"; chown "$user:$user" "$writable"; chmod 700 "$writable"
done < "$USER_LIST"

echo "Done."
[[ "$GEN_PASSWORD" == true ]] && echo "Credentials appended to $CRED_FILE (600) - distribute, then delete securely."
