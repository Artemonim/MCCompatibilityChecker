import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

# Localization checker for MCCompatibilityChecker.
# Exit codes:
#   0 - checks passed (warnings may still be present)
#   1 - validation errors
#   2 - runtime/tool error

OUTPUT_COMMANDS_PATTERN = (
    r"(?:Write-Host|Write-Warning|Write-Error|Read-Host|"
    r"Write-McccHost|Write-McccWarning|Write-McccError|Read-McccHost)"
)
STRING_PATTERNS = [
    re.compile(rf"{OUTPUT_COMMANDS_PATTERN}\s+([\"'])(.*?)\1", re.IGNORECASE | re.DOTALL),
    re.compile(rf"{OUTPUT_COMMANDS_PATTERN}\s*\(\s*([\"'])(.*?)\1", re.IGNORECASE | re.DOTALL),
]
PLACEHOLDER_RE = re.compile(r"\{(\d+)\}")
KEY_TAG_RE = re.compile(r"<KEY_[A-Z0-9_]+>")
LOG_PREFIX_RE = re.compile(r"^\s*(\[[*+\-!]\])")

EXCLUDED_DIRS = {
    ".git",
    ".temporary",
    "archive",
    "node_modules",
}


def normalize_locale_tag(value: str) -> str:
    raw = (value or "").strip().replace("_", "-")
    if not raw:
        return ""
    parts = raw.split("-")
    if len(parts) == 1:
        return parts[0].lower()
    return f"{parts[0].lower()}-{parts[1].upper()}"


def extract_localizable_strings(file_path: Path) -> set[str]:
    content = file_path.read_text(encoding="utf-8")
    found_strings: set[str] = set()

    for pattern in STRING_PATTERNS:
        for _, message in pattern.findall(content):
            if message and message.strip():
                found_strings.add(message)

    return found_strings


def decode_powershell_backtick_escapes(value: str) -> str:
    escapes = {
        "0": "\0",
        "a": "\a",
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "v": "\v",
        "`": "`",
        '"': '"',
        "'": "'",
    }

    def repl(match: re.Match) -> str:
        key = match.group(1)
        return escapes.get(key, key)

    return re.sub(r"`(.)", repl, value)


def discover_source_strings(root_dir: Path) -> dict[str, set[str]]:
    source_map: dict[str, set[str]] = {}

    for path in root_dir.rglob("*.ps1"):
        rel_parts = {part.lower() for part in path.relative_to(root_dir).parts}
        if rel_parts & EXCLUDED_DIRS:
            continue

        rel_path = path.relative_to(root_dir).as_posix()
        for item in extract_localizable_strings(path):
            normalized = decode_powershell_backtick_escapes(item)
            source_map.setdefault(normalized, set()).add(rel_path)

    return source_map


def find_powershell_executable() -> str:
    for cmd in ("pwsh", "powershell"):
        resolved = shutil.which(cmd)
        if resolved:
            return resolved
    raise RuntimeError("PowerShell executable not found (tried: pwsh, powershell)")


def parse_locale_file(locale_path: Path, powershell_exe: str) -> dict:
    ps_path = str(locale_path).replace("'", "''")
    command = f"""
$ErrorActionPreference = 'Stop'
$data = Import-PowerShellDataFile -LiteralPath '{ps_path}'

$templates = @{{}}
if ($null -ne $data -and $data.ContainsKey('Templates') -and $null -ne $data.Templates) {{
  foreach ($k in $data.Templates.Keys) {{
    $templates[[string]$k] = [string]$data.Templates[$k]
  }}
}}

$substrings = @{{}}
if ($null -ne $data -and $data.ContainsKey('Substrings') -and $null -ne $data.Substrings) {{
  foreach ($k in $data.Substrings.Keys) {{
    $substrings[[string]$k] = [string]$data.Substrings[$k]
  }}
}}

$locale = ''
if ($null -ne $data -and $data.ContainsKey('Locale') -and $null -ne $data.Locale) {{
  $locale = [string]$data.Locale
}}

[ordered]@{{
  Locale = $locale
  Templates = $templates
  Substrings = $substrings
}} | ConvertTo-Json -Depth 8 -Compress
"""

    result = subprocess.run(
        [powershell_exe, "-NoProfile", "-Command", command],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"Failed to parse {locale_path}: {details}")

    try:
        parsed = json.loads((result.stdout or "").strip())
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON from locale parser for {locale_path}: {exc}") from exc

    templates = parsed.get("Templates", {}) or {}
    substrings = parsed.get("Substrings", {}) or {}
    return {
        "locale": str(parsed.get("Locale", "") or ""),
        "templates": {str(k): str(v) for k, v in templates.items()},
        "substrings": {str(k): str(v) for k, v in substrings.items()},
    }


