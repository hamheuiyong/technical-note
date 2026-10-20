# Ubuntu 26.04 LTS SFTP 서버 구축·운영 가이드

대상 서버: `sftp-i3` (Ubuntu 26.04 LTS, minimal install, VM)
SSH/SFTP 포트: **58822** (기본 22에서 변경)
방화벽: **ufw** (특정 IP만 허용)
SFTP 계정: **다중 사용자**, 각 홈(격리 루트) = **`/srv/<사용자ID>`**, chroot 격리

> 이 문서는 실제 구축 과정에서 확정된 **정상 동작 절차**만 담았습니다.
> (중간에 시도했다가 문제를 일으킨 수동 `ssh.socket` override 방식은 제외)
>
> **한 번에 설정하려면 → [11. 통합 설정 스크립트](#11-통합-설정-스크립트-setup-sftp-serversh)** 를 사용한다.
> 서버 설정을 `sshd_config` 직접 편집 대신 **드롭인 `/etc/ssh/sshd_config.d/60-sftp.conf`** 로 넣고,
> 사용자 생성까지 한 스크립트로 처리한다. 3·6장은 그 내부 동작을 설명하는 참고 절차다.

---

## 0. 핵심 원칙

- SFTP는 별도 데몬이 아니라 **OpenSSH(sshd)의 서브시스템**이다. `openssh-server`만 있으면 되고, SSH 포트를 바꾸면 SFTP도 같은 포트를 쓴다.
- 서버는 **최소 서비스 + 방화벽으로 노출 통제**가 원칙. 붙어 있는 서비스가 적을수록 안전하다.
- 원격 작업 시 **현재 세션은 절대 끊지 말고**, 새 세션으로 정상 접속을 확인한 뒤 이전 설정을 정리한다.

---

## 1. 설치 옵션 (참고)

- 이미지: **Ubuntu Server (minimal)**. 데스크톱/GUI 선택 안 함.
- 설치 중 **OpenSSH server 설치** 체크.
- 디스크: SFTP 사용자 데이터가 `/srv` 아래에 쌓이므로, 업로드가 OS 파티션을 채우지 않도록 **`/srv`를 별도 파티션/디스크로 분리** 권장.
- 시간대·NTP 동기화 정확히(로그·인증에 중요).
- root 직접 로그인 대신 sudo 관리 계정 사용(`i3admin`).

> 프로덕션이라면 첫 포인트 릴리스(26.04.1) 이후 배포 권장.

---

## 2. 불필요한 서비스 정리 (VM 기준)

현황 확인:

```bash
systemctl list-units --type=service --state=running
```

VM/SFTP 전용이라 꺼도 되는 것:

```bash
# 물리 하드웨어용 — VM에서 불필요
sudo systemctl disable --now multipathd multipathd.socket   # SAN 멀티패스
sudo systemctl disable --now ModemManager                   # 모바일 브로드밴드
sudo systemctl disable --now kdump-tools                    # 커널 크래시 덤프(메모리 예약)

# 스냅 미사용 시 (선택)
sudo systemctl disable --now snapd snapd.socket
# 완전 제거: sudo apt purge snapd

# 직접 만든 로컬 VM이라 cloud-init이 불필요할 때 (클라우드 인스턴스면 유지)
sudo touch /etc/cloud/cloud-init.disabled
```

유지해야 할 것: `ssh`, `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`, `cron`, `rsyslog`, `dbus`, `unattended-upgrades`.

VM 성능 프로파일(선택):

```bash
sudo tuned-adm profile virtual-guest   # tuned 설치 시
```

---

## 3. SSH/SFTP 포트 변경 (22 → 58822)

> **중요:** Ubuntu 24.04+ / 26.04는 SSH가 **소켓 액티베이션(`ssh.socket`)** 으로 뜬다.
> `sshd_config`의 `Port`를 바꾸면, Ubuntu의 `sshd-socket-generator`가 이를 읽어
> **소켓 리슨 주소(IPv4+IPv6)를 자동 생성**한다. 따라서 **`sshd_config`만 고치면 되고,
> `ssh.socket`을 수동으로 override 하지 않는다.**
> (수동 override에 주소 없는 `ListenStream=58822`만 넣으면 `BindIPv6Only` 때문에
> IPv6 전용으로 축소되어 IPv4 접속이 `Connection refused` 된다 — 하지 말 것.)

### 3-1. sshd_config 편집

`/etc/ssh/sshd_config`:

```
Port 58822
```

### 3-2. 문법 검사 후 반영

```bash
sudo sshd -t                    # 오류 없으면 출력 없음
sudo systemctl daemon-reload    # 제너레이터가 소켓 주소 재생성
sudo systemctl restart ssh.socket
sudo systemctl restart ssh
```

### 3-3. 리슨 포트 확인 (IPv4·IPv6 둘 다 떠야 정상)

```bash
sudo ss -tlnp | grep 58822
```

정상 출력 예:

```
LISTEN 0 4096 0.0.0.0:58822 0.0.0.0:*  ...
LISTEN 0 4096    [::]:58822    [::]:*  ...
```

`0.0.0.0:58822`(IPv4)가 보여야 IPv4 클라이언트가 접속 가능하다.
`[::]:58822`만 보이면 IPv6 전용 상태이므로 수동 override 파일이 남아있는지 확인:

```bash
sudo systemctl cat ssh.socket
# /etc/systemd/system/ssh.socket.d/override.conf 가 있으면 삭제:
sudo rm -f /etc/systemd/system/ssh.socket.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ssh.socket ssh
```

### 3-4. 접속 검증 (현재 세션 유지한 채 새 세션에서)

```bash
ssh  -p 58822 i3admin@10.0.20.128
sftp -P 58822 i3admin@10.0.20.128    # sftp는 대문자 -P
```

---

## 4. 방화벽(ufw) — 특정 IP만 58822 허용

> **순서 중요:** ufw 기본 정책이 deny incoming이므로, **허용 규칙을 먼저 넣고** enable 한다.
> 그리고 "Anywhere(전체 개방)" 규칙은 만들지 않는다 — 특정 IP 제한이 무력화된다.

### 4-1. 관리자 IP 허용 규칙 추가 (enable 전)

```bash
sudo ufw allow from 10.0.20.173  to any port 58822 proto tcp comment 'panacea-control'
sudo ufw allow from 10.212.150.14 to any port 58822 proto tcp comment 'danielh-workstation'
```

### 4-2. 기본 정책 + 활성화

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
```

### 4-3. 확인

```bash
sudo ufw status numbered
```

허용 IP만 남아야 정상:

```
[ 1] 58822/tcp   ALLOW IN   10.0.20.173      # panacea-control
[ 2] 58822/tcp   ALLOW IN   10.212.150.14    # danielh-workstation
```

> `ALLOW IN ... Anywhere` 또는 `Anywhere (v6)` 규칙이 보이면 전체 개방이므로 삭제한다
> (번호 높은 것부터): `sudo ufw delete <번호>`

---

## 5. IPv6 정책

커널 레벨(`ipv6.disable=1`)로 IPv6를 통째로 끄지 않는다(snapd·apt·resolved가 IPv6를 전제로 동작해 경고/지연 발생 가능).

- IPv6를 실제 쓰면: 그대로 유지, ufw가 IPv4/IPv6 양쪽에서 허용 IP만 통제.
- 순수 IPv4망이라 SFTP만 IPv4로 제한하고 싶으면: `sshd_config`에 `AddressFamily inet` 추가 후 `sudo systemctl restart ssh`.

---

## 6. 다중 SFTP 계정 — chroot 격리 (홈: `/srv/<사용자ID>`, 조직 간 완전 격리)

여러 SFTP 사용자를 만들고, 각 사용자의 홈(격리 루트)을 **`/srv/<사용자ID>`** 로 지정한다.
각 사용자는 **서로 다른 조직**이므로, 자기 폴더 밖은 물론 **다른 사용자 데이터에도 접근 불가**해야 한다.

### 6-1. 격리 원칙과 디렉터리 설계

두 겹으로 격리한다:

1. **chroot** — 각 사용자의 파일시스템 루트가 자기 `/srv/<ID>`로 고정된다. `/srv` 상위나 옆
   사용자 폴더(`/srv/<다른ID>`)는 보이지도 접근되지도 않는다.
2. **파일 권한** — 업로드 폴더를 **본인 전용 그룹 소유 + `700`** 으로 잠가, chroot와 무관하게
   파일 레벨에서도 조직 간 접근을 차단한다(심층 방어).

> ⚠️ 공유 그룹(`sftpusers`)이 각 사용자 데이터를 소유하게 하면 안 된다.
> `sftpusers`는 **sshd `Match Group` 선택용(보조 그룹)** 으로만 쓰고, **파일은 사용자 전용 그룹이 소유**한다.

`ChrootDirectory`로 지정된 경로와 그 상위 경로는 **모두 root 소유 + 그룹/기타 쓰기 불가**여야 한다
(하나라도 어기면 접속이 끊기며 로그에 `bad ownership or modes` 기록). 최종 구조:

```
/srv                       root:root 755   (기본값)
/srv/<user>                root:root 755   ← chroot 격리 루트 (사용자 쓰기 불가; chroot 필수 조건)
/srv/<user>/uploads        <user>:<user> 700   ← 업로드 폴더, 본인만 접근 (다른 조직 차단)
```

> - `/srv/<user>` 의 755 는 chroot가 요구하는 조건이며, "other"에 r-x가 있어도 chroot 밖에서 도달할
>   수 없어 누출되지 않는다. 실제 데이터가 담기는 `uploads` 는 `700` 이라 소유자 외 완전 차단된다.
> - **로그인 착지 위치**: 계정의 홈(passwd 필드)을 chroot 내부 기준 **`/uploads`** 로 지정한다.
>   그러면 SFTP 접속 시 읽기전용 루트(`/`)가 아니라 **쓰기 가능한 `uploads` 폴더에 바로 떨어진다**
>   (`cd uploads` 불필요). chroot 루트는 여전히 `/srv/<user>` 이다.

### 6-2. 선택용 그룹 + sshd_config Match 블록

```bash
sudo groupadd -f sftpusers      # 파일 소유가 아니라 Match 선택용
```

`/etc/ssh/sshd_config` 맨 아래 (한 번만 설정하면 그룹 소속 사용자 전원에 적용):

```
Match Group sftpusers
    ChrootDirectory /srv/%u
    ForceCommand internal-sftp -u 0077
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
```

> `Match Group` 은 **보조 그룹 소속도 인식**하므로, 사용자를 sftpusers에 보조 그룹으로만 넣어도
> chroot가 정상 적용된다. `%u` 는 접속 사용자 ID로 치환된다 → 각자 `/srv/<자기ID>` 에 격리.
>
> `internal-sftp -u 0077` 의 `-u 0077` 은 SFTP 세션 umask=077 → **업로드되는 새 파일은 `600`,
> 새 폴더는 `700`** 으로 생성된다(기본 umask 022는 파일 644·폴더 755라 "others read"가 붙는다).
> chroot + uploads 폴더 700 때문에 다른 SFTP 사용자가 읽을 수는 없지만, 파일 자체도 `600` 으로
> 만들어 두는 심층 방어다.

적용:

```bash
sudo sshd -t && sudo systemctl restart ssh
```

> **기존에 이미 올라온 파일 정리**(umask는 이후 업로드에만 적용됨):
> ```bash
> sudo find /srv/*/uploads -type f -exec chmod 600 {} +
> sudo find /srv/*/uploads -type d -exec chmod 700 {} +
> ```

### 6-3. 사용자 목록 파일 + 일괄 생성 스크립트

**사용자 목록 파일** `users.txt` — 한 줄에 `사용자ID, 시리얼번호, 이름` (콤마 구분).
빈 줄과 `#` 로 시작하는 줄은 무시된다. 시리얼번호와 이름은 계정의 **주석(comment) 필드**에 기록된다:

```
# userID, serial, name
BCScarFW01,FGT90GTK23023779,BC
BISMISSFW01,FGT60FTK23011233,BIS
MTEK-FG100E,FGT60ETK19005476,MTEK
# 건너뛸 줄, SN-9999, (앞에 # → 건너뜀)
```

> - 각 필드 앞뒤 공백(탭 포함)은 자동으로 제거된다. 콤마 뒤 빈칸은 있어도/없어도 무관.
> - **사용자ID는 자동으로 소문자로 변환**된다(위 예시 → `bcscarfw01`, `bismissfw01`, `mtek-fg100e`).
> - **이름 안의 공백(탭 포함)은 `_` 로 치환**된다(예: `Alpha Corporation` → `Alpha_Corporation`). 콤마·콜론도 `_` 로 치환.

**생성 스크립트** `create-sftp-users.sh`:

```bash
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
```

**실행:**

```bash
chmod +x create-sftp-users.sh
sudo ./create-sftp-users.sh users.txt
```

> **기존에 `upload/` 폴더로 테스트한 계정이 있다면**(홈이 `/srv/<id>` 였던 경우) 한 번 마이그레이션한다.
> 폴더명을 `uploads` 로 바꾼 뒤 스크립트를 다시 돌리면 홈(`/uploads`)·권한이 정정된다:
> ```bash
> for d in /srv/*/upload; do [ -d "$d" ] && mv "$d" "${d}s"; done   # upload -> uploads (데이터 보존)
> sudo ./create-sftp-users.sh users.txt                             # 홈=/uploads, 소유/권한 재적용
> ```

**기록된 주석 + 홈 확인:**

```bash
getent passwd org-alpha
# org-alpha:x:1002:1002:serial=SN-10023 name=Alpha_Corporation:/uploads:/usr/sbin/nologin
#                        └──── 주석(GECOS 5번째 필드) ────┘        └ 홈=/uploads (chroot 내부 착지)

# 시리얼/이름만 보기:
getent passwd org-alpha | cut -d: -f5
```

- 시리얼번호·이름은 계정 **주석(GECOS 5번째 필드)** 에 `serial=... name=...` 형태로 저장된다.
  나중에 `getent passwd <ID> | cut -d: -f5` 또는 `chfn -l`(finger) 등으로 조회할 수 있다.
- 스크립트는 **재실행해도 안전**하다. 기존 사용자는 주석·그룹만 갱신하고 **비밀번호는 유지**하며,
  자격증명 CSV는 **덮어쓰지 않고 이어쓰기**(파일이 없을 때만 헤더 생성)한다. 신규 사용자만 새로 생성·기록된다.
- **기존 사용자 비밀번호를 새로 발급**하려면(예: 자격증명 기록을 잃었을 때):
  ```bash
  sudo RESET_PASSWORD=true ./create-sftp-users.sh users.txt
  ```
  `users.txt`에 있는 사용자 전원의 비밀번호가 재발급되어 CSV 맨 아래에 append 된다(가장 아래 행이 최신).
  특정 사용자 한 명만 재발급하려면: `sudo passwd <ID>`.
- 비밀번호 인증을 쓰려면 `sshd_config`에 `PasswordAuthentication yes` 필요.
  임의 비밀번호는 `sftp-credentials.csv`(권한 600, `user,serial,name,password`)에 기록되며,
  **각 조직에 전달한 뒤 이 파일은 삭제**한다.
- 비밀번호 대신 SSH 키를 쓰려면 `GEN_PASSWORD=false`로 두고 6-4의 키 방식을 따른다.

실행:

```bash
chmod +x create-sftp-users.sh
sudo ./create-sftp-users.sh alice bob carol
```

### 6-4. 비밀번호 / 키 설정

```bash
sudo passwd alice                 # 대화형
# 또는 일괄:  echo 'alice:비번' | sudo chpasswd
```

> 비밀번호 인증을 쓰려면 `sshd_config`에 `PasswordAuthentication yes`가 필요하다.
> 보안상 **SSH 공개키 방식**을 권장한다. 키를 쓸 경우 chroot 특성상 키 파일 위치에 주의:
> 격리 루트는 읽기 전용이라 사용자가 `~/.ssh`를 못 만들 수 있으므로,
> 관리자가 `AuthorizedKeysFile /etc/ssh/authorized_keys/%u` 같은 **중앙 경로**로 지정해 두는 방식이 편하다.

### 6-5. 접속 확인

```bash
sftp -P 58822 alice@10.0.20.128
# 로그인하면 곧바로 /uploads (쓰기 가능) 에 착지 → 바로 put/get
# pwd 로 확인하면 /uploads 로 표시된다
```

### 6-6. 사용자 추가 / 삭제 (운영)

```bash
# 추가 — 스크립트 재실행 (기존 사용자는 건너뜀/갱신, 신규만 생성)
sudo ./create-sftp-users.sh dave

# 삭제 — 계정 제거 (데이터도 지우려면 신중히)
sudo userdel dave
sudo rm -rf /srv/dave          # 데이터까지 삭제할 때만
```

---

## 7. 운영 — 접속 IP 추가/삭제

### IP 추가

```bash
sudo ufw allow from 128.10.5.4 to any port 58822 proto tcp comment '설명'
```

### IP 삭제

```bash
sudo ufw status numbered
sudo ufw delete <번호>
# 또는 규칙 그대로 지정:
sudo ufw delete allow from 128.10.5.4 to any port 58822 proto tcp
```

> enable 상태에서 규칙 추가/삭제는 즉시 반영되며 기존 접속은 끊기지 않는다.

---

## 8. 업로드 파일 정기 백업 (월 1회 / 2개월 1회, 크론)

각 사용자의 `uploads/` 폴더를 다른 위치에 **사용자별 압축본**으로 보관하고, 오래된 세트는 자동
정리(retention)한다. 백업 대상은 가급적 **다른 디스크/마운트**(예: 별도 볼륨, NAS 마운트)로 둔다.

### 8-1. 백업 스크립트 `sftp-backup.sh`

```bash
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
```

배치 및 권한:

```bash
sudo install -m 700 -o root -g root sftp-backup.sh /usr/local/sbin/sftp-backup.sh
sudo mkdir -p /backup/sftp                 # 대상 폴더(가능하면 별도 디스크 마운트)
sudo /usr/local/sbin/sftp-backup.sh        # 수동 1회 실행 테스트
```

> 결과 구조: `/backup/sftp/<YYYYMMDD-HHMMSS>/<user>.tar.gz` + `SHA256SUMS`.
> `RETENTION` 개수만큼 최신 세트만 남기고 오래된 것은 자동 삭제된다(월 1회 기준 6이면 약 6개월 보관).

### 8-2. 크론 등록

`/etc/cron.d/sftp-backup` 파일로 등록(root 실행). `flock` 으로 중복 실행 방지:

**월 1회** — 매월 1일 02:00:

```
0 2 1 * * root /usr/bin/flock -n /run/sftp-backup.lock /usr/local/sbin/sftp-backup.sh
```

**2개월 1회** — 1·3·5·7·9·11월 1일 02:00 (`*/2` = 격월):

```
0 2 1 */2 * root /usr/bin/flock -n /run/sftp-backup.lock /usr/local/sbin/sftp-backup.sh
```

> `*/2` 는 홀수 달(1월부터 격월). 짝수 달(2·4·6·8·10·12월)에 돌리려면 `2,4,6,8,10,12` 로 지정한다.
> 시간(UTC/로컬)은 서버 타임존을 따른다 — `timedatectl` 로 확인.

적용 확인:

```bash
sudo systemctl restart cron       # cron.d 재적용 (보통 자동 반영)
grep -H . /etc/cron.d/sftp-backup
```

### 8-3. 복원

```bash
# 특정 세트에서 한 사용자 복원
tar -xzf /backup/sftp/<YYYYMMDD-HHMMSS>/org-alpha.tar.gz -C /srv/org-alpha
# 무결성 확인
cd /backup/sftp/<YYYYMMDD-HHMMSS> && sha256sum -c SHA256SUMS
```

> 복원 후에는 소유권이 tar 안의 값으로 돌아올 수 있으니, 필요 시
> `chown -R org-alpha:org-alpha /srv/org-alpha/uploads && chmod 700 /srv/org-alpha/uploads` 로 재설정한다.

### 8-4. RETENTION / 보관주기 가이드

- 월 1회 + `RETENTION=6` → 최근 6개월 보관
- 월 1회 + `RETENTION=12` → 최근 12개월 보관
- 2개월 1회 + `RETENTION=6` → 최근 12개월 보관
- 대상 디스크 용량과 데이터 증가량을 보고 `RETENTION` 을 조정한다(오래된 세트는 자동 삭제됨).

---

## 9. 검증 체크리스트

- [ ] `sudo ss -tlnp | grep 58822` 에 `0.0.0.0:58822` 와 `[::]:58822` 둘 다 표시
- [ ] 허용 IP에서 `ssh -p 58822` / `sftp -P 58822` 접속 성공
- [ ] 허용 목록에 없는 IP에서는 timeout(차단)
- [ ] `sudo ufw status numbered` 에 Anywhere 규칙 없음
- [ ] SFTP 사용자 로그인 시 곧바로 `/uploads` (= `/srv/<ID>/uploads`) 에 착지하고 쓰기 가능
- [ ] 격리 루트 `/srv/<ID>` 소유·권한이 `root:root 755` (chroot 조건 충족)
- [ ] `/srv/<ID>/uploads` 소유·권한이 `<ID>:<ID> 700` (다른 조직 사용자가 접근 불가)
- [ ] 사용자 A 계정으로 다른 조직 B의 데이터가 보이지/열리지 않는지 실제 확인
- [ ] 업로드한 새 파일 권한이 `600`(폴더 `700`) 인지 확인 (`internal-sftp -u 0077` 적용)
- [ ] 재부팅 후에도 위 항목 모두 정상
- [ ] 백업 스크립트 수동 실행 성공 + `/backup/sftp/<날짜>/` 에 사용자별 tar.gz 생성
- [ ] `/etc/cron.d/sftp-backup` 등록 및 다음 실행 시각 확인

## 10. 잠금(lock-out) 복구

허용 IP가 바뀌어 접속이 막히면, 하이퍼바이저 **VM 콘솔**로 로그인해:

```bash
sudo ufw disable        # 임시로 방화벽 해제 후 규칙 수정
```

허용 IP는 가급적 **고정 IP**를 쓰고, 유동이면 대역(CIDR) 허용 또는 VPN 경유를 고려한다.

---

## 11. 통합 설정 스크립트 (setup-sftp-server.sh)

서버 설정(포트·chroot·하드닝)을 **`sshd_config` 직접 편집 대신 드롭인 파일
`/etc/ssh/sshd_config.d/60-sftp.conf`** 로 작성하고, **사용자 생성까지 한 번에** 처리하는 통합 스크립트.

**드롭인 방식이 안전한 이유:** Ubuntu의 `sshd_config`는 `Include /etc/ssh/sshd_config.d/*.conf`가
파일 상단에 있지만, **included 드롭인 안의 `Match` 블록은 상위(메인) 파일로 누수되지 않는다**
(OpenSSH가 파일 경계에서 Match 컨텍스트를 리셋). 즉 드롭인 하나에 `Port` + `Match Group` 을 같이 넣어도
메인 설정의 `Subsystem`/`AcceptEnv` 등이 깨지지 않는다. `sshd -t` 로 검증 완료.

### 11-1. 사용자 목록 파일

기본 경로는 `/etc/sftp/users.txt`(스크립트 상단 `USER_LIST`에서 변경, 또는 실행 시 인자로 override).
한 줄에 `userID, serial, name`:

```
# userID, serial, name
BCScarFW01,FGT90GTK23023779,Berg Chilling Systems Inc
i3hqfw01,FGT90GTK23008610,I3 Solutions Inc
```

### 11-2. 스크립트

```bash
#!/usr/bin/env bash
# setup-sftp-server.sh
# One-shot SFTP setup for Ubuntu 24.04+/26.04:
#   1) writes an sshd drop-in (/etc/ssh/sshd_config.d/) - port + chroot jail + hardening
#   2) creates SFTP users from a user-list file
#
# Usage:
#   sudo ./setup-sftp-server.sh [USER_LIST]
#     USER_LIST : path to the user list (defaults to $USER_LIST below; $1 overrides it)
#
# User list format - one line per user: "userID, serial, name"
#   - userID is lowercased; serial + name are stored in the account comment (GECOS)
#   - blank lines and lines starting with # are ignored
#
# Env toggles:
#   GEN_PASSWORD=true|false     auto-generate a random password for NEW users (default true)
#   RESET_PASSWORD=true|false   also reset password for EXISTING users        (default false)
set -euo pipefail

########################### Configuration (edit here) ###########################
SSH_PORT=58822                              # SSH/SFTP port
SFTP_GROUP=sftpusers                        # group that selects the SFTP chroot policy
SRV_BASE=/srv                               # per-user chroot jail parent (/srv/<id>)
WRITABLE=uploads                            # writable folder / login home (=/uploads)
DROPIN=/etc/ssh/sshd_config.d/60-sftp.conf  # sshd drop-in this script manages
PASSWORD_AUTH=yes                           # yes: allow password login for SFTP users only
USER_LIST="${1:-/etc/sftp/users.txt}"       # <-- user list path (override by passing an arg)

GEN_PASSWORD="${GEN_PASSWORD:-true}"
RESET_PASSWORD="${RESET_PASSWORD:-false}"
CRED_FILE="${CRED_FILE:-./sftp-credentials.csv}"
#################################################################################

HOME_IN_JAIL="/$WRITABLE"
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

echo "==> [1/2] Configuring SSH/SFTP server"

getent group "$SFTP_GROUP" >/dev/null || groupadd "$SFTP_GROUP"

# Build the drop-in. NOTE: a Match block inside an included drop-in does NOT leak
# into the main sshd_config, so this is safe even though Ubuntu's Include is at the top.
install -d -m 755 "$(dirname "$DROPIN")"
{
    echo "# Managed by setup-sftp-server.sh - do not edit by hand"
    echo "Port ${SSH_PORT}"
    echo ""
    echo "Match Group ${SFTP_GROUP}"
    echo "    ChrootDirectory ${SRV_BASE}/%u"
    echo "    ForceCommand internal-sftp -u 0077"
    [[ "$PASSWORD_AUTH" == yes ]] && echo "    PasswordAuthentication yes"
    echo "    AllowTcpForwarding no"
    echo "    X11Forwarding no"
    echo "    PermitTunnel no"
} > "$DROPIN"
chmod 644 "$DROPIN"
echo "    wrote $DROPIN"

# Validate, then apply. On 24.04+/26.04 the socket generator reads Port on daemon-reload.
sshd -t
echo "    sshd -t OK"
systemctl daemon-reload
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh
if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} "; then
    echo "    listening on port ${SSH_PORT}"
else
    echo "    WARNING: port ${SSH_PORT} not listening yet - check: systemctl status ssh"
fi

echo "==> [2/2] Creating SFTP users from: $USER_LIST"
if [[ ! -f "$USER_LIST" ]]; then
    echo "    user list not found -> skipping user creation."
    echo "Done (server configured; no users created)."
    exit 0
fi

if [[ "$GEN_PASSWORD" == true && ! -f "$CRED_FILE" ]]; then
    echo "user,serial,name,password" > "$CRED_FILE"; chmod 600 "$CRED_FILE"
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
valid='^[a-z_][a-z0-9_-]*$'

while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${raw//[[:space:]]/}" ]] && continue

    IFS=',' read -r f_uid f_serial f_name <<< "$raw"
    user="$(trim "$f_uid")"; serial="$(trim "$f_serial")"; name="$(trim "$f_name")"
    user="${user,,}"

    if [[ ! "$user" =~ $valid ]]; then
        echo "    ! '$user' : invalid username -> skipped" >&2; continue
    fi
    [[ -z "$serial" ]] && echo "    ! $user : empty serial (continuing)" >&2

    csafe_serial="${serial//[:,]/_}"
    csafe_name="${name//[:,]/_}"
    csafe_name="${csafe_name//[[:space:]]/_}"
    while [[ "$csafe_name" == *__* ]]; do csafe_name="${csafe_name//__/_}"; done
    comment="serial=${csafe_serial} name=${csafe_name}"

    jail="$SRV_BASE/$user"; writable="$jail/$WRITABLE"; set_pw=false

    if ! id "$user" &>/dev/null; then
        useradd -G "$SFTP_GROUP" -d "$HOME_IN_JAIL" -s /usr/sbin/nologin -M -c "$comment" "$user"
        echo "    + created $user  [$comment]"; set_pw=true
    else
        usermod -aG "$SFTP_GROUP" -d "$HOME_IN_JAIL" -s /usr/sbin/nologin -c "$comment" "$user"
        if [[ "$RESET_PASSWORD" == true ]]; then
            echo "    ~ exists $user -> updated + PASSWORD RESET  [$comment]"; set_pw=true
        else
            echo "    ~ exists $user -> updated (password kept)  [$comment]"
        fi
    fi

    if [[ "$GEN_PASSWORD" == true && "$set_pw" == true ]]; then
        pw="$(openssl rand -base64 12)"
        printf '%s:%s\n' "$user" "$pw" | chpasswd
        printf '%s,%s,%s,%s\n' "$user" "$csafe_serial" "$csafe_name" "$pw" >> "$CRED_FILE"
    fi

    mkdir -p "$jail";     chown root:root "$jail";        chmod 755 "$jail"
    mkdir -p "$writable"; chown "$user:$user" "$writable"; chmod 700 "$writable"
done < "$USER_LIST"

echo "Done."
[[ "$GEN_PASSWORD" == true ]] && echo "Credentials appended to $CRED_FILE (600) - distribute, then delete securely."
```

### 11-3. 실행

```bash
sudo mkdir -p /etc/sftp && sudo cp users.txt /etc/sftp/users.txt   # 목록 배치(선택)
chmod +x setup-sftp-server.sh

sudo ./setup-sftp-server.sh                       # 기본 목록 경로(/etc/sftp/users.txt) 사용
sudo ./setup-sftp-server.sh /path/to/users.txt    # 목록 경로를 인자로 지정
GEN_PASSWORD=true sudo ./setup-sftp-server.sh users.txt      # 신규 사용자 비번 자동발급
sudo RESET_PASSWORD=true ./setup-sftp-server.sh users.txt    # 기존 사용자 비번 재발급
```

### 11-4. 주의점

- 이 드롭인이 **포트·chroot 설정의 단일 소스**다. 이전에 `sshd_config`에 직접 넣은 `Port` 나
  `ssh.socket` override 가 남아 있으면 제거한다(중복 `Port` 는 여러 포트에서 동시 리슨하게 됨).
- `PASSWORD_AUTH=yes` 는 **SFTP 그룹 사용자에게만** 비밀번호 로그인을 허용한다(`Match` 블록 안).
  관리자 계정의 전역 인증 정책은 건드리지 않는다. 키 인증만 쓸 거면 `PASSWORD_AUTH=no`.
- 방화벽(특정 IP 허용)은 이 스크립트에 포함하지 않았다 → **4장 ufw** 절차로 별도 적용한다.
- 포트가 리슨되면(`ss -tlnp | grep :58822`), **현재 세션 유지한 채** 새 세션으로 접속을 검증한 뒤
  이전 설정을 정리한다.

---

## 12. /srv 를 SMB(Samba)로 접근 (전용 로컬 계정)

SFTP로 쌓인 `/srv` 데이터를 **새로 만든 전용 로컬 계정 하나**에게 SMB로 열어, 내부 LAN + VPN에서
관리·회수할 수 있게 한다.

### 12-1. 왜 "admin users" 방식인가 (권한 설계)

각 `/srv/<id>/uploads` 는 `700`(소유자만), 업로드 파일은 `600` 이다. 이 상태에서 다른 계정이
접근하게 하는 두 방법:

- **POSIX ACL** (`setfacl u:smbuser:rwX`) — 기존 파일은 읽히지만, SFTP가 새로 올리는 **600 모드
  파일은 ACL mask 가 0 이 되어 접근 불가**해진다(검증됨). 새 업로드마다 깨지므로 부적합.
- **Samba `admin users`** (권장) — 공유에 지정한 계정이 **공유 안에서 root 권한으로** 동작해
  파일 모드와 무관하게 `/srv` 전체를 읽고 쓴다. **기존 700/600 권한을 전혀 바꾸지 않아 SFTP
  사용자 간 격리가 그대로 유지**된다.

> ⚠️ `admin users` 계정은 공유 범위 안에서 root 급 권한을 가진다. 따라서 이 계정은 **강한
> 비밀번호로 보호**하고, SMB는 **내부망/VPN에만** 노출한다(인터넷 금지). SMB3 암호화를 강제한다.

> **다중 계정 가능**: 한 개로 제한되지 않는다. Samba의 `valid users`/`admin users` 는 목록을 받으며,
> **관리 그룹 방식**이 가장 깔끔하다 — 공유에 `admin users = @smbadmins` 로 그룹을 지정하고,
> 이후 관리자를 늘릴 땐 **계정을 그 그룹에 추가**하기만 하면 된다(smb.conf 재편집 불필요). 아래
> 스크립트가 이 방식이다.

> **셸 선택**: Samba 접근은 로그인 셸과 무관하다. 계정을 **SMB 전용**으로만 쓸 거면
> `SMB_SHELL=/usr/sbin/nologin`(권장, 서버 로그인 차단). 같은 사람이 **SSH로 서버 관리도** 할 거면
> `SMB_SHELL=/bin/bash` 로 두면 된다 — 이 경우 SSH 경로가 하나 더 생기니 ufw에서 그 IP를 58822로
> 허용하고, 비밀번호보다 **SSH 키**를 쓰고 sudo 는 필요할 때만 부여한다.

### 12-2. 진행 과정 (요약)

1. `samba` 설치
2. 관리 그룹(`smbadmins`) 생성 + 전용 로컬 계정 1개 이상 생성(셸 없음, 그룹에 소속) + Samba 비밀번호 등록(`smbpasswd`)
3. `/etc/samba/smb.conf` 에 `[srv]` 공유 추가 — `admin users = @smbadmins`, `hosts allow`(LAN+VPN), `smb encrypt`
4. `testparm` 검증 → `smbd` 활성화(NetBIOS `nmbd` 는 불필요하니 비활성)
5. 방화벽에서 **445/tcp 를 LAN + VPN 대역만** 허용
6. 클라이언트에서 `\\<서버IP>\srv` 로 접속 검증

### 12-3. 명령어로 직접 실행 (스크립트 대신)

값(사용자명·네트워크 대역)은 예시이니 환경에 맞게 바꾼다. 모두 root(`sudo`)로.

**1) Samba 설치**
```bash
sudo apt-get update
sudo apt-get install -y samba
```

