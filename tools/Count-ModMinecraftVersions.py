import argparse
import json
import re
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

VERSION_RE = re.compile(r"\d+(?:\.\d+){0,2}")
WILDCARD_RE = re.compile(r"^(\d+)\.(\d+)\.[xX\*]$")
MOD_FILENAME_HINT_PATTERNS = [
    re.compile(r"(?:^|[-_.+])mc(?:inecraft)?[-_.+]?(?P<ver>1\.\d+(?:\.\d+)?(?:[xX\*])?)(?:$|[-_.+])"),
    re.compile(r"(?:^|[-_.+])(?P<ver>1\.\d+(?:\.\d+)?(?:[xX\*])?)[-_.+]?(?:mc|minecraft)(?:$|[-_.+])"),
    re.compile(r"(?:^|[-_.+])(?:fabric|forge|neoforge|quilt|nf)[-_.+]?(?P<ver>1\.\d+(?:\.\d+)?(?:[xX\*])?)(?:$|[-_.+])"),
    re.compile(r"(?:^|[-_.+])(?P<ver>1\.\d+(?:\.\d+)?(?:[xX\*])?)[-_.+]?(?:fabric|forge|neoforge|quilt|nf)(?:$|[-_.+])"),
]

KNOWN_RELEASES = [
    "1.16",
    "1.16.1",
    "1.16.2",
    "1.16.3",
    "1.16.4",
    "1.16.5",
    "1.17",
    "1.17.1",
    "1.18",
    "1.18.1",
    "1.18.2",
    "1.19",
    "1.19.1",
    "1.19.2",
    "1.19.3",
    "1.19.4",
    "1.20",
    "1.20.1",
    "1.20.2",
    "1.20.3",
    "1.20.4",
    "1.21",
    "1.21.1",
]

KNOWN_VERSION_TUPLES: List[Tuple[int, int, int]] = []


def version_tuple_from_string(raw: str) -> Tuple[int, int, int]:
    """Converts a version-like string into a (major, minor, patch) tuple."""
    parts = []
    for token in raw.split("."):
        if token.isdigit():
            parts.append(int(token))
        else:
            digits = re.findall(r"\d+", token)
            if digits:
                parts.append(int(digits[0]))
    while len(parts) < 3:
        parts.append(0)
    trimmed = parts[:3]
    return trimmed[0], trimmed[1], trimmed[2]


KNOWN_VERSION_TUPLES = [version_tuple_from_string(v) for v in KNOWN_RELEASES]


def format_version_tuple(value: Tuple[int, int, int]) -> str:
    """Formats a version tuple to a compact string without trailing zeroes."""
    major, minor, patch = value
    components = [major, minor, patch]
    while len(components) > 1 and components[-1] == 0:
        components.pop()
    return ".".join(str(x) for x in components)


def is_range_spec(spec: str) -> bool:
    """Heuristically detects whether a version string denotes a range."""
    if any(marker in spec for marker in ("[", "]", "(", ")", "<", ">", "..")):
        return True
    if re.search(r"\d+\s*-\s*\d+", spec):
        return True
    if re.search(r"\d+\s*to\s*\d+", spec, flags=re.IGNORECASE):
        return True
    return False


def expand_version_range(
    lower: Tuple[int, int, int],
    upper: Tuple[int, int, int],
    known_versions: Sequence[Tuple[int, int, int]],
) -> List[str]:
    """Expands a range into concrete versions using known releases when possible."""
    expanded: List[str] = []
    for version in known_versions:
        if lower <= version <= upper:
            expanded.append(format_version_tuple(version))
    if expanded:
        return expanded

    # * Fall back to patch iteration when the major/minor bounds match.
    if (lower[0], lower[1]) == (upper[0], upper[1]):
        for patch in range(lower[2], upper[2] + 1):
            expanded.append(format_version_tuple((lower[0], lower[1], patch)))
        if expanded:
            return expanded

    # * If expansion is ambiguous, return the endpoints as best-effort coverage.
    unique_endpoints = {format_version_tuple(lower), format_version_tuple(upper)}
    return sorted(unique_endpoints)


