# REFACTORING TODO

## Правила приоритета
- Приоритет решений: `DRY > SRP > YAGNI`.
- `YAGNI` трактуется как мягкий Garbage Collector: удаляем только то, что доказуемо не дает ценности или мешает сопровождению, без агрессивной "чистки ради чистки".

## Область текущего рефакторинга
- Основной код: `scripts/`
- Дополнительные утилиты: `tools/`
- Legacy Launcher (`archive/`) не трогаем в первой волне.

## База наблюдений (по коду)
- Повторяются функции ожидания запуска:
`Get-ActiveModCount`, `Get-ScaledLaunchWaitTime` в `scripts/Analyze-MixinErrors.ps1`, `scripts/Layer-Mods.ps1`, `scripts/Recover-PhantomCulprits.ps1`.
- Дублируются большие блоки сборки параметров дочерних этапов в `scripts/Auto-Run-LegacyLauncher.ps1`:
`Get-IsolationParam`, `Get-LayeringParam`, `Get-MixinAnalysisParam`, `Get-RecoveryParam`.
- Один и тот же bootstrap конфигурации (`Import-ProjectConfig`, чтение `GameModsDir`/`StorageModsDir`/`LogPath`/`LauncherExePath`) повторяется почти во всех entry-скриптах.
- Логика парсинга логов дублируется между `scripts/Check-Mod-Compatibility.ps1` и `scripts/Shared-Isolation-LogParsing.ps1` (включая `Get-MinecraftVersionFromLog`).
- Сценарий перемещения виновника в legacy и запись в `legacy.log` реализован в нескольких местах:
`scripts/Analyze-MixinErrors.ps1`, `scripts/Layer-Mods.ps1`, `scripts/Isolate-Incompatible-Mod.ps1`, `scripts/Recover-PhantomCulprits.ps1`.
- В `scripts/Shared-Isolation-Strategy.ps1` и частично в `scripts/Shared-Isolation-Launcher.ps1` сильная связность через глобальные `$script:*` переменные вызывающих скриптов.

## План рефакторинга

## Фаза 1 (DRY, сначала)
1. Вынести общий bootstrap окружения в shared-функцию.
Действия:
- Добавить `Initialize-McccRuntimeConfig` в `scripts/Shared-Config.ps1` (или новый `scripts/Shared-Bootstrap.ps1`).
- Централизовать чтение `Paths` и дефолтов (mods/storage/log/launcher).
- Переподключить `Auto-Run`, `Check-Mod-Compatibility`, `Analyze-MixinErrors`, `Layer-Mods`, `Isolate-Incompatible-Mod`, `Recover-PhantomCulprits`.
Критерий готовности:
- Нет копипаста однотипных `Get-IniValue` блоков в entry-скриптах.

2. Унифицировать сбор параметров для дочерних сценариев.
Действия:
- Вынести повторяющуюся сборку launcher/UI/log параметров из `Auto-Run-LegacyLauncher` в одну функцию-конструктор.
- Оставить только stage-specific overrides (изоляция/наслоение/mixin/recovery).
Критерий готовности:
- В `Auto-Run` одна точка формирования общего набора параметров.

3. Убрать дубли функций динамического времени ожидания.
Действия:
- Вынести `Get-ActiveModCount` и `Get-ScaledLaunchWaitTime` в shared-модуль.
- Подключить из `Analyze-MixinErrors`, `Layer-Mods`, `Recover-PhantomCulprits`.
Критерий готовности:
- Функции существуют в единственном месте.

4. Свести парсинг логов в один источник правды.
Действия:
- Перенести недостающие функции из `Check-Mod-Compatibility` в `Shared-Isolation-LogParsing` (или наоборот) и переиспользовать.
- Удалить дубли (`Get-MinecraftVersionFromLog` и пересекающиеся regex-блоки).
Критерий готовности:
- Парсинг сигнатур/версии/ID выполняется единым модулем.