def collect_placeholders(value: str) -> set[int]:
    return {int(match.group(1)) for match in PLACEHOLDER_RE.finditer(value or "")}


def collect_key_tags(value: str) -> set[str]:
    return set(KEY_TAG_RE.findall(value or ""))


def detect_log_prefix(value: str) -> str:
    match = LOG_PREFIX_RE.search(value or "")
    return match.group(1) if match else ""


def format_locations(source_map: dict[str, set[str]], key: str) -> str:
    files = sorted(source_map.get(key, []))
    if not files:
        return "<unknown>"
    preview = files[:3]
    suffix = f" (+{len(files) - len(preview)} more)" if len(files) > len(preview) else ""
    return f"{', '.join(preview)}{suffix}"


def validate_locale(
    locale_name: str,
    locale_data: dict,
    source_strings: set[str],
    source_map: dict[str, set[str]],
    strict_missing: bool,
) -> tuple[list[str], list[str], dict]:
    errors: list[str] = []
    warnings: list[str] = []

    templates: dict[str, str] = locale_data.get("templates", {})
    substrings: dict[str, str] = locale_data.get("substrings", {})

    translated = 0
    empty_entries = 0
    missing_entries = 0
    for src in source_strings:
        if src not in templates:
            missing_entries += 1
            continue
        value = templates.get(src, "")
        if value == "":
            empty_entries += 1
            continue
        translated += 1

    # Empty and missing values are allowed by design (fallback to source English).
    if strict_missing and locale_name.lower() != "en":
        unresolved = missing_entries + empty_entries
        if unresolved > 0:
            errors.append(
                f"[{locale_name}] Strict mode: {unresolved} untranslated source strings "
                f"(missing={missing_entries}, empty={empty_entries})."
            )

    for source_key, target_value in templates.items():
        if source_key.strip() == "":
            errors.append(f"[{locale_name}] Empty template key is not allowed.")
            continue
        if target_value == "":
            continue

        src_placeholders = collect_placeholders(source_key)
        dst_placeholders = collect_placeholders(target_value)
        if src_placeholders != dst_placeholders:
            errors.append(
                f"[{locale_name}] Placeholder mismatch for template key: {source_key!r} "
                f"(src={sorted(src_placeholders)}, dst={sorted(dst_placeholders)})"
            )

        src_tags = collect_key_tags(source_key)
        dst_tags = collect_key_tags(target_value)
        if src_tags != dst_tags:
            errors.append(
                f"[{locale_name}] Technical key-tag mismatch for template key: {source_key!r} "
                f"(src={sorted(src_tags)}, dst={sorted(dst_tags)})"
            )

        src_prefix = detect_log_prefix(source_key)
        dst_prefix = detect_log_prefix(target_value)
        if src_prefix and src_prefix != dst_prefix:
            warnings.append(
                f"[{locale_name}] Log prefix changed from {src_prefix!r} to {dst_prefix!r} "
                f"for template key: {source_key!r}"
            )

    for source_key, target_value in substrings.items():
        if source_key.strip() == "":
            errors.append(f"[{locale_name}] Empty substring key is not allowed.")
            continue
        if target_value == "":
            continue

        src_placeholders = collect_placeholders(source_key)
        dst_placeholders = collect_placeholders(target_value)
        if src_placeholders != dst_placeholders:
            errors.append(
                f"[{locale_name}] Placeholder mismatch for substring key: {source_key!r} "
                f"(src={sorted(src_placeholders)}, dst={sorted(dst_placeholders)})"
            )

    stale_template_keys = sorted(k for k in templates.keys() if k not in source_strings)
    if stale_template_keys:
        sample = stale_template_keys[:10]
        sample_joined = "; ".join(repr(item) for item in sample)
        suffix = f" (+{len(stale_template_keys) - len(sample)} more)" if len(stale_template_keys) > len(sample) else ""
        warnings.append(
            f"[{locale_name}] Template keys not found in current source: {sample_joined}{suffix}"
        )

    sample_missing = sorted(source_strings - set(templates.keys()))[:10]
    missing_samples = []
    for key in sample_missing:
        missing_samples.append(f"{key!r} @ {format_locations(source_map, key)}")

    metrics = {
        "source_total": len(source_strings),
        "templates_total": len(templates),
        "substrings_total": len(substrings),
        "translated": translated,
        "empty": empty_entries,
        "missing": missing_entries,
        "coverage": (translated / len(source_strings)) if source_strings else 1.0,
        "missing_samples": missing_samples,
    }

    return errors, warnings, metrics


