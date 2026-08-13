Windows가 **왜 재부팅되었는지** 확인하는 가장 좋은 방법은 **이벤트 로그(Event Viewer)**를 확인하는 것입니다. 명령줄에서도 쉽게 조회할 수 있습니다.

## 1. 최근 재부팅 원인 확인 (가장 유용)

PowerShell:

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ID=1074} |
Select-Object TimeCreated, ProviderName, Message -First 10
```

**Event ID 1074**는 정상적인 재부팅 또는 종료를 의미합니다.

예시:

```text
TimeCreated : 2026-07-16 09:35
ProviderName : USER32

The process C:\Windows\System32\svchost.exe has initiated the restart...
Reason Code: Operating System: Service pack (Planned)
```

여기서 다음과 같은 정보를 확인할 수 있습니다.

* 누가 재부팅했는지
* 어떤 프로세스가 재부팅을 요청했는지
* Windows Update 때문인지
* 사용자가 직접 재부팅했는지

---

## 2. 예기치 않은 재부팅(전원 장애, 강제 종료)

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ID=6008} |
Select-Object TimeCreated, Message -First 10
```

**Event ID 6008**

```
The previous system shutdown was unexpected.
```

다음과 같은 경우에 기록됩니다.

* 전원 장애
* 강제 Reset
* BSOD
* 전원 버튼 길게 누름

---

## 3. Kernel-Power 오류 확인

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ID=41} |
Select-Object TimeCreated, Message -First 10
```

**Event ID 41**

대표적인 원인

* 정전
* PSU 문제
* 강제 리셋
* BSOD
* 시스템 다운

---

## 4. Windows Update 때문에 재부팅되었는지

```powershell
Get-WinEvent -LogName System |
Where-Object {$_.ProviderName -eq "WindowsUpdateClient"} |
Select-Object TimeCreated, Id, Message -First 20
```

---

## 5. 마지막 부팅 시간 확인

```powershell
systeminfo | findstr /C:"System Boot Time"
```

또는

```powershell
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
```

---

## 6. 최근 재부팅 관련 이벤트 한 번에 보기 (추천)

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ID=@(41,1074,6005,6006,6008)} |
Sort-Object TimeCreated -Descending |
Select-Object TimeCreated, Id, ProviderName, LevelDisplayName -First 30
```

각 이벤트의 의미는 다음과 같습니다.

| Event ID | 의미                   |
| -------- | -------------------- |
| 41       | 비정상 종료(Kernel-Power) |
| 1074     | 정상 재부팅/종료 요청         |
| 6005     | 이벤트 로그 서비스 시작(부팅)    |
| 6006     | 이벤트 로그 서비스 종료(정상 종료) |
| 6008     | 비정상 종료               |

### 원인을 가장 정확히 알고 싶다면

다음 명령을 실행한 결과를 보내주세요.

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ID=@(41,1074,6008)} |
Sort-Object TimeCreated -Descending |
Select-Object TimeCreated, Id, ProviderName, Message -First 10
```

출력 내용을 보고 **Windows Update**, **사용자 재부팅**, **전원 장애**, **BSOD**, **하드웨어 문제** 중 어떤 이유였는지 함께 분석해 드리겠습니다.
