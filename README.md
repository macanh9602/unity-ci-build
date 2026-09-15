# Unity CI Build

Build game Unity **chạy nền**, để Unity Editor của bạn vẫn dùng được bình thường trong lúc đó.

---

## Cài đặt

1. Copy cả thư mục này về máy
2. Double-click **`install.bat`**
3. Trả lời vài câu hỏi

Hết.

### Bạn cần chuẩn bị

| Cần gì | Bắt buộc | Ghi chú |
|---|---|---|
| Thư mục project Unity (đã là git repo) | ✅ | Build lấy code từ commit |
| Một ổ đĩa còn trống ~60 GB | ✅ | Chứa bản sao thứ hai của project |
| Unity Hub + Unity Editor + Android Build Support | ✅ | Trình cài đặt sẽ kiểm tra và chỉ chỗ nếu thiếu |
| Webhook của một kênh Discord | ⬜ | Để nhận thông báo build xong |
| Nơi tester lấy file | ⬜ | Một đường dẫn folder là đủ — xem bên dưới |
| File keystore | ⬜ | Chỉ cần nếu build bản release |

Git nếu thiếu thì trình cài đặt **tự cài giúp**. Phần Unity thì không — Unity bắt buộc phải đăng nhập license bằng tay qua Unity Hub, không tự động được.

### Đưa file cho tester — chọn 1 trong 3

| Cách | Bạn phải nhập gì | Đổi lại |
|---|---|---|
| **Không cần** | — | File chỉ nằm trên máy này |
| **Copy sang folder khác** ⭐ | Một đường dẫn folder | Đơn giản nhất, không đăng nhập gì. Trỏ vào folder của Google Drive Desktop / MEGA / OneDrive / ổ mạng — client tự đồng bộ lên mây |
| **rclone** | Đăng nhập Google một lần qua trình duyệt (~1 phút) | Tự tạo link tải riêng cho từng file |

Cách giữa là mặc định và hợp với hầu hết trường hợp. Wizard tự dò các folder đồng bộ có sẵn trên máy rồi liệt kê cho bạn chọn.

Nếu chọn rclone thì wizard tự chạy `rclone config create gdrive drive scope=drive` — lệnh này lấy giá trị mặc định cho mọi câu hỏi cấu hình, nên cả cuộc phỏng vấn ~10 bước của `rclone config` rút lại còn đúng một bước: bấm Allow trên trình duyệt. (Nó dùng client ID dùng chung của rclone, có thể bị Google throttle khi upload dồn dập — với vài file APK mỗi ngày thì không sao.)

**Không chắc chọn gì thì chọn [1].** Cứ để build chạy được trước đã; lát nữa chạy lại `install.bat` là thêm được, không mất gì.

**Chỉ dán link Drive thôi thì không đủ** — link là địa chỉ, không phải chìa khoá; Google bắt buộc OAuth mới cho ghi file. Nhưng nếu bạn đã share sẵn folder đó và có link, dán vào lúc cài (một lần) thì Discord sẽ kèm link đó vào mọi thông báo. Đó là link tĩnh của cả folder, không phải link riêng từng file.

### Bạn nhận được gì

- Trong Unity có menu **CI Build** — bấm một phát là build chạy nền
- File APK/AAB nằm trong một thư mục cố định, đặt tên theo ngày giờ + commit
- Discord báo thành công hay thất bại
- Build hỏng thì có file `errors.txt` liệt kê đúng dòng lỗi, không phải đi đọc log Unity

---

## Dùng hằng ngày

**Trong Unity** (cách chính):

- `CI Build > Bảng điều khiển` — chọn APK/AAB, dev/release, xem lịch sử
- `CI Build > Build nhanh - APK dev` — hoặc `Ctrl+Alt+B`

**Không mở Unity:**

- Double-click `build.bat`
- Hoặc PowerShell:

```powershell
.\ci.ps1 build                              # APK dev, project mặc định
.\ci.ps1 build -Project SE-001              # project khác
.\ci.ps1 build -Format aab -Config release  # AAB release
.\ci.ps1 projects                           # liệt kê project đã khai báo
.\ci.ps1 status                             # đang build gì, kết quả gần đây
.\ci.ps1 open                               # mở thư mục chứa file build
.\ci.ps1 config                             # xem / đổi đường dẫn
.\ci.ps1 doctor                             # kiểm tra lại máy
```

### Nhiều project

Chạy lại `install.bat` và chọn project khác là nó **thêm vào**, không đè lên cái cũ. Chọn lại project đã có thì là **sửa**. Wizard tự nhận biết bằng đường dẫn.

Cái gì dùng chung, cái gì riêng:

| Dùng chung mọi project | Riêng từng project |
|---|---|
| Ổ đĩa CI, hàng đợi, runner | Đường dẫn project, bản Unity |
| Số core chừa lại, timeout | Worktree, thư mục file build |
| Webhook Discord | Nơi đẩy file cho tester, keystore |

**Một hàng đợi, một runner, một khoá — cho tất cả project.** Đây là chủ ý: hai bản Unity build cùng lúc trên một máy sẽ giành CPU và ổ cứng, cả hai đều chậm hơn là chạy lần lượt. Job xếp hàng theo thứ tự đến, mỗi job mang theo tên project của nó.

Trong Unity thì **không phải chọn gì** — cửa sổ CI Build đối chiếu đường dẫn project đang mở với config và tự dùng đúng project đó. Lịch sử build cũng chỉ hiện của project đang mở.

Đổi project mặc định (khi gõ `ci.ps1 build` không kèm `-Project`): sửa `defaultProject` trong `config.json`.

Keystore lưu riêng từng project trong `secrets.json`, không đụng nhau.

### Đổi nơi file build được đẩy tới

Lúc cài, câu hỏi **"Folder cu the de do file vao"** nhận đường dẫn đầy đủ bất kỳ — lồng bao nhiêu cấp cũng được, chưa tồn tại cũng được (tool tự tạo):

```
G:\My Drive\Team\Builds\WoolLoop\Android
```

Sau khi cài rồi thì **không cần chạy lại `install.bat`** — chạy `.\ci.ps1 config`, nó in ra đường dẫn hiện tại và mở `config.json` cho bạn sửa:

| Trong `config.json` | Là gì |
|---|---|
| `projects[].drive.folderPath` | Nơi copy file tới (chế độ folder) |
| `projects[].drive.folder` | Thư mục trên Drive (chế độ rclone) — nhận `Builds/WoolLoop/Android` |
| `projects[].drive.shareUrl` | Link Discord sẽ kèm theo |
| `projects[].buildsPath` | Nơi chứa bản gốc trên máy này |
| `defaultProject` | Project dùng khi không gõ `-Project` |

Bản gốc luôn nằm ở `buildsPath`; `drive.folderPath` chỉ là **bản copy thêm**. Xoá nhầm bên Drive không mất bản gốc.

### Nếu folder Drive nằm trong "Shared with me"

Folder người khác share cho bạn thì **cả hai cách đều không trỏ thẳng vào được**:

- Google Drive Desktop chỉ đồng bộ `My Drive`, không đồng bộ "Shared with me"
- rclone: docs ghi rõ folder trong "Shared with me" *"do not work well"* với `root_folder_id`

Một thao tác gỡ được cả hai — làm **một lần** trên drive.google.com:

> Chuột phải vào folder → **Organise** (Sắp xếp) → **Add shortcut to Drive** → chọn **My Drive**

Xong rồi thì:

| Chế độ | Nhập gì |
|---|---|
| **Folder** | `G:\My Drive\<tên folder>` — ổ `G:` là ổ Google Drive Desktop mount, mở This PC xem chữ cái thật |
| **rclone** | Dán nguyên link folder vào wizard, nó tự tách `folders/<ID>` ra và ghim vào đúng đó |

