# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Diagnóstico automático de conflictos de mods de Minecraft. El script inicia el juego, detecta cierres inesperados (crashes), lee los registros de errores, encuentra el mod culpable y lo aísla, en un ciclo continuo hasta que la colección de mods funcione.

> Funciona a través de [Legacy Launcher](https://llaun.ch/) (sucesor de TLauncher). El inicio del juego y la detección de errores se realizan a través de la interfaz del lanzador; el análisis de errores se basa en los registros estándar de Fabric/Forge/Minecraft.

## Por qué

Has reunido 200 mods, has iniciado el juego y se ha cerrado. Has abierto el registro y es un muro de texto. Has quitado un mod al azar y has tenido otro error. ¿Te suena?

MCCompatibilityChecker hace lo que tú haces manualmente, pero de forma automática: quita mods, inicia el juego, comprueba el resultado y repite. Pero en lugar de intentos aleatorios, utiliza un algoritmo con búsqueda binaria, análisis de errores de Mixin y un mapa de dependencias.

El resultado es una lista de culpables y una colección de mods que funciona.

## Estado del proyecto

Versión actual — desarrollo activo (experimental).

- Actualmente, el procesamiento de grandes grupos de incompatibilidades puede ser inestable.
- Para colecciones grandes, se recomienda hacer primero una copia de seguridad de la carpeta `mods` y utilizar los informes/registros después de cada ejecución.

## Cómo funciona

El diagnóstico se realiza en varias etapas. Cada etapa posterior se activa solo si la anterior no resolvió el problema:

1. **Análisis Básico** — lee el registro de errores, busca candidatos en el texto del error y los aísla por prioridad de dependencia.
2. **Análisis de Mixin** — analiza los errores `Mixin apply failed` y `@Mixin target not found`, identifica los mods de origen y destino, y verifica cada uno en 1 o 2 inicios.
3. **Capas (Layering)** — quita todos los mods, deja las bibliotecas base (core) y añade el resto por capas (por niveles de dependencia, en lotes exponenciales). Si un lote falla, se realiza un triaje e aislamiento dentro del lote.
4. **Aislamiento (Isolation)** — alternativa final: niveles basados en dependencias, pruebas exponenciales/binarias en niveles tempranos y aislamiento lineal en niveles posteriores.
5. **Recuperación (Recovery)** — si 3 o más "culpables" dan el mismo error de Mixin, el script comprueba si fueron falsos positivos y busca la verdadera causa raíz.

Descripción detallada del algoritmo en [doc/Algorithm.md](doc/Algorithm.md).

## Requisitos

- **Windows** (se utiliza Win32 UI Automation)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- Minecraft con **Fabric** o **Forge**

## Dependencias de desarrollo

- **PSScriptAnalyzer** (módulo de PowerShell, necesario para `checker.ps1`)
- **Python 3.x** (necesario para la verificación de localizaciones mediante `tools/Check-Localization.py`)

Instalación de `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Inicio rápido

1. Clona el repositorio o descarga el archivo desde la [última versión](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest):
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. Copia `config.ini` a `config.local.ini` e indica la ruta a tu carpeta de mods:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Abre Minecraft Launcher.

4. Escribe `./run.ps1` o `./run.ps1 -verbose` en la consola de PowerShell.

5. Coloca el mouse sobre el botón de lanzamiento del cliente en el lanzador.

6. Presiona `Enter` para enviar el comando de consola y permitir que el Checker obtenga las coordenadas del botón.

## Configuración

Los ajustes se definen en `config.ini` (predeterminados) y `config.local.ini` (tus personalizaciones, ignorado por git).

| Parámetro | Descripción |
|-----------|-------------|
| `GameModsDir` | Carpeta de mods que utiliza el juego |
| `StorageModsDir` | Almacenamiento principal de mods (opcional) |
| `LogPath` | Ruta al archivo de registro del lanzador (vacío para detección automática) |
| `LauncherExePath` | Ruta al ejecutable del lanzador (vacío para conectar a uno ya iniciado) |
| `EnableMixinAnalysis` | Activar etapa de análisis de Mixin (por defecto: `true`) |
| `EnableLayering` | Activar capas e aislamiento sustractivo (por defecto: `true`) |
| `EnableRecovery` | Activar recuperación de culpables fantasmas (por defecto: `true`) |
| `Language` | Idioma de los mensajes de consola (`[Localization].Language`). Si está vacío: automático según el SO, por defecto `en` |

Locales disponibles: `en`, `ru`.
Preparados para: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
La búsqueda de la ventana de error del lanzador recopila automáticamente patrones de `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`).
Actualmente incluye `Something broke` / `Something went wrong` (en) y `Что-то сломалось...` (ru). Para nuevos idiomas, basta con añadir esta lista al archivo de locale correspondiente.
Si el título de la ventana de tu lanzador es diferente, puedes establecer explícitamente `CrashWindowTitlePatterns` en `[Profile:<nombre>]` y ejecutar con `-Profile <nombre>`.

## Parámetros principales de inicio

```bash
.\run.ps1 -Help          # Ayuda breve
.\run.ps1 -HelpFull      # Ayuda técnica completa
```

| Parámetro | Descripción |
|-----------|-------------|
| `-LauncherExePath <ruta>` | Ruta al lanzador (si no se especifica en la configuración) |
| `-NoLegacy` | No guardar mods aislados, eliminarlos |
| `-GameLegacy` | Mantener copias de los mods aislados en la carpeta del juego |
| `-DryRun` | Mostrar lo que se hará sin ejecutarlo realmente |
| `-Verbose` | Registros detallados (en consola y en `MCCC.log`) |
| `-UseLinearIsolation` | Búsqueda lineal en lugar de binaria (más lento pero más sencillo) |
| `-NoCache` | Desactivar caché de sesión (volver a verificar configuraciones previas exitosas) |
| `-ThoroughStabilityCheck` | Aumentar el tiempo de comprobación de estabilidad de los inicios |
| `-AutoHandleFabricDialog <bool>` | Gestión automática de diálogos de Fabric sin dependencias faltantes |
| `-IgnoreModIds <id1,id2,...>` | Ignorar los IDs de mods especificados en la limpieza de compatibilidad |
| `-Profile <nombre>` | Aplicar perfil de `[Profile:<nombre>]` en `config.ini` / `config.local.ini` |

## Verificación de scripts y localizaciones

`checker.ps1` verifica:
- Scripts de PowerShell mediante `PSScriptAnalyzer`
- Activos de localización mediante `tools/Check-Localization.py`
- Las cadenas `Write-Verbose`/solo depuración se consideran de servicio, permanecen en inglés y no se incluyen en la cobertura de localización.

Ejemplos:
```powershell
.\checker.ps1             # Verificación completa (incluyendo locales)
.\checker.ps1 -NoLocales  # Omitir verificación de locales
```

Comportamiento si falta Python:
- Por defecto es un **error** (el verificador termina con código de error) para no pasar por alto un fallo en el sistema de localización.
- Si no trabajas con localizaciones, utiliza `-NoLocales`.

## Estructura del proyecto

```
├── run.ps1                  # Punto de entrada
├── config.ini               # Configuración predeterminada
├── checker.ps1              # Linter + verificación de localizaciones
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Orquestador: inicio, monitoreo, ciclo
│   ├── Check-Mod-Compatibility.ps1      # Análisis Básico
│   ├── Analyze-MixinErrors.ps1          # Análisis de Mixin
│   ├── Layer-Mods.ps1                   # Capas
│   ├── Isolate-Incompatible-Mod.ps1     # Aislamiento (alternativa)
│   ├── Recover-PhantomCulprits.ps1      # Recuperación
│   └── Shared-*.ps1                     # Módulos compartidos
├── tools/
│   ├── Analyze-JarDependencies.ps1      # Análisis de dependencias dentro de los archivos JAR de los mods
│   ├── Analyze-JarDependencyMap.ps1     # Construcción de mapa de dependencias completo e informes
│   ├── Check-Localization.py            # Validación de activos de localización
│   ├── Count-ModMinecraftVersions.py    # Conteo de mods por versión de Minecraft
│   ├── Find-SuspiciousDuplicateMods.py  # Búsqueda de duplicados sospechosos de mods
│   └── Restore-ModsFromLog.ps1          # Restauración de mods desde el registro de aislamiento
└── doc/
    └── Algorithm.md                     # Descripción detallada del algoritmo
```

## Dónde van los mods aislados

Por defecto, los mods aislados se mueven a la carpeta `Legacy` dentro de `StorageModsDir` (o `GameModsDir` si no se ha definido el almacenamiento). Esto permite restaurarlos manualmente con facilidad si el resultado del diagnóstico no te convence.

El parámetro `-NoLegacy` elimina los mods permanentemente. El parámetro `-GameLegacy` guarda además una copia en la carpeta del juego.

## Informe final (Summary)

Al finalizar, el script muestra un informe: tiempo de ejecución, lista de culpables por etapas, mods restaurados (si se usó Recuperación) y la lista actual de mods aislados.

## Limitaciones

- Solo funciona con Legacy Launcher (la automatización de la interfaz está ligada a él)
- Solo Windows (Win32 API para la gestión de ventanas)
- El diagnóstico requiere múltiples inicios del juego; en colecciones grandes esto puede llevar mucho tiempo
- Con grandes grupos de incompatibilidades, es posible que haya ejecuciones inestables o paradas prematuras del diagnóstico
- La etapa de Recuperación es experimental y está desactivada por defecto

## Soporte

Si te gusta este proyecto, puedes apoyar al autor en [Sponsr](https://sponsr.ru/artemonim/).