**2) 관리 그룹 생성** — 이 그룹 소속만 공유 접근. 나중에 관리자 추가 시 smb.conf 재편집 불필요.
```bash
sudo groupadd -f smbadmins
```

**3) SMB 계정 생성** — SMB 전용(권장):
```bash
sudo useradd -M -s /usr/sbin/nologin -G smbadmins smbadmin1
sudo passwd -l smbadmin1          # Unix 비밀번호 잠금(SMB는 별도 DB라 무관)
```
SSH 관리도 겸할 계정이면 셸을 주고 잠그지 않는다: `sudo useradd -M -s /bin/bash -G smbadmins smbadmin1`

**4) Samba 비밀번호 등록** — Samba는 자체 passdb 사용(Unix 비번과 별개):
```bash
sudo smbpasswd -a smbadmin1       # 비밀번호 입력(2회)
sudo smbpasswd -e smbadmin1       # 활성화
sudo pdbedit -L                   # 등록 확인
```

**5) smb.conf에 공유 추가** — `10.0.20.0/24`(LAN)·`10.8.0.0/24`(VPN)를 실제 대역으로 교체:
```bash
sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak
sudo tee -a /etc/samba/smb.conf >/dev/null <<'EOF'

[srv]
   comment = SFTP uploads (all organizations)
   path = /srv
   browseable = yes
   read only = no
   valid users = @smbadmins
   admin users = @smbadmins
   create mask = 0640
   directory mask = 0750
   hosts allow = 10.0.20.0/24 10.8.0.0/24 127.0.0.1
   hosts deny = 0.0.0.0/0
   smb encrypt = required
EOF
```
- `admin users = @smbadmins` — 공유 안에서 root 권한 → `700`/`600` 파일도 전부 접근(기존 SFTP 권한 변경 불필요).
- `hosts allow`/`deny` — LAN+VPN+로컬만 허용. `smb encrypt = required` — SMB3 암호화 강제.

