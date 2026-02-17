# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Minecraft mod çakışmalarının otomatik teşhisi. Script oyunu kendisi başlatır, çökmeleri (crash) yakalar, çökme günlüklerini okur, suçlu modu bulur ve izole eder — mod paketi çalışana kadar bu döngüyü sürdürür.

> [Legacy Launcher](https://llaun.ch/) (TLauncher'ın halefi) aracılığıyla çalışır. Oyunun başlatılması ve çökmelerin tespiti başlatıcının (launcher) arayüzü üzerinden yapılır; hata analizi ise standart Fabric/Forge/Minecraft günlüklerine dayanır.

## Neden Kullanmalı?

200 mod topladınız, oyunu başlattınız ve çöktü. Günlüğü açtınız ve karşınıza bir yazı duvarı çıktı. Rastgele bir modu kaldırdınız ve başka bir çökme aldınız. Tanıdık geldi mi?

MCCompatibilityChecker, sizin manuel olarak yaptığınız şeyi otomatik olarak yapar: modları kaldırır, oyunu başlatır, sonucu kontrol eder ve tekrarlar. Ancak rastgele denemeler yerine; ikili arama (binary search), Mixin hata analizi ve bağımlılık haritası içeren bir algoritma kullanır.

Sonuçta elinizde suçlu listesi ve çalışan bir mod paketi olur.

## Proje Durumu

Mevcut sürüm — aktif geliştirme aşamasındadır (deneysel).

- Şu anda büyük uyumsuzluk kümelerinin işlenmesi kararsız olabilir.
- Büyük mod paketleri için önce `mods` klasörünün yedeğini almanız ve her çalıştırmadan sonra raporları/günlükleri kullanmanız önerilir.

## Nasıl Çalışır?

Teşhis birkaç aşamada gerçekleşir. Her sonraki aşama, ancak bir önceki aşama sorunu çözmediyse etkinleştirilir:

1. **Temel Analiz (Baseline Analysis)** — çökme günlüğünü okur, hata metnindeki adayları arar ve bunları bağımlılık önceliğine göre izole eder.
2. **Mixin Analizi** — `Mixin apply failed` ve `@Mixin target not found` hatalarını çözümler, kaynak ve hedef modları belirler ve her birini 1-2 başlatma ile kontrol eder.
3. **Katmanlama (Layering)** — tüm modları kaldırır, çekirdek (core) kütüphaneleri bırakır ve geri kalanını katmanlar halinde ekler (bağımlılık seviyelerine göre, üstel paketler halinde). Bir paket çöktüğünde — paket içinde önceliklendirme ve izolasyon yapılır.
4. **İzolasyon (Isolation)** — yedek çözüm: bağımlılık odaklı seviyeler, erken seviyelerde üstel/ikili denemeler ve geç seviyelerde doğrusal izolasyon.
5. **Kurtarma (Recovery)** — eğer 3 veya daha fazla "suçlu" aynı Mixin hatasını verirse, script bunların yanlış pozitif olup olmadığını kontrol eder ve gerçek ana nedeni arar.

Algoritmanın ayrıntılı açıklaması [doc/Algorithm.md](doc/Algorithm.md) dosyasındadır.

## Gereksinimler

- **Windows** (Win32 UI Automation kullanılır)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- **Fabric** veya **Forge** yüklü Minecraft

## Geliştirme Bağımlılıkları

- **PSScriptAnalyzer** (PowerShell modülü, `checker.ps1` için gereklidir)
- **Python 3.x** (`tools/Check-Localization.py` aracılığıyla yerelleştirme kontrolleri için gereklidir)
- **Pester** (`-NoPester` kullanılmadığında `checker.ps1` testleri için gereken PowerShell modülü)

`PSScriptAnalyzer` kurulumu:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Hızlı Başlangıç

1. Depoyu klonlayın veya [en son sürümden](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest) arşivi indirin:
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. `config.ini` dosyasını `config.local.ini` olarak kopyalayın ve mod klasörünüzün yolunu belirtin:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Minecraft Launcher'ı açın.

4. PowerShell konsolu'na `./run.ps1` veya `./run.ps1 -verbose` yazın.

5. Fareyi başlatıcıdaki istemci başlatma düğmesinin üzerine getirin.

6. Konsol komutunu göndermek ve Checker'ın düğme koordinatlarını almasına izin vermek için `Enter` tuşuna basın.

## Yapılandırma

Ayarlar `config.ini` (varsayılanlar) ve `config.local.ini` (sizin özel ayarlarınız, git tarafından yoksayılır) dosyalarında tanımlanır.

| Parametre | Açıklama |
|-----------|----------|
| `GameModsDir` | Oyunun kullandığı mod klasörü |
| `StorageModsDir` | Ana mod deposu (isteğe bağlı) |
| `LogPath` | Başlatıcı günlük dosyası yolu (otomatik tespit için boş bırakın) |
| `LauncherExePath` | Başlatıcı çalıştırılabilir dosya yolu (çalışan bir tanesine bağlanmak için boş bırakın) |
| `EnableMixinAnalysis` | Mixin analizi aşamasını etkinleştir (varsayılan: `true`) |
| `EnableLayering` | Katmanlama ve çıkarmalı izolasyonu etkinleştir (varsayılan: `true`) |
| `EnableRecovery` | Hayalet suçluların kurtarılmasını etkinleştir (varsayılan: `true`) |
| `Language` | Konsol mesajları dili (`[Localization].Language`). Boşsa: işletim sistemi dilinden otomatik, yedek olarak `en` |

Şu anki mevcut yereller: `en`, `ru`.
Şunlar için taslaklar hazırlandı: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
Başlatıcının çökme penceresi araması otomatik olarak `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`) içinden desenleri toplar.
Şu anda `Something broke...`, `Something went wrong...` ve `Что-то сломалось...` desenlerini içerir. Yeni diller için bu listeyi ilgili locale dosyasına eklemek yeterlidir.
Başlatıcı pencerenizin başlığı farklıysa, `CrashWindowTitlePatterns` parametresini `[Profile:<isim>]` içinde açıkça belirtebilir ve `-Profile <isim>` ile çalıştırabilirsiniz.

