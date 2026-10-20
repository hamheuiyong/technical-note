SMB 계정은 **어느 그룹에 넣느냐로 권한이 결정**됩니다 — `smbadmins`=모든 권한(읽기/쓰기), `srvread`=읽기 전용. 공유 `[srv]`의 `valid users = @smbadmins @srvread`에 두 그룹이 이미 포함돼 있으니, **smb.conf나 방화벽은 건드릴 필요 없이 계정만 만들어 그룹에 넣으면** 됩니다.

## 모든 권한 (읽기/쓰기) 계정

```bash
RWUSER=smbrw2                      # 계정명
sudo useradd -M -s /usr/sbin/nologin -G smbadmins "$RWUSER"
sudo smbpasswd -a "$RWUSER"        # 비밀번호 입력(2회)
sudo smbpasswd -e "$RWUSER"        # 활성화
```

`smbadmins`는 공유 안에서 root 권한(`admin users`)으로 동작 → `/srv` 전체 읽기/쓰기/삭제.

## 읽기 전용 계정

```bash
ROUSER=smbro2                      # 계정명
sudo useradd -M -s /usr/sbin/nologin -G srvread "$ROUSER"
sudo smbpasswd -a "$ROUSER"        # 비밀번호 입력(2회)
sudo smbpasswd -e "$ROUSER"        # 활성화
```

`srvread`는 `read list`로 강제 읽기 전용 → `/srv` 전체를 **볼 수만** 있고 수정·삭제 불가. (업로드 파일이 640·그룹 srvread라 읽힘)

## 확인

```bash
id smbrw2; id smbro2               # 그룹 소속 확인
sudo pdbedit -L                    # 등록된 Samba 계정 목록
```

---

참고:

- `-M -s /usr/sbin/nologin` → 홈 없음·셸 없음(SMB 전용, 서버 로그인 불가). Samba는 자체 비밀번호 DB를 쓰므로 셸과 무관하게 동작합니다.
- 그룹 변경은 **새 SMB 세션부터** 적용됩니다(클라이언트에서 재접속).
- **기존 계정의 권한을 바꾸려면** 그룹만 옮기면 됩니다: 읽기전용→쓰기 `sudo usermod -aG smbadmins <user>`, 쓰기→읽기전용은 smbadmins에서 빼고 srvread로 (`sudo gpasswd -d <user> smbadmins; sudo usermod -aG srvread <user>`).
- 접속: `\\10.0.20.128\srv` (쓰기 계정은 수정 가능, 읽기 계정은 보기만).

## smb 사용자를 만들기 위해서 사용자를 미리 /etc/passwd에 만들지 않아도 되나?

- 좋은 질문입니다. 지금 구성(standalone + 기본 `tdbsam` passdb)에서는 **Unix 계정(/etc/passwd)이 먼저 있어야 합니다.** 실제로 확인해 드리겠습니다.

확인했습니다 — **미리 만들어야 합니다.** 테스트 결과가 명확합니다:

- Unix 계정 없이 `smbpasswd -a nouser_test` → **`Failed to add entry for user nouser_test.`** (실패)
- `useradd`로 먼저 만든 뒤 → **`Added user nouser_test.`** (성공)

## 왜 필요한가

지금 구성(standalone + 기본 `tdbsam` passdb)에서 Samba는 비밀번호를 **자체 DB**에 저장하지만, 각 SMB 계정은 **파일 소유·권한을 위해 Unix UID에 매핑**되어야 합니다. `/etc/passwd`에 계정이 없으면 매핑할 UID가 없어서 `smbpasswd -a`가 거부됩니다. 그래서 항상 `useradd` → `smbpasswd -a` 순서입니다.

다만 그 Unix 계정은 **최소한으로** 만들면 됩니다(로그인 불가, 홈 없음):

```bash
sudo useradd -M -s /usr/sbin/nologin -G smbadmins smbuser1   # 홈X·셸X
sudo passwd -l smbuser1                                       # Unix 비밀번호 잠금(선택)
sudo smbpasswd -a smbuser1 && sudo smbpasswd -e smbuser1      # SMB 비밀번호만 활성
```

즉 "존재만 하고 서버 로그인은 못 하는" 껍데기 계정이면 충분합니다. SMB 인증·비밀번호는 전적으로 Samba DB가 담당하고, Unix 쪽은 UID 매핑 용도로만 쓰입니다.

## 미리 안 만들어도 되는 경우 (참고)

per-user `/etc/passwd` 항목을 아예 없애려면 백엔드를 바꿔야 합니다 — Samba를 **Active Directory 멤버**로 조인하거나 **LDAP passdb**를 쓰면 사용자가 디렉터리에서 오고 로컬 계정이 불필요합니다. 하지만 이건 인프라를 크게 바꾸는 일이라, 지금 같은 소규모 standalone 서버에서는 **Unix 계정을 미리 만드는 방식이 표준이고 가장 간단**합니다.