def parse_version_spec(spec: str, expand_ranges: bool) -> List[str]:
    """Parses a version requirement string into specific versions."""
    normalized = (spec or "").strip()
    if not normalized or normalized in ("*", "any"):
        return []

    wildcard_match = WILDCARD_RE.match(normalized)
    if wildcard_match:
        major = int(wildcard_match.group(1))
        minor = int(wildcard_match.group(2))
        matches = [
            v for v in KNOWN_VERSION_TUPLES if (v[0], v[1]) == (major, minor)
        ]
        return [format_version_tuple(v) for v in matches] if matches else [f"{major}.{minor}"]

    tokens = VERSION_RE.findall(normalized)
    if not tokens:
        return []

    tuples = sorted(version_tuple_from_string(token) for token in tokens)
    if not expand_ranges:
        return [format_version_tuple(tuples[0])]

    if is_range_spec(normalized) and len(tuples) >= 2:
        return expand_version_range(tuples[0], tuples[-1], KNOWN_VERSION_TUPLES)

    return [format_version_tuple(item) for item in tuples]


def is_plausible_minecraft_version(version: str) -> bool:
    """Applies guardrails for filename-based version inference."""
    major, minor, patch = version_tuple_from_string(version)
    if major != 1:
        return False
    if minor < 6 or minor > 30:
        return False
    if minor >= 20:
        return patch <= 20
    return patch <= 10


def parse_versions_from_filename(jar_path: Path, expand_ranges: bool) -> List[str]:
    """Best-effort extraction of Minecraft versions from a jar filename."""
    stem = jar_path.stem.lower()

    # * First try explicit mc/minecraft markers around version tokens.
    versions: List[str] = []
    for pattern in MOD_FILENAME_HINT_PATTERNS:
        for match in pattern.finditer(stem):
            parsed = parse_version_spec(match.group("ver"), expand_ranges)
            for version in parsed:
                if is_plausible_minecraft_version(version):
                    versions.append(version)
    if versions:
        unique_versions = list(dict.fromkeys(versions))
        modern_versions = [
            v for v in unique_versions if version_tuple_from_string(v)[1] >= 20
        ]
        if modern_versions:
            return [max(modern_versions, key=version_tuple_from_string)]
        if len(unique_versions) > 1:
            return [max(unique_versions, key=version_tuple_from_string)]
        return unique_versions

    # * Secondary fallback: accept modern 1.20+ versions in filename tokens.
    # * This intentionally avoids older minors to reduce false positives with mod versions.
    modern_candidates = re.findall(r"\b1\.\d+(?:\.\d+)?\b", stem)
    modern_versions: List[str] = []
    for candidate in modern_candidates:
        parsed = parse_version_spec(candidate, expand_ranges)
        for version in parsed:
            ver_tuple = version_tuple_from_string(version)
            if is_plausible_minecraft_version(version) and 20 <= ver_tuple[1] <= 30:
                modern_versions.append(version)

    unique_modern = list(dict.fromkeys(modern_versions))
    if len(unique_modern) <= 1:
        return unique_modern

    # * If several modern versions exist in one filename, use the maximal one as best guess.
    best = max(unique_modern, key=version_tuple_from_string)
    return [best]


def parse_dependency_value(value, expand_ranges: bool) -> List[str]:
    """Extracts versions from a dependency declaration field."""
    specs: List[str] = []
    if isinstance(value, str):
        specs.append(value)
    elif isinstance(value, list):
        for entry in value:
            if isinstance(entry, str):
                specs.append(entry)
            elif isinstance(entry, dict) and "version" in entry:
                specs.append(str(entry.get("version", "")).strip())
    elif isinstance(value, dict) and "version" in value:
        specs.append(str(value.get("version", "")).strip())

    versions: List[str] = []
    for spec in specs:
        versions.extend(parse_version_spec(spec, expand_ranges))

    unique_versions = []
    seen = set()
    for version in versions:
        if version not in seen:
            seen.add(version)
            unique_versions.append(version)
    return unique_versions


