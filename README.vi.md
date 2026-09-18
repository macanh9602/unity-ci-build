[🇺🇸 English](./README.md) · [🇻🇳 Tiếng Việt](./README.vi.md)

# Unity CI Build

> Build Unity chạy nền để bạn tiếp tục làm việc trong Editor.

Windows · Unity 6 · Android · PowerShell 5.1+

## Vấn đề

Một build Unity Android có thể khóa Editor trong 20–40 phút. Workspace riêng với `Library/` riêng sẽ tách biệt việc làm game và việc build.

## Ý tưởng

Gửi yêu cầu build và build một Git commit cụ thể trong workspace độc lập:

```text
Project dev → queue → build workspace → Unity batchmode → APK/AAB
```

## Ba mode va ownership

```text
                HTTPS / SSH
DEV  ------------------------------> Git Remote
                                       |
                                       | clone/fetch SHA
                                       v
                                   BUILD MACHINE
                                       ^
                                       |
               SMB TCP 445           |
DEV  ---------------------------------+
      queue / cancel / status
      logs / results / artifact
```

Default: DEV va BUILD cung trusted LAN.
VPN la advanced/manual: user phai tu cau hinh VPN route va firewall subnet.
Khong expose SMB TCP 445 truc tiep ra public Internet.
Git la source-code transport; khong copy project qua SMB. Keystore, password,
Discord secret va `UnityCISecure` chi nam local tren BUILD.

## Giải pháp

- Build từ Unity, batch file hoặc PowerShell.
- Build theo commit mà không đổi checkout của máy dev.
- Dùng Git worktree local hoặc build agent từ xa.
- Reuse Unity `Library` và invalidate bằng fingerprint.
- Theo dõi queue, cancel, log, Discord progress và artifact.
- Tự phục hồi worktree stale và hỗ trợ nhiều project.

## Bắt đầu nhanh

```powershell
.\install.bat
.\build.bat
```

Neu dung may rieng, chon `BUILD AGENT` trong `install.bat` tren build machine,
sau do chon `DEV CLIENT` trong `install.bat` tren may dev. Pairing da nam trong
client setup, khong can chay them `ci.ps1 pair`.


## Cài đặt

Standalone kiem tra PowerShell, Git, Unity Hub, Editor, Android Build Support,
Android SDK/NDK, OpenJDK va dung luong disk. DEV CLIENT chi kiem tra Git project
local va `ProjectVersion.txt`; Android module va Unity executable local khong phai
build requirement.

Agent bootstrap chuẩn bị CI root, SMB share, firewall, Scheduled Task, heartbeat, Unity CLI và Android module. Đăng nhập trước lần provisioning đầu tiên:

```text
unity auth status
unity auth login
```

## Dùng hằng ngày

```powershell
.\ci.ps1 build
.\ci.ps1 build -Branch release/1.2
.\ci.ps1 build -Project SE-001
.\ci.ps1 build -Format aab -Config release
.\ci.ps1 status
.\ci.ps1 queue
.\ci.ps1 cancel
.\ci.ps1 doctor
```

Trong Unity, dùng `CI Build > Dashboard` hoặc `Ctrl+Alt+B`.

## Cách hoạt động

Client ghi job vào `queue/` bằng temporary file rồi atomic rename. Runner nhận job vào `processing/<agent>/`, checkout commit, chạy Unity batchmode và ghi result vào `results/`.

## Build local và Build agent

| Chế độ | Khi dùng | Workspace |
|---|---|---|
| Local | Một máy dev | Local worktree |
| Build agent | Máy riêng hoặc máy thứ hai | Worktree hoặc clone trên agent |

Build remote dùng SMB cho queue, cancel, result, log và quyền đọc artifact. Remote agent chỉ thấy commit đã push.

Client khong duoc build local. Neu agent offline, job van nam trong queue;
`ci.ps1 build -Local` se fail ro rang cho den khi doi may sang `standalone`.

Tren build machine, SMB chi mo tren profile Private/Domain va TCP 445 tu
`LocalSubnet`. Profile Public se block agent setup. NTFS ACL giu rieng
`worktree/` va `UnityCISecure`, chi expose cac path queue/status/log/artifact can thiet.

## Git Commit và Branch

Mỗi job lưu branch và commit SHA. Client đọc branch được chọn mà không checkout nên thay đổi local không bị đụng tới. Hãy push commit trước remote build; tên artifact có branch và short commit.

Build agent xem metadata trong queue là input không đáng tin. Remote phải có dạng HTTPS/SSH hợp lệ và remote đã cấu hình của project không được thay bằng giá trị khác từ queue. Chỉ trỏ agent tới repository mà team tin cậy.

## Worktree và Library Cache

### Private Git repository

BUILD authenticate Git bằng chính Windows user chạy `UnityCIBuildAgent` (ưu tiên
Git Credential Manager cho HTTPS hoặc SSH key đã cấu hình). Credential không được
đưa vào `config.json`, queue hoặc SMB share. Agent doctor dùng `git ls-remote` và
báo `GIT_AUTH_REQUIRED` nếu BUILD chưa được authenticate.

Runner tính fingerprint từ Unity Editor version thực tế, `ProjectSettings/ProjectVersion.txt`, `Packages/manifest.json` và `Packages/packages-lock.json`.

Fingerprint giống nhau thì giữ toàn bộ state của `Library`, `Temp` và `obj`. Fingerprint đổi hoặc chưa biết thì xóa các thư mục này trước khi Unity chạy. `Library/PackageCache` không bị xóa riêng ở mỗi build.

## Worktree tự phục hồi

Setup và runner kiểm tra Git checkout rồi recovery theo thứ tự:

```text
REUSE → REPAIR → RECREATE → FAIL kèm Git error
```