## Ana Başlatma Parametreleri

```bash
.\run.ps1 -Help          # Kısa yardım
.\run.ps1 -HelpFull      # Tam teknik yardım
```

| Bayrak | Açıklama |
|--------|----------|
| `-LauncherExePath <yol>` | Başlatıcı yolu (yapılandırmada belirtilmemişse) |
| `-NoLegacy` | İzole edilen modları kaydetme — sil |
| `-GameLegacy` | İzole edilen modların kopyalarını oyun klasöründe tut |
| `-DryRun` | Gerçekten çalıştırmadan ne yapılacağını göster |
| `-Verbose` | Ayrıntılı günlükler (konsola ve `MCCC.log` dosyasına) |
| `-UseLinearIsolation` | İkili yerine doğrusal arama (daha yavaş ama daha basit) |
| `-NoCache` | Oturum önbelleğini kapat (daha önce başarılı olan yapılandırmaları bile tekrar kontrol et) |
| `-OutcomeTimeoutSeconds <sec>` | Play'e bastıktan sonra sonuç bekleme süresi (varsayılan: 60) |
| `-ThoroughStabilityCheck` | Başlatma kararlılığı kontrol süresini artır |
| `-AutoHandleFabricDialog <bool>` | Hata ayıklama boru hattında eksik bağımlılık olmayan Fabric diyaloglarını otomatik yönlendir |
| `-IgnoreModIds <id1,id2,...>` | Uyumluluk temizliğinde belirtilen mod id'lerini yoksay |
| `-Profile <isim>` | `config.ini` / `config.local.ini` içindeki `[Profile:<isim>]` profilini uygula |

## Script ve Yerelleştirme Kontrolü