5. Единый helper для перемещения culprit в legacy.
Действия:
- Создать shared-функцию `Move-CulpritToLegacyAndAppendLog` с одинаковой семантикой для storage/game.
- Использовать ее в `Analyze-MixinErrors`, `Layer-Mods`, `Isolate-Incompatible-Mod`, `Recover-PhantomCulprits`.
Критерий готовности:
- Одинаковое поведение и формат лога по всем этапам.

6. Убрать дубли парсинга JAR metadata между `tools/` и `scripts/`.
Действия:
- Общие функции (`Get-ZipEntryText`, `ConvertFrom-ForgeToml`, разбор Fabric/Quilt) вынести в единый shared-модуль.
- Подключить из `scripts/Shared-Isolation-JarDependencies.ps1` и `tools/Analyze-JarDependencyMap.ps1`.
Критерий готовности:
- Нет двух независимых реализаций одного и того же парсера.

## Фаза 2 (SRP, после DRY)
1. Разделить крупные оркестраторы на подмодули по ответственности.
Действия:
- `Auto-Run-LegacyLauncher`: разделить на session-loop, stage-dispatch, reporting, restore-flow.
- `Layer-Mods`: разделить на baseline/core-check, layer execution, batch triage, finalize.
- `Isolate-Incompatible-Mod`: разделить на baseline capture, strategy loop, culprit finalize.
Критерий готовности:
- В каждом файле меньше "god-script" логики, основные сценарии читаются сверху вниз без длинных inline-блоков.

2. Перейти с неявных globals на явный context-object.
Действия:
- Для `Shared-Isolation-Strategy` и `Shared-Isolation-Launcher` передавать структурированный context (paths, ui, timeouts, flags, cache state).
- Сократить использование `$script:*` к минимуму.
Критерий готовности:
- Shared-функции тестируемы изолированно, без обязательной подготовки внешних глобальных переменных.

3. Стандартизировать контракты результатов этапов.
Действия:
- Ввести единый формат result-объектов (launch outcome, culprit record, recovery result).
- Убрать ad-hoc поля и ручные преобразования в `Auto-Run`.
Критерий готовности:
- Единые поля и минимум специальных веток преобразования между этапами.

4. Разделить "чистую" алгоритмику и side-effects.
Действия:
- Логику принятия решений (что изолировать/когда считать стабильным) отделить от UI-кликов, перемещений файлов и вывода в консоль.
Критерий готовности:
- Алгоритмические функции можно запускать на входных данных без GUI/файловых операций.

## Фаза 3 (YAGNI как мягкий GC, после DRY+SRP)
1. Удалить подтвержденно лишние элементы.
Действия:
- Удалить неиспользуемую `Write-LegacyLog` в `scripts/Check-Mod-Compatibility.ps1`.
- Удалить/деактивировать устаревший `MaxAttempts` (и из `run.ps1` help/описаний, если не используется).
Критерий готовности:
- Нет мертвого кода и "deprecated but kept forever" без реальной причины.

2. Сократить поверхность CLI-параметров без потери сценариев.
Действия:
- Сгруппировать редко используемые ручки в profile/config-блоки.
- Сохранить совместимость через алиасы на переходный период.
Критерий готовности:
- Меньше когнитивной нагрузки при запуске, основные флаги остаются очевидными.

3. Привести дефолты утилит к проектным.
Действия:
- Убрать персональные hardcoded-пути в `tools/Analyze-JarDependencyMap.ps1`.
- Подчинить defaults `config.ini`/`config.local.ini` или относительным путям проекта.
Критерий готовности:
- Инструменты запускаются "из коробки" на любом окружении без правок кода.

## Последовательность выполнения (минимальный риск)
1. DRY-функции без изменения поведения.
2. Подключение entry-скриптов к новым shared-функциям.
3. SRP-декомпозиция по одному сценарию за раз (`Auto-Run` -> `Layer` -> `Isolate`).
4. YAGNI-чистка только после покрытия ключевых потоков smoke-проверками.

## Контроль после каждого шага
- Прогон `./checker.ps1`.
- Smoke сценарий:
  - baseline crash detection;
  - mixin stage;
  - layering stage;
  - isolate fallback;
  - recovery (если включен);
  - корректная запись/чтение `legacy.log`.