Ở chế độ rclone, ID được truyền lúc gọi lệnh (`--drive-root-folder-id`) chứ không nhúng vào remote — nên sau này đổi folder đích chỉ cần sửa `drive.rootFolderId` trong `config.json`, không phải đăng nhập Google lại.

---

## Vài điều nên biết trước

### Theo dõi tiến độ trên Discord

Mỗi build là **một card duy nhất** — nó tự sửa nội dung mỗi ~20 giây rồi kết thúc thành kết quả, không đẻ thêm tin nhắn:

```
Giai doan: IL2CPP (bien ma)
[#######.....]  4m 10s / ~12m (uoc tinh)
```

**Không có phần trăm thật.** Unity không phát ra tiến độ ở batchmode — không API, không dòng log nào báo %. Nên:

- **Giai đoạn** là thật, đọc từ log Unity theo thời gian thực (khởi động → import asset → compile script → compile shader → build player → IL2CPP → gradle). Giai đoạn chỉ tiến, không lùi, nên nó không nhấp nháy khi log các chặng xen kẽ nhau.
- **ETA** là trung vị thời lượng 5 lần build **thành công** gần nhất của đúng project + đúng loại build. Dùng trung vị chứ không phải trung bình, để một lần bất thường không kéo lệch. Vài lần build đầu chưa có số liệu thì nó ghi thẳng "chua co so lieu de uoc tinh" thay vì bịa.
- **Bar** chạy theo `đã chạy / ETA` và luôn ghi "(uoc tinh)". Nó không bao giờ đầy khi chưa xong, kể cả lúc build vượt ETA.

Bảng nhận diện giai đoạn nằm ở đầu `lib/UnityLog.ps1`, tách riêng để dễ chỉnh nếu log Unity của bạn khác.

**Lần build đầu mất 20–40 phút.** Unity phải import lại toàn bộ asset cho bản sao thứ hai. Những lần sau chỉ còn vài phút vì `Library` được giữ lại.

**Build lấy đúng commit HEAD.** Thay đổi chưa commit sẽ KHÔNG có trong bản build — tool sẽ cảnh báo trước khi chạy. Đây là chủ ý: mỗi file build truy ngược được về đúng một commit.

**Máy sẽ hơi ì lúc build.** Build Android ăn hết CPU. Tool đã hạ ưu tiên và chừa lại vài core cho Editor (chỉnh được lúc cài), nhưng không thể làm nó miễn phí. Muốn hết ì hoàn toàn thì phải build trên máy khác.

**`versionCode` = số commit.** Tự tăng theo `git rev-list --count`, không cần file state, không tạo commit rác. Bản release thì tool không đụng vào — bạn tự đặt trong Player Settings.

---

## Bên trong chạy thế nào

```
Unity menu / ci.ps1 / build.bat
        ↓  ghi 1 file job vào queue/
   runner.ps1  (một job một lúc, khóa bằng named mutex)
        ↓
   worktree riêng  ──►  Unity.exe -batchmode  ──►  APK/AAB
        ↓
   Discord  +  Google Drive
```

**Worktree** là bản sao thứ hai của project, `git worktree` tạo ra, dùng chung kho object với repo chính nên không tốn thêm dung lượng git. Nó có `Library` riêng — đó chính là lý do Editor của bạn không bị khóa.

**Queue là drop-folder.** Ghi file `.tmp` rồi đổi tên — thao tác đổi tên là nguyên tử, nên nhiều nguồn cùng đẩy job vào không đụng nhau, và runner không bao giờ đọc phải file đang ghi dở.

**Khóa runner dùng named mutex** chứ không dùng lock file. Windows tự thu hồi mutex khi process chết, nên không bao giờ có lock "mồ côi" phải dọn tay sau khi crash.