`checker.ps1` şunları kontrol eder:
- `PSScriptAnalyzer` ile PowerShell scriptleri
- `tools/Check-Localization.py` ile yerelleştirme varlıkları
- `Write-Verbose`/sadece hata ayıklama dizeleri hizmet dizeleri olarak kabul edilir, İngilizce kalır ve yerelleştirme kapsamına dahil edilmez.

Örnekler:
```powershell
.\checker.ps1             # Tam kontrol (yerelleştirmeler dahil)
.\checker.ps1 -NoLocales  # Yerelleştirme kontrolünü atla
.\checker.ps1 -NoPester   # Pester testlerini atla
.\checker.ps1 .\scripts\Shared-FileOps.ps1  # Yalnızca belirtilen dosya/yolu kontrol et
```

Python eksik olduğunda davranış:
- Yerelleştirme sistemindeki bir bozulmayı kaçırmamak için varsayılan olarak bu bir **hatadır** (checker hata koduyla sonlanır).
- Yerelleştirme ile çalışmıyorsanız `-NoLocales` kullanın.

## Proje Yapısı

```
├── run.ps1                  # Giriş noktası
├── config.ini               # Varsayılan yapılandırma
├── checker.ps1              # Linter + yerelleştirme kontrolü
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Orkestratör: başlatma, izleme, döngü
│   ├── Check-Mod-Compatibility.ps1      # Temel Analiz
│   ├── Analyze-MixinErrors.ps1          # Mixin Analizi
│   ├── Layer-Mods.ps1                   # Katmanlama
│   ├── Isolate-Incompatible-Mod.ps1     # İzolasyon (yedek)
│   ├── Recover-PhantomCulprits.ps1      # Kurtarma
│   └── Shared-*.ps1                     # Ortak modüller
├── tools/
│   ├── Analyze-JarDependencies.ps1      # Mod JAR dosyaları içindeki bağımlılıkları arama
│   ├── Analyze-JarDependencyMap.ps1     # Tam bağımlılık haritası oluşturma ve raporlar
│   ├── Check-Localization.py            # Yerelleştirme varlıklarının doğrulanması
│   ├── Count-ModMinecraftVersions.py    # Minecraft sürümlerine göre mod sayımı
│   ├── Find-SuspiciousDuplicateMods.py  # Şüpheli mod kopyalarını bulma
│   └── Restore-ModsFromLog.ps1          # İzolasyon günlüğünden modları geri yükleme
└── doc/
    └── Algorithm.md                     # Algoritmanın ayrıntılı açıklaması
```

## İzole Edilen Modlar Nereye Gidiyor?

Varsayılan olarak izole edilen modlar, `StorageModsDir` (veya depo ayarlanmamışsa `GameModsDir`) içindeki `Legacy` klasörüne taşınır. Bu, teşhis sonucu sizi tatmin etmezse modları manuel olarak kolayca geri yüklemenize olanak tanır.

`-NoLegacy` bayrağı modları kalıcı olarak siler. `-GameLegacy` bayrağı ek olarak oyun klasöründe bir kopya saklar.

## Final Özet Raporu (Summary)

Tamamlandıktan sonra script bir rapor sunar: çalışma süresi, aşamalara göre suçlu listesi, geri yüklenen modlar (Kurtarma kullanıldıysa) ve mevcut izole edilmiş modların listesi.

## Kısıtlamalar

- Sadece Legacy Launcher ile çalışır (arayüz otomasyonu onun arayüzüne bağlıdır)
- Sadece Windows (Pencere yönetimi için Win32 API)
- Teşhis, oyunun defalarca başlatılmasını gerektirir — büyük mod paketlerinde bu önemli bir zaman alabilir
- Büyük uyumsuzluk kümelerinde kararsız çalışmalar ve teşhisin erken durması mümkündür
- Kurtarma aşaması şu an için deneyseldir, ancak varsayılan olarak açıktır (`[Stages].EnableRecovery=true`)

## Destek

Bu projeyi beğendiyseniz, yazarı [Sponsr](https://sponsr.ru/artemonim/) üzerinden destekleyebilirsiniz.