**6) 설정 검증**
```bash
sudo testparm                     # "Loaded services file OK" + [srv] 확인
```

**7) 서비스 활성화** — `nmbd`(NetBIOS)는 445 직결엔 불필요:
```bash
sudo systemctl enable --now smbd
sudo systemctl disable --now nmbd
sudo systemctl restart smbd
sudo systemctl status smbd --no-pager
```

**8) 방화벽 — 445를 LAN+VPN만 허용**
```bash
sudo ufw allow from 10.0.20.0/24 to any port 445 proto tcp comment 'smb-lan'
sudo ufw allow from 10.8.0.0/24  to any port 445 proto tcp comment 'smb-vpn'
sudo ufw status numbered
```

**9) 접속 검증**
```bash
sudo smbstatus                    # 서버 측 세션/공유
# 클라이언트:  \\<서버IP>\srv   또는   smbclient //<서버IP>/srv -U smbadmin1
```

**관리자 추가/삭제(나중에)**
```bash
# 추가
sudo useradd -M -s /usr/sbin/nologin -G smbadmins smbadmin2
sudo smbpasswd -a smbadmin2 && sudo smbpasswd -e smbadmin2
# 삭제(그룹에서 제외 → 접근 차단)
sudo gpasswd -d smbadmin2 smbadmins
sudo smbpasswd -x smbadmin2        # SMB 계정 제거(선택)
```