Cleanup chỉ được thực hiện trong các path do CI sở hữu.

## Progress và Discord

Runner update một Discord card với project, branch, commit, stage, thời gian chạy, ETA và kết quả. Stage được suy ra từ Unity log như import, compile, IL2CPP, Gradle và packaging.

## Gửi Artifact

Artifact có thể để trên build machine, copy vào folder đồng bộ hoặc upload bằng `rclone`:

```powershell
.\ci.ps1 drive
```

Upload fail được báo riêng và local artifact path vẫn được giữ lại.

## Release, Keystore và Secrets

Release build cần keystore, alias và password. Credential được kiểm tra trước build và import trên build machine:

```powershell
.\ci.ps1 import-secrets <bundle.json>
```

Secrets dùng Windows DPAPI. Keystore nằm ngoài SMB share trong `UnityCISecure`; password không bao giờ vào queue job.

## Các Rule quan trọng

### Build profile, performance và measurement

`config=dev` chỉ quyết định signing/profile, không tự bật Unity `Development Build`.
Flow quick/test mặc định là `dev` với `developmentBuild=false`; dùng `-Development` nếu
cần opt-in Unity Development Build. Release luôn non-development. Tên artifact chứa profile,
ví dụ `job-branch-sha-dev.apk` hoặc `job-branch-sha-dev-development.apk`.

Config có `buildPerformanceMode`: `editor-friendly`, `balanced` hoặc `max-speed`. Config cũ
được migrate an toàn; standalone mặc định `balanced`, agent mặc định `max-speed`. Runner ghi
policy và timing theo phase (Git sync, cache, Unity); cache là `hit`, `miss` hoặc `initialize`
kèm reason. So sánh size chỉ mang tính thông tin và chỉ so với cùng project, format, signing
config và trạng thái Development Build.

Đây là trusted LAN/VPN transport, không phải Internet-facing service.

1. Build từ một commit cụ thể.
2. Không đổi checkout của dev để build branch khác.
3. Mỗi machine chỉ chạy một Unity build nặng.
4. Chỉ reuse `Library` khi fingerprint hợp lệ.
5. Không patch generated file trong `Library/PackageCache`.
6. Không commit hoặc đưa secret vào queue.
7. Agent chỉ là build worker, không phải remote shell.
8. Thiếu release credential phải fail sớm.

## Xử lý lỗi

### Lỗi PixelPerfectCamera hoặc PackageCache

Để fingerprint policy regenerate toàn bộ cache. Không patch `Library/PackageCache`. Nếu lỗi còn lại, kiểm tra compatibility giữa package và Unity.

### Thiếu Android SDK

Cài Android Build Support, Android SDK & NDK Tools và OpenJDK. Chạy `.\ci.ps1 doctor`.

### Lỗi worktree hoặc .git

```powershell
.\ci.ps1 repair
```

Xem `runner.log` và Git error được in ra.

### Build agent không chạy

```powershell
.\ci.ps1 status
.\ci.ps1 agent-doctor
```

### Build fail nhưng không rõ nguyên nhân

Xem `logs/<job-id>.errors.txt` và Unity log đầy đủ trong `logs/<job-id>.log`.

### Upload Drive fail

Chạy `.\ci.ps1 drive`; artifact vẫn nằm trên build machine.

### Remote build không thấy commit

Push branch và commit lên Git remote đã cấu hình.

## Cấu trúc Project

```text
Build_CICD/
├── install.bat
├── setup.ps1
├── setup-agent.ps1
├── ci.ps1
├── runner.ps1
├── lib/                  các PowerShell module dùng chung
└── unity/                script Unity Editor

UnityCI/
├── queue/                job đang chờ
├── cancel/               cờ hủy
├── processing/<agent>/   job agent đã nhận
├── worktree/<project>/   checkout để build
├── builds/<project>/     output APK/AAB
├── results/              result JSON
├── logs/                 Unity log và error log
└── agents/               heartbeat
```

## Nhiều Project

Một CI root và queue có thể phục vụ nhiều project. Mỗi project có Git remote, Unity version, worktree, output và release config riêng. Mỗi machine chỉ chạy một Unity job nặng.

## Trạng thái Feature

Feature stable gồm Android APK/AAB, local workspace, Git worktree, branch build, cancel, Discord result, artifact publishing, heartbeat, cache fingerprint và worktree recovery.

## Experimental

## Network transport support matrix

```text
Same LAN       = SUPPORTED mac dinh
Trusted VPN    = ADVANCED; tu cau hinh route va firewall subnet
Public Internet SMB = NOT SUPPORTED
```

Installer khong tu detect/whitelist VPN adapter. TCP 445 van gioi han o
`LocalSubnet`, profile Public bi block, va khong bao gio dung `RemoteAddress=Any`.

Build-agent bootstrap, pairing dev với agent, tự động provision Unity CLI, Android module provisioning và agent doctor mở rộng nên được kiểm tra trên máy phụ trước release.

## Sắp tới

- zero-touch build-agent provisioning;
- hoàn thiện on-demand Unity Editor provisioning;
- agent trust và pairing an toàn hơn;
- Firebase App Distribution;
- Discord `/build` command và multi-agent routing;
- build agent macOS và iOS.

## Triết lý

Project này cố ý nhỏ hơn Jenkins hoặc hosted CI platform. Mục tiêu là team Unity mobile nhỏ có thể bấm Build rồi tiếp tục làm việc ngay.

## Star và Issues

Nếu Unity CI Build giúp tiết kiệm thời gian, hãy star repository. Khi báo bug, mở Issue và đính kèm `runner.log`, `logs/<job-id>.errors.txt`, Unity version, Windows version và thông tin build local hay remote.