**`CIBuild.cs` được bơm vào worktree mỗi lần build**, sau bước `git clean`. Nhờ vậy build được cả những commit cũ chưa hề có script CI, và bạn không cần commit gì trước khi build lần đầu.

---

## Cấu trúc thư mục

```
Build_CICD/
├─ install.bat          ← double-click để cài
├─ build.bat            ← double-click để build nhanh
├─ setup.ps1            trình cài đặt
├─ ci.ps1               dòng lệnh
├─ runner.ps1           bộ phận build thật
├─ config.json          sinh ra sau khi cài (cài đặt chung + danh sách project)
├─ secrets.json         webhook + mật khẩu keystore từng project (mã hoá DPAPI)
├─ lib/                 thư viện dùng chung
└─ unity/               script copy vào project Unity
```

Nơi chứa build (bạn chọn lúc cài, ví dụ `E:\UnityCI`):

```
UnityCI/
├─ worktree/<project>/  bản sao để build (mỗi project một cái)
├─ builds/<project>/    file APK/AAB
├─ queue/               job đang chờ (dùng chung mọi project)
├─ results/             kết quả từng build
├─ logs/                log Unity + errors.txt
└─ runner.log
```

---

## Bảo mật

`secrets.json` chứa webhook Discord và mật khẩu keystore, **mã hoá bằng Windows DPAPI** — chỉ giải mã được bởi đúng tài khoản Windows đó trên đúng máy đó. Copy file sang máy khác là thành vô nghĩa.

Mật khẩu keystore truyền vào Unity qua **biến môi trường**, không bao giờ ghi ra đĩa.

### Đẩy lên GitHub

Được — code trong repo này không chứa secret nào. Nhưng **phải có `.gitignore`** (đã kèm sẵn), vì ba thứ này là riêng của từng máy:

| File | Chứa gì |
|---|---|
| `secrets.json` | Webhook Discord + mật khẩu keystore |
| `config.json` | Đường dẫn máy, tên Windows user, ID folder Drive |
| `queue/ results/ logs/ builds/ worktree/` | Rác lúc chạy, phình to vô hạn |

`config.example.json` là bản mẫu đã bỏ hết thông tin riêng — người khác clone về chỉ cần chạy `install.bat`, nó tự sinh `config.json`.

**Kiểm tra trước khi push lần đầu:**

```powershell
git status --short          # không được thấy config.json / secrets.json
git ls-files | Select-String "secrets|config\.json$"   # phải rỗng
```

Nếu lỡ commit rồi mới nhớ ra thì **đổi webhook Discord và mật khẩu keystore**, đừng chỉ xoá file — git giữ lại toàn bộ lịch sử.

Về `secrets.json`: nội dung mã hoá bằng **Windows DPAPI**, chỉ giải mã được bởi đúng tài khoản Windows đó trên đúng máy đó. Nên kể cả lộ thì người khác cũng không dùng được. Nhưng đó là lớp phòng thủ thứ hai, không phải lý do để commit nó.

---

## Hỏng thì xem ở đâu

| Hiện tượng | Xem |
|---|---|
| Build hỏng | `logs/<id>.errors.txt` — đã tách sẵn lỗi compile vs lỗi đóng gói |
| Không thấy build chạy | `runner.log` |
| Nghi thiếu gì đó trên máy | `.\ci.ps1 doctor` |
| Muốn xem log Unity đầy đủ | `logs/<id>.log` |

**Lỗi thường gặp:** `Unable to locate Android SDK` → mở Unity Hub > Installs > bánh răng của bản Unity đang dùng > Add modules > tích **Android Build Support**, **Android SDK & NDK Tools**, **OpenJDK**.

---

## Chưa làm (để sau)

- Discord bot `/build` — cần một daemon chạy thường trực, khác hẳn webhook
- Build iOS — cần máy Mac
- Firebase App Distribution — hiện dùng folder đồng bộ hoặc rclone