### 12-3s. 설치 스크립트 `setup-smb.sh` (위 과정을 한 번에)

```bash
#!/usr/bin/env bash
# setup-smb.sh
# Expose the SFTP data root (/srv) over SMB to one or MORE dedicated local accounts.
#   - Creates a management group (SMB_GROUP) and adds each account to it
#   - Adds a Samba share [srv] with "admin users = @SMB_GROUP" so those accounts
#     get full access to every organization's files WITHOUT changing the 700/600
#     permissions the SFTP chroot relies on (SFTP isolation stays intact).
#   - Restricts the share to internal LAN + VPN networks only.
#
# Add more admins later: just re-run with the extra names in SMB_USERS,
# or manually:  sudo useradd -M -s /usr/sbin/nologin bob
#               sudo usermod -aG smbadmins bob
#               sudo smbpasswd -a bob && sudo smbpasswd -e bob
#
# Usage: sudo ./setup-smb.sh
set -euo pipefail

########################### Configuration (edit here) ###########################
SMB_GROUP=smbadmins                 # management group granted access to the share
SMB_USERS="smbadmin1 smbadmin2"     # one or more local accounts (space-separated)
SMB_SHELL=/usr/sbin/nologin         # login shell: /usr/sbin/nologin = SMB-only (recommended)
                                    #              /bin/bash        = also allow SSH/shell login
SHARE_NAME=srv                      # SMB share name -> \\server\srv
SHARE_PATH=/srv                     # directory to expose (SFTP data root)
WORKGROUP=WORKGROUP
# Networks allowed to reach the share (space-separated CIDRs): internal LAN + VPN
ALLOW_NETS="10.0.20.0/24 10.8.0.0/24"
SMB_CONF=/etc/samba/smb.conf
GEN_SMB_PASSWORD="${GEN_SMB_PASSWORD:-true}"   # auto-generate each account's SMB password
CRED_FILE="${CRED_FILE:-./smb-credentials.csv}"
#################################################################################

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

echo "==> Installing Samba"
DEBIAN_FRONTEND=noninteractive apt-get install -y samba >/dev/null

echo "==> Management group: $SMB_GROUP"
getent group "$SMB_GROUP" >/dev/null || groupadd "$SMB_GROUP"

# credentials file: create header only if missing; never truncate an existing one
if [[ "$GEN_SMB_PASSWORD" == true && ! -f "$CRED_FILE" ]]; then
    umask 077; echo "smb_user,smb_password" > "$CRED_FILE"; chmod 600 "$CRED_FILE"
fi

echo "==> Creating SMB accounts"
for u in $SMB_USERS; do
    if ! id "$u" &>/dev/null; then
        useradd -M -s "$SMB_SHELL" -G "$SMB_GROUP" "$u"
        echo "    + created $u (shell $SMB_SHELL, group $SMB_GROUP)"
    else
        usermod -aG "$SMB_GROUP" -s "$SMB_SHELL" "$u"
        echo "    ~ exists $u -> added to $SMB_GROUP (shell $SMB_SHELL)"
    fi
    # Lock the Unix password only for SMB-only accounts (nologin/false).
    # With a real shell, leave it so the admin can set a password or SSH key.
    case "$SMB_SHELL" in
        */nologin|*/false) passwd -l "$u" >/dev/null 2>&1 || true ;;
    esac

    # set the Samba password
    if [[ "$GEN_SMB_PASSWORD" == true ]]; then
        if pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$u"; then
            echo "      (SMB password already set - kept)"
        else
            pw="$(openssl rand -base64 15)"
            printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$u"
            smbpasswd -e "$u" >/dev/null
            printf '%s,%s\n' "$u" "$pw" >> "$CRED_FILE"
            echo "      SMB password generated -> $CRED_FILE"
        fi
    else
        echo "      run:  sudo smbpasswd -a $u && sudo smbpasswd -e $u"
    fi
done

echo "==> Writing the [$SHARE_NAME] share into $SMB_CONF"
HOSTS_ALLOW="$ALLOW_NETS 127.0.0.1"
# Remove any previous managed block, then append a fresh one (idempotent).
if [[ -f "$SMB_CONF" ]]; then
    cp -a "$SMB_CONF" "${SMB_CONF}.bak.$(id -u)"
    sed -i '/# >>> setup-smb managed >>>/,/# <<< setup-smb managed <<</d' "$SMB_CONF"
fi
cat >> "$SMB_CONF" <<EOF
# >>> setup-smb managed >>>
[$SHARE_NAME]
   comment = SFTP uploads (all organizations)
   path = $SHARE_PATH
   browseable = yes
   read only = no
   valid users = @$SMB_GROUP
   admin users = @$SMB_GROUP
   create mask = 0640
   directory mask = 0750
   hosts allow = $HOSTS_ALLOW
   hosts deny = 0.0.0.0/0
   smb encrypt = required
# <<< setup-smb managed <<<
EOF

echo "==> Validating configuration"
testparm -s "$SMB_CONF" >/dev/null

echo "==> Enabling services (smbd only; nmbd/NetBIOS not needed for direct 445 access)"
systemctl enable --now smbd
systemctl disable --now nmbd 2>/dev/null || true
systemctl restart smbd

echo "==> Firewall: allow SMB (445/tcp) from LAN + VPN only"
if command -v ufw >/dev/null; then
    for net in $ALLOW_NETS; do
        ufw allow from "$net" to any port 445 proto tcp comment 'smb' || true
    done
fi

echo "Done."
echo "Connect:  \\\\<server-ip>\\$SHARE_NAME   (users: $SMB_USERS)"
```

