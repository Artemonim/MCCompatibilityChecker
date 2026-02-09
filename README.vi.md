# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Tự động chẩn đoán xung đột mod Minecraft. Script tự khởi động trò chơi, bắt lỗi văng game (crash), đọc nhật ký lỗi, tìm mod gây lỗi và cách ly nó — lặp đi lặp lại cho đến khi bản modpack hoạt động ổn định.

> Hoạt động thông qua [Legacy Launcher](https://llaun.ch/) (hậu duệ của TLauncher). Việc khởi chạy game và phát hiện crash được thực hiện qua giao diện người dùng của launcher; phân tích lỗi dựa trên nhật ký chuẩn của Fabric/Forge/Minecraft.

## Tại sao cần công cụ này

Bạn cài 200 mod, khởi động game — và nó bị crash. Bạn mở nhật ký lỗi — một rừng chữ. Bạn thử gỡ mod ngẫu nhiên — lại gặp crash khác. Quen thuộc chứ?

MCCompatibilityChecker thực hiện những gì bạn thường làm bằng tay, nhưng một cách tự động: gỡ mod, chạy game, kiểm tra kết quả và lặp lại. Thay vì thử sai ngẫu nhiên, nó sử dụng thuật toán tìm kiếm nhị phân, phân tích lỗi Mixin và bản đồ phụ thuộc.

Kết quả cuối cùng là danh sách các mod gây lỗi và một bản modpack hoạt động được.

## Trạng thái dự án

Phiên bản hiện tại — đang trong giai đoạn phát triển tích cực (thử nghiệm).

- Hiện tại, việc xử lý các cụm xung đột lớn có thể chưa ổn định.
- Đối với các bộ mod lớn, khuyến nghị nên sao lưu thư mục `mods` trước và sử dụng các báo cáo/nhật ký sau mỗi lần chạy.

## Cách thức hoạt động

Quá trình chẩn đoán trải qua nhiều giai đoạn. Mỗi giai đoạn tiếp theo chỉ được kích hoạt nếu giai đoạn trước đó không giải quyết được vấn đề:

1. **Phân tích cơ bản (Baseline Analysis)** — đọc nhật ký crash, tìm các ứng cử viên trong văn bản lỗi và cách ly chúng theo thứ tự ưu tiên phụ thuộc.
2. **Phân tích Mixin** — phân tích các lỗi `Mixin apply failed` và `@Mixin target not found`, xác định mod nguồn và mod đích, kiểm tra từng mod qua 1-2 lần chạy.
3. **Phân lớp (Layering)** — gỡ bỏ tất cả mod, giữ lại các thư viện cốt lõi (core), sau đó thêm lại các mod theo từng lớp (theo cấp độ phụ thuộc, theo lô lũy thừa). Nếu một lô bị lỗi — sẽ thực hiện phân loại và cách ly trong phạm vi lô đó.
4. **Cách ly (Isolation)** — phương án dự phòng: các cấp độ nhận biết phụ thuộc, thử nghiệm lũy thừa/nhị phân ở các cấp độ đầu và cách ly tuyến tính ở các cấp độ sau.
5. **Khôi phục (Recovery)** — nếu có từ 3 "thủ phạm" trở lên cùng gây ra một lỗi Mixin, script sẽ kiểm tra xem đó có phải là báo động giả hay không và tìm nguyên nhân gốc rễ thực sự.

Mô tả chi tiết thuật toán — xem tại [doc/Algorithm.md](doc/Algorithm.md).

## Yêu cầu hệ thống

- **Windows** (sử dụng Win32 UI Automation)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- Minecraft bản **Fabric** hoặc **Forge**

## Các phụ thuộc phát triển

- **PSScriptAnalyzer** (module PowerShell, cần cho `checker.ps1`)
- **Python 3.x** (cần để kiểm tra đa ngôn ngữ qua `tools/Check-Localization.py`)

Cài đặt `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Bắt đầu nhanh

1. Clone kho lưu trữ hoặc tải xuống tệp lưu trữ từ [phiên bản mới nhất](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest):
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. Sao chép `config.ini` thành `config.local.ini` và chỉ định đường dẫn đến thư mục mod của bạn:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Mở Minecraft Launcher.

4. Gõ `./run.ps1` hoặc `./run.ps1 -verbose` vào bảng điều khiển PowerShell.

5. Di chuột lên nút khởi chạy máy khách trong launcher.

6. Nhấn `Enter` để gửi lệnh bảng điều khiển và để Checker lấy tọa độ nút.

## Cấu hình

Các thiết lập được định nghĩa trong `config.ini` (mặc định) và `config.local.ini` (các tùy chỉnh của bạn, được git bỏ qua).

| Tham số | Mô tả |
|---------|-------|
| `GameModsDir` | Thư mục mod mà trò chơi sử dụng |
| `StorageModsDir` | Nơi lưu trữ mod chính (tùy chọn) |
| `LogPath` | Đường dẫn đến tệp nhật ký của launcher (để trống để tự động tìm) |
| `LauncherExePath` | Đường dẫn đến tệp thực thi của launcher (để trống để kết nối với bản đang chạy) |
| `EnableMixinAnalysis` | Kích hoạt giai đoạn phân tích Mixin (mặc định: `true`) |
| `EnableLayering` | Kích hoạt phân lớp và cách ly loại trừ (mặc định: `true`) |
| `EnableRecovery` | Kích hoạt khôi phục các thủ phạm ảo (mặc định: `false`) |
| `Language` | Ngôn ngữ thông báo trên console (`[Localization].Language`). Nếu trống: tự động theo hệ điều hành, dự phòng là `en` |

Các ngôn ngữ hiện có: `en`, `ru`.
Đã chuẩn bị sẵn khung cho: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
Việc tìm kiếm cửa sổ crash của launcher sẽ tự động thu thập các mẫu từ `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`).
Hiện đã có `Something broke` / `Something went wrong` (en) và `Что-то сломалось...` (ru). Đối với các ngôn ngữ mới, chỉ cần thêm danh sách này vào tệp ngôn ngữ tương ứng.
Nếu tiêu đề cửa sổ launcher của bạn khác, bạn có thể thiết lập rõ ràng `CrashWindowTitlePatterns` trong `[Profile:<tên>]` và chạy với `-Profile <tên>`.

## Các tham số chạy chính

```bash
.\run.ps1 -Help          # Hướng dẫn rút gọn
.\run.ps1 -HelpFull      # Hướng dẫn kỹ thuật đầy đủ
```

| Cờ | Mô tả |
|----|-------|
| `-LauncherExePath <đường dẫn>` | Đường dẫn đến launcher (nếu không được chỉ định trong cấu hình) |
| `-NoLegacy` | Không lưu lại các mod bị cách ly — xóa luôn |
| `-GameLegacy` | Giữ bản sao các mod bị cách ly trong thư mục game |
| `-DryRun` | Chạy thử để xem script sẽ làm gì mà không thực hiện thay đổi thật |
| `-Verbose` | Nhật ký chi tiết (ra console và tệp `MCCC.log`) |
| `-UseLinearIsolation` | Tìm kiếm tuyến tính thay vì nhị phân (chậm hơn nhưng đơn giản hơn) |
| `-NoCache` | Tắt bộ nhớ đệm phiên (kiểm tra lại cả những cấu hình đã thành công trước đó) |
| `-ThoroughStabilityCheck` | Tăng thời gian kiểm tra độ ổn định khi khởi động |
| `-AutoHandleFabricDialog <bool>` | Tự động xử lý các hộp thoại Fabric không thiếu phụ thuộc trong quy trình debug |
| `-IgnoreModIds <id1,id2,...>` | Bỏ qua các mod id chỉ định trong quá trình dọn dẹp tương thích |
| `-Profile <tên>` | Áp dụng cấu hình từ `[Profile:<tên>]` trong `config.ini` / `config.local.ini` |

## Kiểm tra script và ngôn ngữ

`checker.ps1` thực hiện kiểm tra:
- Script PowerShell qua `PSScriptAnalyzer`
- Các tài nguyên ngôn ngữ qua `tools/Check-Localization.py`
- Các chuỗi `Write-Verbose`/debug-only được coi là nội bộ, giữ nguyên tiếng Anh và không tính vào độ phủ ngôn ngữ.

Ví dụ:
```powershell
.\checker.ps1             # Kiểm tra đầy đủ (bao gồm cả ngôn ngữ)
.\checker.ps1 -NoLocales  # Bỏ qua kiểm tra ngôn ngữ
```

Hành vi khi thiếu Python:
- Mặc định sẽ là **lỗi** (checker kết thúc với mã lỗi) để không bỏ sót các lỗi trong hệ thống ngôn ngữ.
- Nếu bạn không làm việc với ngôn ngữ, hãy sử dụng `-NoLocales`.

## Cấu trúc dự án

```
├── run.ps1                  # Điểm nhập (Entry point)
├── config.ini               # Cấu hình mặc định
├── checker.ps1              # Linter + kiểm tra ngôn ngữ
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Điều phối: chạy, giám sát, vòng lặp
│   ├── Check-Mod-Compatibility.ps1      # Phân tích cơ bản
│   ├── Analyze-MixinErrors.ps1          # Phân tích Mixin
│   ├── Layer-Mods.ps1                   # Phân lớp
│   ├── Isolate-Incompatible-Mod.ps1     # Cách ly (dự phòng)
│   ├── Recover-PhantomCulprits.ps1      # Khôi phục
│   └── Shared-*.ps1                     # Các module dùng chung
├── tools/
│   ├── Analyze-JarDependencies.ps1      # Phân tích phụ thuộc JAR
│   ├── Analyze-JarDependencyMap.ps1     # Xây dựng bản đồ phụ thuộc
│   └── Restore-ModsFromLog.ps1          # Khôi phục mod từ báo cáo
└── doc/
    └── Algorithm.md                     # Mô tả chi tiết thuật toán
```

## Các mod bị cách ly sẽ đi đâu

Theo mặc định, các mod bị cách ly sẽ được chuyển vào thư mục `Legacy` bên trong `StorageModsDir` (hoặc `GameModsDir` nếu không thiết lập kho lưu trữ). Điều này cho phép bạn dễ dàng khôi phục chúng thủ công nếu kết quả chẩn đoán không làm bạn hài lòng.

Cờ `-NoLegacy` sẽ xóa mod vĩnh viễn. Cờ `-GameLegacy` sẽ lưu thêm một bản sao trong thư mục game.

## Báo cáo cuối cùng (Summary)

Sau khi hoàn tất, script sẽ xuất báo cáo: thời gian chạy, danh sách thủ phạm theo từng giai đoạn, các mod được khôi phục (nếu có dùng Recovery) và danh sách các mod hiện đang bị cách ly.

## Hạn chế

- Chỉ hoạt động với Legacy Launcher (tự động hóa giao diện gắn liền với launcher này)
- Chỉ dành cho Windows (sử dụng Win32 API để quản lý cửa sổ)
- Chẩn đoán yêu cầu khởi động game nhiều lần — với các bộ mod lớn, việc này có thể mất nhiều thời gian
- Với các cụm xung đột lớn, có thể xảy ra tình trạng chạy không ổn định hoặc dừng chẩn đoán sớm
- Giai đoạn Recovery hiện vẫn đang là thử nghiệm và bị tắt theo mặc định

## Hỗ trợ

Nếu bạn thích dự án này, bạn có thể ủng hộ tác giả trên [Sponsr](https://sponsr.ru/artemonim/).
