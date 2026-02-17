# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Diagnosis otomatis konflik mod Minecraft. Script ini akan menjalankan game, menangkap crash, membaca log crash, menemukan mod penyebab masalah, dan mengisolasinya — dalam sebuah loop hingga susunan mod dapat berjalan.

> Bekerja melalui [Legacy Launcher](https://llaun.ch/) (penerus TLauncher). Menjalankan game dan deteksi crash dilakukan melalui GUI launcher; analisis kesalahan berdasarkan log standar Fabric/Forge/Minecraft.

## Mengapa

Anda mengumpulkan 200 mod, menjalankannya — dan crash. Anda membuka log — dan isinya adalah dinding teks. Anda menghapus mod secara acak — dan muncul crash lain. Terasa familiar?

MCCompatibilityChecker melakukan apa yang Anda lakukan secara manual, tetapi secara otomatis: menghapus mod, menjalankan game, memeriksa hasilnya, dan mengulanginya. Namun, alih-alih mencoba secara acak, ia menggunakan algoritma dengan pencarian biner, analisis kesalahan Mixin, dan peta dependensi.

Hasilnya adalah daftar mod penyebab masalah dan susunan mod yang berfungsi.

## Status Proyek

Versi saat ini — dalam pengembangan aktif (eksperimental).

- Saat ini, pemrosesan klaster ketidakcocokan yang besar mungkin tidak stabil.
- Untuk susunan mod yang besar, disarankan untuk membuat cadangan folder `mods` terlebih dahulu dan menggunakan laporan/log setelah setiap sesi berjalan.

## Cara Kerja

Diagnosis berlangsung dalam beberapa tahap. Setiap tahap berikutnya hanya akan diaktifkan jika tahap sebelumnya tidak menyelesaikan masalah:

1. **Analisis Dasar (Baseline Analysis)** — membaca log crash, mencari kandidat dalam teks kesalahan, dan mengisolasinya berdasarkan urutan prioritas dependensi.
2. **Analisis Mixin** — mengurai kesalahan `Mixin apply failed` dan `@Mixin target not found`, menentukan mod sumber dan target, serta memeriksa masing-masing dalam 1–2 kali percobaan jalankan.
3. **Pelapisan (Layering)** — menghapus semua mod, menyisakan pustaka inti (core), dan menambahkan sisanya secara berlapis (berdasarkan tingkat dependensi, dalam batch eksponensial). Jika terjadi crash pada batch — dilakukan triage dan isolasi di dalam batch tersebut.
4. **Isolasi (Isolation)** — solusi cadangan: tingkat yang sadar dependensi, percobaan eksponensial/biner pada tingkat awal, dan isolasi linear pada tingkat akhir.
5. **Pemulihan (Recovery)** — jika 3+ "penyebab" memberikan kesalahan Mixin yang sama, script akan memeriksa apakah itu positif palsu dan mencari akar masalah yang sebenarnya.

Deskripsi detail algoritma ada di [doc/Algorithm.md](doc/Algorithm.md).

## Persyaratan

- **Windows** (menggunakan Win32 UI Automation)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- Minecraft dengan **Fabric** atau **Forge**

## Dependensi Pengembangan

- **PSScriptAnalyzer** (modul PowerShell, diperlukan untuk `checker.ps1`)
- **Python 3.x** (diperlukan untuk pemeriksaan lokalisasi melalui `tools/Check-Localization.py`)
- **Pester** (modul PowerShell, diperlukan untuk tes `checker.ps1` jika `-NoPester` tidak digunakan)

Instalasi `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Memulai Cepat

1. Clone repositori atau unduh arsip dari [rilis terbaru](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest):
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. Salin `config.ini` ke `config.local.ini` dan tentukan jalur ke folder mod Anda:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Buka Minecraft Launcher.

4. Ketik `./run.ps1` atau `./run.ps1 -verbose` ke dalam konsol PowerShell.

5. Arahkan mouse ke tombol peluncuran klien di launcher.

6. Tekan `Enter` untuk mengirim perintah konsol dan biarkan Checker mendapatkan koordinat tombol.

## Konfigurasi

Pengaturan ditentukan dalam `config.ini` (default) dan `config.local.ini` (penyesuaian Anda, diabaikan oleh git).

| Parameter | Deskripsi |
|-----------|-----------|
| `GameModsDir` | Folder mod yang digunakan oleh game |
| `StorageModsDir` | Penyimpanan utama mod (opsional) |
| `LogPath` | Jalur ke file log launcher (kosong untuk deteksi otomatis) |
| `LauncherExePath` | Jalur ke file eksekusi launcher (kosong untuk menghubungkan ke yang sudah berjalan) |
| `EnableMixinAnalysis` | Aktifkan tahap analisis Mixin (default: `true`) |
| `EnableLayering` | Aktifkan Pelapisan dan Isolasi subtraktif (default: `true`) |
| `EnableRecovery` | Aktifkan Pemulihan penyebab semu (default: `true`) |
| `Language` | Bahasa pesan konsol (`[Localization].Language`). Jika kosong: otomatis dari bahasa OS, fallback `en` |

Locale yang tersedia saat ini: `en`, `ru`.
Stub disiapkan untuk: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
Pencarian jendela crash launcher secara otomatis mengumpulkan pola dari `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`).
Saat ini mencakup pola judul `Something broke...`, `Something went wrong...`, dan `Что-то сломалось...`. Untuk bahasa baru, cukup tambahkan daftar ini ke file locale yang sesuai.
Jika judul jendela launcher Anda berbeda, Anda dapat mengatur `CrashWindowTitlePatterns` secara eksplisit di `[Profile:<nama>]` dan jalankan dengan `-Profile <nama>`.

## Parameter Utama Menjalankan

```bash
.\run.ps1 -Help          # Bantuan singkat
.\run.ps1 -HelpFull      # Bantuan teknis lengkap
```

| Flag | Deskripsi |
|------|-----------|
| `-LauncherExePath <jalur>` | Jalur ke launcher (jika tidak ditentukan di konfigurasi) |
| `-NoLegacy` | Jangan simpan mod yang diisolasi — hapus saja |
| `-GameLegacy` | Simpan salinan mod yang diisolasi di folder game |
| `-DryRun` | Tampilkan apa yang akan dilakukan tanpa eksekusi nyata |
| `-Verbose` | Log mendetail (ke konsol dan `MCCC.log`) |
| `-UseLinearIsolation` | Pencarian linear alih-alih biner (lebih lambat tetapi lebih sederhana) |
| `-NoCache` | Matikan cache sesi (verifikasi ulang bahkan konfigurasi yang sebelumnya berhasil) |
| `-OutcomeTimeoutSeconds <sec>` | Waktu tunggu hasil setelah menekan Play (default: 60) |
| `-ThoroughStabilityCheck` | Tingkatkan jendela pemeriksaan stabilitas saat menjalankan |
| `-AutoHandleFabricDialog <bool>` | Pengalihan otomatis dialog Fabric tanpa dependensi yang hilang dalam pipeline debug |
| `-IgnoreModIds <id1,id2,...>` | Abaikan id mod yang ditentukan dalam pembersihan kompatibilitas |
| `-Profile <nama>` | Terapkan profil dari `[Profile:<nama>]` di `config.ini` / `config.local.ini` |

## Pemeriksaan Script dan Lokalisasi

`checker.ps1` memeriksa:
- Script PowerShell melalui `PSScriptAnalyzer`
- Aset lokalisasi melalui `tools/Check-Localization.py`
- String `Write-Verbose`/hanya-debug dianggap sebagai string layanan, tetap dalam bahasa Inggris dan tidak termasuk dalam cakupan lokalisasi.

Contoh:
```powershell
.\checker.ps1             # Pemeriksaan lengkap (termasuk locale)
.\checker.ps1 -NoLocales  # Lewati pemeriksaan locale
.\checker.ps1 -NoPester   # Lewati tes Pester
.\checker.ps1 .\scripts\Shared-FileOps.ps1  # Periksa hanya file/path yang ditentukan
```

Perilaku saat Python tidak ada:
- Secara default, ini dianggap sebagai **error** (checker akan berhenti dengan kode error) agar tidak melewatkan kerusakan pada sistem lokalisasi.
- Jika Anda tidak bekerja dengan lokalisasi, gunakan `-NoLocales`.

## Struktur Proyek

```
├── run.ps1                  # Titik masuk (Entry point)
├── config.ini               # Konfigurasi default
├── checker.ps1              # Linter + pemeriksaan lokalisasi
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Orchestrator: jalankan, pemantauan, loop
│   ├── Check-Mod-Compatibility.ps1      # Analisis Dasar
│   ├── Analyze-MixinErrors.ps1          # Analisis Mixin
│   ├── Layer-Mods.ps1                   # Pelapisan
│   ├── Isolate-Incompatible-Mod.ps1     # Isolasi (cadangan)
│   ├── Recover-PhantomCulprits.ps1      # Pemulihan
│   └── Shared-*.ps1                     # Modul bersama
├── tools/
│   ├── Analyze-JarDependencies.ps1      # Pencarian dependensi di dalam file JAR mod
│   ├── Analyze-JarDependencyMap.ps1     # Pembuatan peta dependensi lengkap dan laporan
│   ├── Check-Localization.py            # Validasi aset lokalisasi
│   ├── Count-ModMinecraftVersions.py    # Penghitungan mod berdasarkan versi Minecraft
│   ├── Find-SuspiciousDuplicateMods.py  # Pencarian duplikat mod yang mencurigakan
│   └── Restore-ModsFromLog.ps1          # Pemulihan mod dari log isolasi
└── doc/
    └── Algorithm.md                     # Deskripsi detail algoritma
```

## Ke mana perginya mod yang diisolasi

Secara default, mod yang diisolasi dipindahkan ke folder `Legacy` di dalam `StorageModsDir` (atau `GameModsDir` jika penyimpanan tidak diatur). Ini memungkinkan Anda untuk memulihkannya secara manual dengan mudah jika hasil diagnosis tidak memuaskan Anda.

Flag `-NoLegacy` akan hapus mod secara permanen. Flag `-GameLegacy` juga menyimpan salinan di folder game.

## Laporan Akhir (Summary)

Setelah selesai, script akan menampilkan laporan: waktu eksekusi, daftar penyebab masalah berdasarkan tahap, mod yang dipulihkan (jika Pemulihan digunakan), dan daftar mod yang saat ini diisolasi.

## Batasan

- Hanya berfungsi dengan Legacy Launcher (otomatisasi GUI terikat pada antarmukanya)
- Hanya Windows (Win32 API untuk manajemen jendela)
- Diagnosis memerlukan berkalikali menjalankan game — pada susunan mod yang besar, hal ini dapat memakan waktu yang cukup lama
- Pada klaster ketidakcocokan yang besar, kemungkinan terjadi sesi berjalan yang tidak stabil dan penghentian diagnosis lebih awal
- Tahap Pemulihan saat ini masih eksperimental, tetapi diaktifkan secara default (`[Stages].EnableRecovery=true`)

## Dukungan

Jika Anda menyukai proyek ini, Anda dapat mendukung penulis di [Sponsr](https://sponsr.ru/artemonim/).