### 12-4. 실행 · 검증

```bash
# ALLOW_NETS 를 실제 LAN + VPN 대역으로 수정한 뒤:
chmod +x setup-smb.sh
sudo ./setup-smb.sh

# 상태 확인
systemctl status smbd --no-pager
sudo smbstatus            # 접속 세션/공유 확인

# 클라이언트
#   Windows 탐색기 주소창:   \\<서버IP>\srv
#   Linux/macOS:            smbclient //<서버IP>/srv -U smbadmin1
```

### 12-4b. 관리자 계정 추가 / 삭제 (다중 계정 운영)

공유는 그룹(`@smbadmins`)으로 접근을 통제하므로 **smb.conf 를 다시 건드릴 필요가 없다.**
계정을 그룹에 넣고 빼기만 하면 된다.

```bash
# 추가
sudo useradd -M -s /usr/sbin/nologin -G smbadmins newadmin
sudo smbpasswd -a newadmin && sudo smbpasswd -e newadmin

# 삭제(그룹에서만 제외 → 접근 차단, 계정 유지)
sudo gpasswd -d olduser smbadmins
sudo smbpasswd -x olduser          # SMB 계정 자체 제거(선택)
```

> 스크립트의 `SMB_USERS` 에 이름을 여러 개 나열해 한 번에 만들 수도 있다(재실행 시 기존 계정은
> 그룹만 확인하고 SMB 비밀번호는 유지).

