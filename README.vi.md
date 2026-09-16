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

Nếu dùng máy riêng, chạy `install-agent.bat` trên build machine rồi pair máy dev:

```powershell
.\ci.ps1 pair BUILD-PC-01
```

## Cài đặt

Installer kiểm tra PowerShell, Git, Unity Hub, Editor cần dùng, Android Build Support, Android SDK/NDK, OpenJDK và dung lượng disk.

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

## Git Commit và Branch

Mỗi job lưu branch và commit SHA. Client đọc branch được chọn mà không checkout nên thay đổi local không bị đụng tới. Hãy push commit trước remote build; tên artifact có branch và short commit.

Build agent xem metadata trong queue là input không đáng tin. Remote phải có dạng HTTPS/SSH hợp lệ và remote đã cấu hình của project không được thay bằng giá trị khác từ queue. Chỉ trỏ agent tới repository mà team tin cậy.

## Worktree và Library Cache

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
├── install-agent.bat
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