def extract_from_fabric_mod_json(mod_json: dict, expand_ranges: bool) -> List[str]:
    """Extracts Minecraft versions from fabric.mod.json data."""
    depends = mod_json.get("depends", {})
    if not isinstance(depends, dict):
        return []
    if "minecraft" not in depends:
        return []
    return parse_dependency_value(depends.get("minecraft"), expand_ranges)


def extract_from_quilt_mod_json(mod_json: dict, expand_ranges: bool) -> List[str]:
    """Extracts Minecraft versions from quilt.mod.json data."""
    loader = mod_json.get("quilt_loader")
    if not isinstance(loader, dict):
        return []
    depends = loader.get("depends")
    if isinstance(depends, dict):
        minecraft_value = depends.get("minecraft")
        if minecraft_value is None:
            return []
        return parse_dependency_value(minecraft_value, expand_ranges)
    if not isinstance(depends, list):
        return []

    versions: List[str] = []
    for dep in depends:
        if not isinstance(dep, dict):
            continue
        if str(dep.get("id", "")).lower() != "minecraft":
            continue
        if "versions" in dep:
            versions.extend(parse_dependency_value(dep.get("versions"), expand_ranges))
        elif "version" in dep:
            versions.extend(parse_dependency_value(dep.get("version"), expand_ranges))
    return list(dict.fromkeys(versions))


def extract_from_mods_toml(toml_text: str, expand_ranges: bool) -> List[str]:
    """Extracts Minecraft versions from Forge/NeoForge mods.toml content."""
    dependency_block_re = re.compile(r"^\s*\[\[dependencies\.[^\]]+\]\]")
    key_value_re = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*["\'](.*?)["\']')

    versions: List[str] = []
    current_target = ""
    current_range: Optional[str] = None

    for line in toml_text.splitlines():
        if dependency_block_re.match(line):
            if current_target == "minecraft" and current_range:
                versions.extend(parse_version_spec(current_range, expand_ranges))
            current_target = ""
            current_range = None
            continue

        kv_match = key_value_re.match(line)
        if not kv_match:
            continue
        key = kv_match.group(1).lower()
        value = kv_match.group(2).strip()
        if key == "modid":
            current_target = value.lower()
        elif key == "versionrange":
            current_range = value

    if current_target == "minecraft" and current_range:
        versions.extend(parse_version_spec(current_range, expand_ranges))

    return list(dict.fromkeys(versions))


def extract_from_mcmod_info(info_text: str, expand_ranges: bool) -> List[str]:
    """Extracts Minecraft versions from legacy mcmod.info content."""
    try:
        data = json.loads(info_text)
    except json.JSONDecodeError:
        return []

    items = data if isinstance(data, list) else [data]
    versions: List[str] = []

    for item in items:
        if not isinstance(item, dict):
            continue
        if "acceptedMinecraftVersions" in item:
            versions.extend(
                parse_version_spec(
                    str(item.get("acceptedMinecraftVersions", "")).strip(),
                    expand_ranges,
                )
            )
        elif "mcversion" in item:
            versions.extend(
                parse_version_spec(str(item.get("mcversion", "")).strip(), expand_ranges)
            )
    return list(dict.fromkeys(versions))