### 12-4c. 개인 홈 공유 `[homes]` 추가 — 각 Samba 사용자가 자기 홈만 (기존 `[srv]` 유지)

`[srv]`(관리자 전체 접근)는 그대로 두고, **새 Samba 사용자가 각자 `/home/<username>` 을 읽고 쓰는**
개인 공유를 추가한다. 클라이언트가 `\\<서버IP>` 만 쳐도 접근 권한 있는 공유가 자동으로 나열되며,
각 사용자는 **자기 이름의 홈 공유**를 본다(검증됨).

**smb.conf 에 `[homes]` 블록 추가** (`[srv]` 는 건드리지 않는다):

```bash
sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak.homes
sudo tee -a /etc/samba/smb.conf >/dev/null <<'EOF'

[homes]
   comment = Home Directories
   browseable = no
   read only = no
   valid users = %S
   create mask = 0600
   directory mask = 0700
EOF
sudo testparm >/dev/null && sudo systemctl restart smbd
```

- `[homes]` — 접속 사용자의 passwd 홈(`/home/<username>`)을 그 사용자 이름의 공유로 자동 제공.
- `valid users = %S` — 본인만 접근(다른 사용자 차단). `browseable = no` 여도 **본인 것은 자기
  이름으로 목록에 표시**된다.

