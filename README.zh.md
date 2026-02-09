# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Minecraft 模组冲突自动诊断工具。本脚本会自动启动游戏、捕获崩溃、读取崩溃日志、找出有问题的模组并将其隔离 —— 循环执行，直到整合包可以正常运行。

> 通过 [Legacy Launcher](https://llaun.ch/)（TLauncher 的继任者）运行。游戏的启动和崩溃检测通过启动器的图形界面完成；错误分析基于标准的 Fabric/Forge/Minecraft 日志。

## 为什么需要它

你收集了 200 个模组，启动游戏 —— 结果崩溃了。打开日志 —— 满屏的代码。随便删了一个模组 —— 又出现了另一个崩溃。听起来很熟悉吧？

MCCompatibilityChecker 自动完成你手动进行的操作：移除模组、启动游戏、检查结果并重复此过程。但它并非随机尝试，而是使用包含二分查找、Mixin 错误分析和依赖关系图的算法。

最终你将得到一份问题模组列表和一个可以运行的整合包。

## 项目状态

当前版本 —— 积极开发中（实验性）。

- 目前，处理大规模不兼容冲突簇可能不太稳定。
- 对于大型整合包，建议先备份 `mods` 文件夹，并在每次运行后查看报告/日志。

## 工作原理

诊断分为几个阶段。只有当前一阶段未能解决问题时，才会启用下一阶段：

1. **基础分析 (Baseline Analysis)** —— 读取崩溃日志，在错误文本中寻找可能的候选项，并按依赖优先级顺序将其隔离。
2. **Mixin 分析** —— 解析 `Mixin apply failed` 和 `@Mixin target not found` 错误，确定源模组和目标模组，并通过 1-2 次启动进行验证。
3. **分层 (Layering)** —— 移除所有模组，仅保留核心库，然后分层添加其余模组（按依赖级别，采用指数级批处理）。如果某批次发生崩溃 —— 在该批次内进行分诊和隔离。
4. **隔离 (Isolation)** —— 兜底方案：感知依赖关系的级别，在早期级别采用指数级/二分尝试，在后期级别采用线性隔离。
5. **恢复 (Recovery)** —— 如果 3 个以上的“罪魁祸首”导致了相同的 Mixin 错误，脚本会检查它们是否为误报，并寻找真正的根源。

详细算法描述请参见 [doc/Algorithm.md](doc/Algorithm.md)。

## 系统要求

- **Windows** (使用 Win32 UI 自动化)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- 安装了 **Fabric** 或 **Forge** 的 Minecraft

## 开发依赖

- **PSScriptAnalyzer** (PowerShell 模块，`checker.ps1` 运行所需)
- **Python 3.x** (通过 `tools/Check-Localization.py` 进行本地化检查所需)

安装 `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## 快速开始

1. 克隆仓库：
   ```bash
   git clone https://github.com/<你的用户名>/MCCompatibilityChecker.git
   ```

2. 将 `config.ini` 复制为 `config.local.ini` 并指定模组文件夹路径：
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. 打开 Legacy Launcher 并选择所需版本。

4. 运行脚本：
   ```powershell
   .\run.ps1
   ```

5. 当脚本提示时 —— 将鼠标悬停在启动器的“开始游戏”(Play) 按钮上并按回车键。之后的一切都是自动的。

## 配置

设置定义在 `config.ini`（默认值）和 `config.local.ini`（你的自定义设置，被 git 忽略）中。

| 参数 | 描述 |
|-----------|----------|
| `GameModsDir` | 游戏使用的模组文件夹 |
| `StorageModsDir` | 模组的主要存储位置（可选） |
| `LogPath` | 启动器日志文件的路径（留空则自动检测） |
| `LauncherExePath` | 启动器可执行文件的路径（留空则连接到已运行的启动器） |
| `EnableMixinAnalysis` | 启用 Mixin 分析阶段（默认值：`true`） |
| `EnableLayering` | 启用分层和减法隔离（默认值：`true`） |
| `EnableRecovery` | 启用虚假罪魁祸首恢复（默认值：`false`） |
| `Language` | 控制台消息语言 (`[Localization].Language`)。如果为空：根据操作系统语言自动检测，回退到 `en` |

目前可用的本地化：`en`, `ru`。
已准备占位符：`tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`。
搜索启动器崩溃窗口会自动从 `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`) 中收集模式。
目前包含 `Something broke` / `Something went wrong` (en) 和 `Что-то сломалось...` (ru)。对于新语言，只需将此列表添加到相应的本地化文件中。
如果你的启动器窗口标题不同，可以在 `[Profile:<名称>]` 中显式设置 `CrashWindowTitlePatterns` 并使用 `-Profile <名称>` 运行。

## 主要启动参数

```bash
.\run.ps1 -Help          # 简短帮助
.\run.ps1 -HelpFull      # 完整的技术帮助
```

| 标志 | 描述 |
|------|----------|
| `-LauncherExePath <路径>` | 启动器路径（如果未在配置中指定） |
| `-NoLegacy` | 不保存隔离的模组 —— 直接删除 |
| `-GameLegacy` | 在游戏文件夹中保留隔离模组的副本 |
| `-DryRun` | 显示将要执行的操作，而不进行实际执行 |
| `-Verbose` | 详细日志（输出到控制台和 `MCCC.log`） |
| `-UseLinearIsolation` | 使用线性搜索代替二分搜索（较慢但更简单） |
| `-NoCache` | 禁用会话缓存（重新验证即使是之前成功的配置） |
| `-ThoroughStabilityCheck` | 增加启动稳定性检查窗口 |
| `-AutoHandleFabricDialog <bool>` | 在调试流水线中自动处理不含缺失依赖项的 Fabric 对话框 |
| `-IgnoreModIds <id1,id2,...>` | 在兼容性清理中忽略指定的模组 ID |
| `-Profile <名称>` | 应用 `config.ini` / `config.local.ini` 中 `[Profile:<名称>]` 的配置 |

## 脚本和本地化检查

`checker.ps1` 检查：
- 通过 `PSScriptAnalyzer` 检查 PowerShell 脚本
- 通过 `tools/Check-Localization.py` 检查本地化资产
- `Write-Verbose`/仅调试字符串被视为服务字符串，保留英文，不计入本地化覆盖范围。

示例：
```powershell
.\checker.ps1             # 完整检查（包括本地化）
.\checker.ps1 -NoLocales  # 跳过本地化检查
```

缺失 Python 时的行为：
- 默认情况下，这会被视为**错误**（检查器以错误代码退出），以免漏掉本地化系统的故障。
- 如果你不处理本地化，请使用 `-NoLocales`。

## 项目结构

```
├── run.ps1                  # 入口点
├── config.ini               # 默认配置
├── checker.ps1              # Linter + 本地化检查
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # 编排器：启动、监控、循环
│   ├── Check-Mod-Compatibility.ps1      # 基础分析
│   ├── Analyze-MixinErrors.ps1          # Mixin 分析
│   ├── Layer-Mods.ps1                   # 分层
│   ├── Isolate-Incompatible-Mod.ps1     # 隔离 (兜底)
│   ├── Recover-PhantomCulprits.ps1      # 恢复
│   └── Shared-*.ps1                     # 共享模块
├── tools/
│   ├── Analyze-JarDependencies.ps1      # JAR 依赖分析
│   ├── Analyze-JarDependencyMap.ps1     # 建立依赖关系图
│   └── Restore-ModsFromLog.ps1          # 从报告中恢复模组
└── doc/
    └── Algorithm.md                     # 详细算法描述
```

## 隔离的模组去哪了

默认情况下，隔离的模组会被移动到 `StorageModsDir`（如果未设置存储位置，则为 `GameModsDir`）内的 `Legacy` 文件夹中。如果你对诊断结果不满意，可以轻松地手动恢复它们。

`-NoLegacy` 标志会永久删除模组。`-GameLegacy` 标志还会额外在游戏文件夹中保存一份副本。

## 最终总结报告 (Summary)

完成后，脚本会输出一份报告：运行时间、各阶段发现的罪魁祸首列表、恢复的模组（如果使用了恢复功能）以及当前被隔离的模组列表。

## 局限性

- 仅适用于 Legacy Launcher（图形界面自动化绑定到其界面）
- 仅限 Windows (使用 Win32 API 进行窗口 management)
- 诊断需要多次启动游戏 —— 对于大型整合包，这可能需要相当长的时间
- 遇到大规模不兼容冲突簇时，可能会出现运行不稳定或诊断过早停止的情况
- 恢复阶段目前处于实验阶段，默认情况下是禁用的

## 许可证

MIT