def extract_versions_from_jar(jar_path: Path, expand_ranges: bool) -> Set[str]:
    """Reads a jar and extracts Minecraft version targets."""
    found: Set[str] = set()

    try:
        with zipfile.ZipFile(jar_path, "r") as archive:
            if "fabric.mod.json" in archive.namelist():
                try:
                    raw = archive.read("fabric.mod.json").decode("utf-8", errors="ignore")
                    mod_json = json.loads(raw)
                    found.update(extract_from_fabric_mod_json(mod_json, expand_ranges))
                except json.JSONDecodeError:
                    pass

            if "quilt.mod.json" in archive.namelist():
                try:
                    raw = archive.read("quilt.mod.json").decode("utf-8", errors="ignore")
                    mod_json = json.loads(raw)
                    found.update(extract_from_quilt_mod_json(mod_json, expand_ranges))
                except json.JSONDecodeError:
                    pass

            for toml_name in ("META-INF/mods.toml", "META-INF/neoforge.mods.toml"):
                if toml_name in archive.namelist():
                    raw = archive.read(toml_name).decode("utf-8", errors="ignore")
                    found.update(extract_from_mods_toml(raw, expand_ranges))

            if "mcmod.info" in archive.namelist():
                try:
                    raw = archive.read("mcmod.info").decode("utf-8", errors="ignore")
                    found.update(extract_from_mcmod_info(raw, expand_ranges))
                except json.JSONDecodeError:
                    pass
    except (zipfile.BadZipFile, OSError):
        return set()

    if not found:
        found.update(parse_versions_from_filename(jar_path, expand_ranges))

    return found


def iter_mod_files(root: Path, recursive: bool) -> Iterable[Path]:
    """Yields mod jar files from the given directory."""
    if recursive:
        yield from root.rglob("*.jar")
    else:
        yield from root.glob("*.jar")


def sort_version_key(version: str) -> Tuple[int, int, int]:
    """Provides a sortable key for version strings."""
    return version_tuple_from_string(version)


def count_versions(
    mods_dir: Path,
    recursive: bool,
    expand_ranges: bool,
) -> tuple[Counter, Dict[str, List[str]], int, List[str]]:
    """Counts mods per targeted Minecraft version."""
    counter: Counter = Counter()
    mods_by_version: Dict[str, List[str]] = defaultdict(list)
    unknown = 0
    unknown_mods: List[str] = []

    for jar_path in iter_mod_files(mods_dir, recursive):
        versions = extract_versions_from_jar(jar_path, expand_ranges)
        jar_name = jar_path.name
        if versions:
            for version in versions:
                counter[version] += 1
                mods_by_version[version].append(jar_name)
        else:
            unknown += 1
            unknown_mods.append(jar_name)
    return counter, mods_by_version, unknown, unknown_mods


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    """Parses CLI arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Count mods by targeted Minecraft version using mod metadata. "
            "Supports Fabric, Quilt, Forge, and legacy metadata formats."
        )
    )
    parser.add_argument(
        "mods_dir",
        type=Path,
        help="Path to the folder with mod jar files.",
    )
    parser.add_argument(
        "--recursive",
        action="store_true",
        help="Scan subdirectories recursively.",
    )
    parser.add_argument(
        "--expand-ranges",
        action="store_true",
        help=(
            "Expand version ranges to every version inside the bounds when possible. "
            "By default only the minimal version is counted."
        ),
    )
    parser.add_argument(
        "-verbose",
        "--verbose",
        "-v",
        action="store_true",
        help=(
            "Print mod lists under each version. At the end, print compact summary "
            "in default output format."
        ),
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Entrypoint."""
    args = parse_args(argv)
    mods_dir: Path = args.mods_dir.expanduser()
    if not mods_dir.exists():
        print(f"Directory not found: {mods_dir}")
        return 1
    if not mods_dir.is_dir():
        print(f"Path is not a directory: {mods_dir}")
        return 1

    counter, mods_by_version, unknown, unknown_mods = count_versions(
        mods_dir,
        args.recursive,
        args.expand_ranges,
    )
    if not counter and unknown == 0:
        print("No mod jars found.")
        return 0

    if args.verbose:
        for version in sorted(counter.keys(), key=sort_version_key):
            print(f"{version}: {counter[version]} модов")
            for mod_name in sorted(mods_by_version.get(version, []), key=str.lower):
                print(f"  - {mod_name}")
            print("")
        print(f"unknown: {unknown} модов")
        for mod_name in sorted(unknown_mods, key=str.lower):
            print(f"  - {mod_name}")

        print("")
        print("summary:")

    for version in sorted(counter.keys(), key=sort_version_key):
        print(f"{version}: {counter[version]} модов")
    print(f"unknown: {unknown} модов")
    return 0


if __name__ == "__main__":
    sys.exit(main())