**홈을 가진 Samba 사용자 생성** (`[homes]` 는 홈이 실제로 있어야 하므로 `-m` 사용):

```bash
sudo useradd -m -d /home/newuser -s /usr/sbin/nologin newuser
sudo chmod 700 /home/newuser
sudo smbpasswd -a newuser && sudo smbpasswd -e newuser
```

- 이 사용자는 `smbadmins` 에 없으므로 `/srv` 는 못 보고 **자기 홈만** 본다.
  홈 + `/srv` 둘 다 필요하면 `-G smbadmins` 를 추가한다. SSH 관리도 겸하면 셸을 `/bin/bash` 로.
- 접속: `\\<서버IP>` → `newuser` 공유가 보이고, `\\<서버IP>\newuser` 에서 읽기/쓰기.

> 공유 요약: `[srv]` = `@smbadmins` 그룹만(전체 데이터 관리) · `[homes]` = 각 사용자 자기 홈만.
> SFTP 사용자는 Samba 에 등록하지 않는 한 SMB 와 무관하다.

### 12-5. 주의점

- **네트워크 노출은 LAN+VPN만.** `ALLOW_NETS` 에 사내 LAN 대역과 VPN 대역을 모두 넣는다.
  방화벽은 445/tcp 를 그 대역만 허용하고, 인터넷에는 절대 열지 않는다.
- **SFTP 격리는 그대로 유지된다** — 이 구성은 파일 권한을 바꾸지 않는다. 조직 사용자끼리는 여전히
  서로의 폴더에 접근 불가하고, `@smbadmins` 그룹 계정만 SMB로 전체를 본다.
- **다중 계정**: `admin users = @smbadmins` 로 그룹의 여러 계정이 동시에 관리 접근할 수 있다.
  각 계정은 별도 Samba 비밀번호를 갖고, `smbstatus` 로 누가 접속 중인지 구분된다.
- **소유권**: `@smbadmins` 계정이 SMB로 새로 만든 파일은 `admin users` 특성상 소유자가 `root` 로
  기록될 수 있다(SFTP 사용자가 그 파일을 받을 필요는 없으므로 문제 없음).
- **SMB1 은 쓰지 않는다**(최신 Samba 기본값이 SMB2 이상). `smb encrypt = required` 로 SMB3
  암호화를 강제하므로 클라이언트는 Windows 8/Server 2012 이상이어야 한다.