def print_messages(title: str, messages: list[str], max_items: int = 50) -> None:
    if not messages:
        return
    print(f"{title} ({len(messages)}):")
    for item in messages[:max_items]:
        print(f"  - {item}")
    if len(messages) > max_items:
        print(f"  - ... (+{len(messages) - max_items} more)")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate localization assets for MCCompatibilityChecker.")
    parser.add_argument(
        "--strict-missing",
        action="store_true",
        help="Treat missing/empty template translations as validation errors for non-English locales.",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent
    locale_dir = root_dir / "scripts" / "locales"
    if not locale_dir.exists():
        print(f"[ERROR] Locale directory not found: {locale_dir}")
        return 2

    source_map = discover_source_strings(root_dir)
    source_strings = set(source_map.keys())
    print(f"[INFO] Source strings discovered: {len(source_strings)}")

    locale_files = sorted(locale_dir.glob("*.psd1"))
    if not locale_files:
        print(f"[ERROR] No locale files found in: {locale_dir}")
        return 2

    try:
        powershell_exe = find_powershell_executable()
    except RuntimeError as exc:
        print(f"[ERROR] {exc}")
        return 2

    all_errors: list[str] = []
    all_warnings: list[str] = []

    for locale_file in locale_files:
        locale_name = locale_file.stem
        try:
            locale_data = parse_locale_file(locale_file, powershell_exe)
        except RuntimeError as exc:
            all_errors.append(str(exc))
            continue

        declared_locale = normalize_locale_tag(locale_data.get("locale", ""))
        file_locale = normalize_locale_tag(locale_name)
        if declared_locale and declared_locale != file_locale:
            all_warnings.append(
                f"[{locale_name}] Declared locale '{locale_data.get('locale', '')}' does not match file name."
            )

        errors, warnings, metrics = validate_locale(
            locale_name=locale_name,
            locale_data=locale_data,
            source_strings=source_strings,
            source_map=source_map,
            strict_missing=args.strict_missing,
        )
        all_errors.extend(errors)
        all_warnings.extend(warnings)

        print(
            f"[LOCALE] {locale_name}: templates={metrics['templates_total']}, "
            f"substrings={metrics['substrings_total']}, translated={metrics['translated']}, "
            f"empty={metrics['empty']}, missing={metrics['missing']}, "
            f"coverage={metrics['coverage'] * 100:.1f}%"
        )
        if metrics["missing_samples"] and metrics["templates_total"] > 0:
            print("  Missing template samples:")
            for sample in metrics["missing_samples"][:5]:
                print(f"    - {sample}")

    print_messages("[WARN]", all_warnings, max_items=40)
    print_messages("[ERROR]", all_errors, max_items=200)

    if all_errors:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("[ERROR] Interrupted.")
        raise SystemExit(2)
