# * Скрипт для поиска зависимостей внутри JAR-файлов Minecraft модов (Fabric/Forge)
# * Использует прямое чтение ZIP-архивов для высокой производительности.

param(
    [Parameter(Mandatory = $true, HelpMessage = "Часть имени или ID зависимости для поиска (например, 'owo')")]
    [string]$SearchTerm,

    [Parameter(Mandatory = $false)]
    [string]$ScanPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$Recurse,

    [Parameter(Mandatory = $false)]
    [switch]$NoRecurse
)

# * Подключаем библиотеку для работы с архивами
Add-Type -AssemblyName System.IO.Compression.FileSystem

$results = @()
$searchPattern = "*{0}*" -f $SearchTerm
$scanRecursively = $true
if ($PSBoundParameters.ContainsKey("Recurse")) {
    $scanRecursively = [bool]$Recurse
}
if ($NoRecurse) {
    $scanRecursively = $false
}

Write-Host ("[*] Сканирование: {0}" -f $ScanPath) -ForegroundColor Cyan
Write-Host ("[*] Поиск зависимости: '{0}'" -f $SearchTerm) -ForegroundColor Cyan

$jarFiles = Get-ChildItem -Path $ScanPath -Filter "*.jar" -Recurse:$scanRecursively

foreach ($jarFile in $jarFiles) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)

        # ? 1. Проверка Fabric (fabric.mod.json)
        $fabricEntry = $zip.Entries | Where-Object { $_.FullName -eq "fabric.mod.json" }
        if ($fabricEntry) {
            $stream = $fabricEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()

            $modJson = $content | ConvertFrom-Json
            $foundDeps = @()

            # ! Проверяем все возможные блоки зависимостей в Fabric
            $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
            foreach ($block in $depBlocks) {
                if ($modJson.PSObject.Properties.Name -contains $block) {
                    foreach ($prop in $modJson.$block.PSObject.Properties) {
                        if ($prop.Name -like $searchPattern) {
                            $foundDeps += "{0}: {1} ({2})" -f $prop.Name, $prop.Value, $block
                        }
                    }
                }
            }

            if ($foundDeps.Count -gt 0) {
                $results += [PSCustomObject]@{
                    ModName      = $modJson.name
                    JarName      = $jarFile.Name
                    Version      = $modJson.version
                    Dependencies = $foundDeps -join "; "
                    Type         = "Fabric"
                    Path         = $jarFile.FullName
                }
            }
        }

        # ? 2. Проверка Forge (META-INF/mods.toml)
        if (-not $fabricEntry) {
            $tomlEntry = $zip.Entries | Where-Object { $_.FullName -eq "META-INF/mods.toml" }
            if ($tomlEntry) {
                $stream = $tomlEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()

                if ($content -like $searchPattern) {
                    $results += [PSCustomObject]@{
                        ModName      = "Forge Mod (ID unknown)"
                        JarName      = $jarFile.Name
                        Version      = "Unknown"
                        Dependencies = "Found '{0}' in mods.toml" -f $SearchTerm
                        Type         = "Forge"
                        Path         = $jarFile.FullName
                    }
                }
            }
        }

        $zip.Dispose()

    } catch {
        if ($zip) { $zip.Dispose() }
        # ! Игнорируем ошибки доступа или поврежденные архивы, если нужно
        # Write-Warning ("Ошибка при обработке {0}: {1}" -f $jarFile.Name, $_.Exception.Message)
    }
}

# * Вывод результатов
if ($results.Count -gt 0) {
    Write-Host ("`n[+] Найдено совпадений: {0}" -f $results.Count) -ForegroundColor Green
    foreach ($result in $results) {
        Write-Host ("`nМод: {0} ({1})" -f $result.ModName, $result.Type) -ForegroundColor Yellow
        Write-Host ("JAR:     {0}" -f $result.JarName)
        Write-Host ("Версия:  {0}" -f $result.Version)
        Write-Host ("Связи:   {0}" -f $result.Dependencies)
        Write-Host ("Путь:    {0}" -f $result.Path)
    }
} else {
    Write-Host "`n[-] Совпадений не найдено." -ForegroundColor Red
}
