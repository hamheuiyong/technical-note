새 SFTP 사용자 하나를 지금 서버 구성(chroot `/srv/<id>`, `upload` 폴더가 `srvread` 그룹·setgid 2750, 파일 640, 셸 없음)에 맞춰 만드는 방법입니다.

먼저 기존 사용자 한 명을 보고 관례(특히 홈 경로)를 맞추는 게 안전합니다:

```bash
getent passwd bcscarfw01          # 홈 필드(:...:) 확인 → 새 사용자도 동일하게
ls -ld /srv/bcscarfw01 /srv/bcscarfw01/upload
```

## 수동 생성 (명령어)

값을 채우고 실행하세요:

```bash
USER=newfw01                       # 소문자 ID
SERIAL=FGTxxxxTKxxxxxxxx            # 장비 시리얼
NAME="Organization Name"           # 조직명(공백은 _로)
SRC_IP=203.0.113.10                # 이 장비가 접속할 공인 IP

# 1) 계정 생성: 셸 없음, chroot 홈, sftpusers 그룹, 주석에 시리얼/이름
sudo useradd -M -s /usr/sbin/nologin -G sftpusers \
     -d /srv/$USER \
     -c "serial=$SERIAL name=${NAME// /_}" "$USER"

# 2) chroot 격리 루트: root:root 755
sudo mkdir -p /srv/$USER
sudo chown root:root /srv/$USER
sudo chmod 755 /srv/$USER

# 3) 업로드 폴더: 소유 <user>:srvread, setgid 2750 (새 파일이 srvread 그룹 상속)
sudo mkdir -p /srv/$USER/upload
sudo chown $USER:srvread /srv/$USER/upload
sudo chmod 2750 /srv/$USER/upload

# 4) 비밀번호 설정
sudo passwd "$USER"                # 대화형 (또는 키 인증 사용)

# 5) 방화벽: 이 장비 IP만 58822 허용
sudo ufw allow from $SRC_IP to any port 58822 proto tcp comment "$NAME"
```

## 확인

```bash
getent passwd "$USER"              # 주석(serial/name)·홈 확인
ls -ld /srv/$USER /srv/$USER/upload   # 755 root:root  /  drwxr-s--- user:srvread
sudo ufw status | grep "$NAME"
# 접속 테스트(허용 IP에서): sftp -P 58822 newfw01@10.0.20.128
```

업로드 파일은 ForceCommand의 `-u 0027` 덕분에 자동으로 `640`(그룹 `srvread`)으로 생성돼, SMB 읽기 그룹에서도 보입니다.

---

참고로 두 가지:

- **홈 경로**: 위에서 `-d /srv/$USER`로 두면 로그인 시 읽기전용 루트에 떨어져 `cd upload` 후 작업합니다. 장비가 홈 디렉터리에 바로 업로드하도록 하려면 기존 사용자들이 `-d /upload`(쓰기폴더 착지)를 쓰는지 `getent passwd`로 확인하고 똑같이 맞추세요.
- **스크립트가 서버에 있다면** 더 간단합니다 — `users.txt`에 `newfw01, FGTxxxx, Organization Name` 한 줄 추가하고 `sudo ./create-sftp-users.sh users.txt` 실행하면 위 과정을 자동으로 하고 비밀번호도 발급합니다(기존 사용자는 그대로 유지).

어느 쪽으로 진행할지, 또는 실제 기존 사용자의 홈 경로(`getent passwd bcscarfw01` 결과)를 알려주시면 거기에 딱 맞춰 명령을 확정해 드리겠습니다.
