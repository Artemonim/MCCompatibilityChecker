"""Canonical jar metadata extraction shared by tools scripts."""

from __future__ import annotations

import json
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

_MODS_HEADER_RE = re.compile(r"^\s*\[\[\s*mods\s*\]\]\s*$", flags=re.IGNORECASE)
_DEPS_HEADER_RE = re.compile(r"^\s*\[\[\s*dependencies\.([^\]]+)\s*\]\]\s*$", flags=re.IGNORECASE)
_QUOTED_KV_RE = re.compile(r'^\s*([A-Za-z0-9_.-]+)\s*=\s*["\'](.*?)["\']\s*$')
_BOOL_KV_RE = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*=\s*(true|false)\s*$", flags=re.IGNORECASE)


@dataclass
class DependencyMetadata:
    """Canonical dependency contract."""

    mod_id: str = ""
    version_range: str = ""
    kind: str = ""
    is_required: Optional[bool] = None
    side: str = ""
    ordering: str = ""
    owner_mod_id: str = ""

    def to_dict(self) -> dict[str, object]:
        """Returns PascalCase dict compatible with PowerShell metadata keys."""
        return {
            "ModId": self.mod_id,
            "VersionRange": self.version_range,
            "Kind": self.kind,
            "IsRequired": self.is_required,
            "Side": self.side,
            "Ordering": self.ordering,
            "OwnerModId": self.owner_mod_id,
        }


@dataclass
class JarMetadataRecord:
    """Canonical mod metadata contract."""

    mod_id: str = ""
    display_name: str = ""
    version: str = ""
    provided_ids: list[str] = field(default_factory=list)
    dependencies: list[DependencyMetadata] = field(default_factory=list)
    loader: str = ""
    is_fallback_mod_id: bool = False
    is_fallback_display_name: bool = False

    def to_dict(self) -> dict[str, object]:
        """Returns PascalCase dict compatible with PowerShell metadata keys."""
        return {
            "ModId": self.mod_id,
            "DisplayName": self.display_name,
            "Version": self.version,
            "ProvidedIds": list(self.provided_ids),
            "Dependencies": [item.to_dict() for item in self.dependencies],
            "Loader": self.loader,
        }


@dataclass
class JarMetadataResult:
    """Container for parsed metadata from one jar."""

    loader: str = ""
    records: list[JarMetadataRecord] = field(default_factory=list)
    dependency_records: list[DependencyMetadata] = field(default_factory=list)
    jar_provided_ids: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        """Returns PascalCase dict compatible with PowerShell metadata keys."""
        return {
            "Loader": self.loader,
            "Records": [record.to_dict() for record in self.records],
            "DependencyRecords": [dep.to_dict() for dep in self.dependency_records],
            "JarProvidedIds": list(self.jar_provided_ids),
        }


def _normalize_entry_name(entry_name: str) -> str:
    return entry_name.replace("\\", "/").lower()


def _find_entry_name(archive: zipfile.ZipFile, entry_name: str) -> Optional[str]:
    target = _normalize_entry_name(entry_name)
    for name in archive.namelist():
        if _normalize_entry_name(name) == target:
            return name
    return None


def read_text_entry(archive: zipfile.ZipFile, entry_name: str) -> str:
    """Reads and decodes a text entry from a jar archive."""
    actual_name = _find_entry_name(archive, entry_name)
    if actual_name is None:
        return ""
    return archive.read(actual_name).decode("utf-8", errors="ignore")


def read_json_entry(archive: zipfile.ZipFile, entry_name: str) -> Any:
    """Reads and parses JSON entry content."""
    text = read_text_entry(archive, entry_name)
    if not text.strip():
        return None
    return json.loads(text)


def _get_value(container: Any, key: str) -> Any:
    if container is None:
        return None
    if isinstance(container, dict):
        for entry_key, value in container.items():
            if str(entry_key).lower() == key.lower():
                return value
        return None
    return getattr(container, key, None)


def _get_string(container: Any, key: str) -> str:
    value = _get_value(container, key)
    if value is None:
        return ""
    return str(value).strip()


def _dedupe_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        text = str(value).strip()
        if not text:
            continue
        lowered = text.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        result.append(text)
    return result


def _as_version_range(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return ",".join(str(item) for item in value if str(item).strip())
    return str(value)


def collect_provided_ids(provides_value: Any) -> list[str]:
    """Normalizes 'provides' field variants to a flat id list."""
    if provides_value is None:
        return []
    provided: list[str] = []

    if isinstance(provides_value, str):
        provided.append(provides_value)
    elif isinstance(provides_value, dict):
        for key in provides_value.keys():
            provided.append(str(key))
    elif isinstance(provides_value, list):
        for item in provides_value:
            if isinstance(item, str):
                provided.append(item)
            elif isinstance(item, dict):
                item_id = _get_string(item, "id")
                if item_id:
                    provided.append(item_id)
    else:
        for key in getattr(provides_value, "keys", lambda: [])():
            provided.append(str(key))

    return _dedupe_strings(provided)


def parse_fabric_dependencies(mod_json: dict[str, Any], owner_mod_id: str) -> list[DependencyMetadata]:
    """Parses Fabric dependency blocks into canonical dependency records."""
    dep_blocks = ("depends", "suggests", "recommends", "breaks", "conflicts")
    result: list[DependencyMetadata] = []

    for block in dep_blocks:
        value = _get_value(mod_json, block)
        if value is None:
            continue

        if isinstance(value, dict):
            for dep_id, dep_value in value.items():
                dep = DependencyMetadata(
                    mod_id=str(dep_id).strip(),
                    version_range=_as_version_range(dep_value),
                    kind=block,
                    is_required=(block == "depends"),
                    owner_mod_id=owner_mod_id,
                )
                if dep.mod_id:
                    result.append(dep)
            continue

        if isinstance(value, list):
            for item in value:
                if isinstance(item, str):
                    dep = DependencyMetadata(
                        mod_id=item.strip(),
                        version_range="",
                        kind=block,
                        is_required=(block == "depends"),
                        owner_mod_id=owner_mod_id,
                    )
                    if dep.mod_id:
                        result.append(dep)
                    continue

                if isinstance(item, dict):
                    dep_id = _get_string(item, "id") or _get_string(item, "modId")
                    dep_range = _as_version_range(_get_value(item, "version"))
                    if not dep_range:
                        dep_range = _as_version_range(_get_value(item, "versions"))
                    dep = DependencyMetadata(
                        mod_id=dep_id,
                        version_range=dep_range,
                        kind=block,
                        is_required=(block == "depends"),
                        owner_mod_id=owner_mod_id,
                    )
                    if dep.mod_id:
                        result.append(dep)
            continue

        if isinstance(value, str):
            dep = DependencyMetadata(
                mod_id=value.strip(),
                version_range="",
                kind=block,
                is_required=(block == "depends"),
                owner_mod_id=owner_mod_id,
            )
            if dep.mod_id:
                result.append(dep)

    return result


def parse_quilt_dependencies(loader: dict[str, Any], owner_mod_id: str) -> list[DependencyMetadata]:
    """Parses Quilt dependency blocks into canonical dependency records."""
    dep_blocks = ("depends", "suggests", "recommends", "breaks", "conflicts")
    result: list[DependencyMetadata] = []

    for block in dep_blocks:
        value = _get_value(loader, block)
        if value is None:
            continue

        if isinstance(value, dict):
            for dep_id, dep_value in value.items():
                dep = DependencyMetadata(
                    mod_id=str(dep_id).strip(),
                    version_range=_as_version_range(dep_value),
                    kind=block,
                    is_required=(block == "depends"),
                    owner_mod_id=owner_mod_id,
                )
                if dep.mod_id:
                    result.append(dep)
            continue

        if isinstance(value, list):
            for item in value:
                if isinstance(item, str):
                    dep = DependencyMetadata(
                        mod_id=item.strip(),
                        version_range="",
                        kind=block,
                        is_required=(block == "depends"),
                        owner_mod_id=owner_mod_id,
                    )
                    if dep.mod_id:
                        result.append(dep)
                    continue

                if isinstance(item, dict):
                    dep_id = _get_string(item, "id") or _get_string(item, "modId")
                    dep_range = _as_version_range(_get_value(item, "versions"))
                    if not dep_range:
                        dep_range = _as_version_range(_get_value(item, "version"))
                    dep = DependencyMetadata(
                        mod_id=dep_id,
                        version_range=dep_range,
                        kind=block,
                        is_required=(block == "depends"),
                        owner_mod_id=owner_mod_id,
                    )
                    if dep.mod_id:
                        result.append(dep)
            continue

        if isinstance(value, str):
            dep = DependencyMetadata(
                mod_id=value.strip(),
                version_range="",
                kind=block,
                is_required=(block == "depends"),
                owner_mod_id=owner_mod_id,
            )
            if dep.mod_id:
                result.append(dep)

    return result


def parse_forge_toml(toml_text: str) -> tuple[list[dict[str, str]], list[DependencyMetadata]]:
    """Parses mods.toml/neoforge.mods.toml into canonical mod/dependency records."""
    mods: list[dict[str, str]] = []
    deps: list[DependencyMetadata] = []
    current_section = ""
    current_mod: Optional[dict[str, str]] = None
    current_dep: Optional[DependencyMetadata] = None

    for line in toml_text.splitlines():
        if _MODS_HEADER_RE.match(line):
            if current_mod is not None:
                mods.append(current_mod)
            current_mod = {"ModId": "", "DisplayName": "", "Version": ""}
            current_section = "mods"
            continue

        dep_match = _DEPS_HEADER_RE.match(line)
        if dep_match:
            if current_dep is not None:
                deps.append(current_dep)
            current_dep = DependencyMetadata(
                mod_id="",
                version_range="",
                kind="dependency",
                is_required=None,
                side="",
                ordering="",
                owner_mod_id=str(dep_match.group(1)).strip(),
            )
            current_section = "dependencies"
            continue

        if current_section == "mods" and current_mod is not None:
            kv_match = _QUOTED_KV_RE.match(line)
            if not kv_match:
                continue
            key = kv_match.group(1).strip().lower()
            value = kv_match.group(2).strip()
            if key == "modid":
                current_mod["ModId"] = value
            elif key == "displayname":
                current_mod["DisplayName"] = value
            elif key == "version":
                current_mod["Version"] = value
            continue

        if current_section == "dependencies" and current_dep is not None:
            kv_match = _QUOTED_KV_RE.match(line)
            if kv_match:
                key = kv_match.group(1).strip().lower()
                value = kv_match.group(2).strip()
                if key == "modid":
                    current_dep.mod_id = value
                elif key == "versionrange":
                    current_dep.version_range = value
                elif key == "side":
                    current_dep.side = value
                elif key == "ordering":
                    current_dep.ordering = value
                continue

            bool_match = _BOOL_KV_RE.match(line)
            if bool_match and bool_match.group(1).strip().lower() == "mandatory":
                current_dep.is_required = bool_match.group(2).strip().lower() == "true"

    if current_mod is not None:
        mods.append(current_mod)
    if current_dep is not None:
        deps.append(current_dep)
    return mods, deps


def parse_mcmod_records(mcmod_text: str, fallback_mod_id: str) -> list[JarMetadataRecord]:
    """Parses legacy mcmod.info content into canonical records."""
    try:
        data = json.loads(mcmod_text)
    except json.JSONDecodeError:
        return []

    items = data if isinstance(data, list) else [data]
    result: list[JarMetadataRecord] = []
    for item in items:
        if not isinstance(item, dict):
            continue

        raw_mod_id = _get_string(item, "modid") or _get_string(item, "id")
        mod_id = raw_mod_id or fallback_mod_id
        is_fallback_mod_id = not bool(raw_mod_id)

        raw_display_name = _get_string(item, "name")
        display_name = raw_display_name or mod_id
        is_fallback_display_name = not bool(raw_display_name)

        version = _get_string(item, "version") or "Unknown"
        provided_ids = _dedupe_strings([mod_id] if mod_id else [])
        dependencies: list[DependencyMetadata] = []

        accepted = _get_string(item, "acceptedMinecraftVersions") or _get_string(item, "mcversion")
        if accepted:
            dependencies.append(
                DependencyMetadata(
                    mod_id="minecraft",
                    version_range=accepted,
                    kind="depends",
                    is_required=True,
                    owner_mod_id=mod_id,
                )
            )

        result.append(
            JarMetadataRecord(
                mod_id=mod_id,
                display_name=display_name,
                version=version,
                provided_ids=provided_ids,
                dependencies=dependencies,
                loader="Legacy",
                is_fallback_mod_id=is_fallback_mod_id,
                is_fallback_display_name=is_fallback_display_name,
            )
        )

    return result


def extract_jar_metadata_from_archive(
    archive: zipfile.ZipFile,
    jar_path: Optional[Path] = None,
    throw_on_parse_error: bool = False,
) -> Optional[JarMetadataResult]:
    """Extracts canonical metadata from an already opened archive."""
    fallback_mod_id = jar_path.stem if jar_path else ""

    fabric_entry = _find_entry_name(archive, "fabric.mod.json")
    if fabric_entry is not None:
        try:
            mod_json = read_json_entry(archive, "fabric.mod.json")
        except json.JSONDecodeError:
            if throw_on_parse_error:
                raise
            return None
        if not isinstance(mod_json, dict):
            return None

        raw_mod_id = _get_string(mod_json, "id")
        mod_id = raw_mod_id or fallback_mod_id
        is_fallback_mod_id = not bool(raw_mod_id)

        raw_display_name = _get_string(mod_json, "name")
        display_name = raw_display_name or mod_id
        is_fallback_display_name = not bool(raw_display_name)

        version = _get_string(mod_json, "version") or "Unknown"
        provided_ids = _dedupe_strings([mod_id, *collect_provided_ids(_get_value(mod_json, "provides"))])
        dependencies = parse_fabric_dependencies(mod_json, owner_mod_id=mod_id)

        record = JarMetadataRecord(
            mod_id=mod_id,
            display_name=display_name,
            version=version,
            provided_ids=provided_ids,
            dependencies=dependencies,
            loader="Fabric",
            is_fallback_mod_id=is_fallback_mod_id,
            is_fallback_display_name=is_fallback_display_name,
        )
        return JarMetadataResult(
            loader="Fabric",
            records=[record],
            dependency_records=list(dependencies),
            jar_provided_ids=list(provided_ids),
        )

    quilt_entry = _find_entry_name(archive, "quilt.mod.json")
    if quilt_entry is not None:
        try:
            mod_json = read_json_entry(archive, "quilt.mod.json")
        except json.JSONDecodeError:
            if throw_on_parse_error:
                raise
            return None
        if not isinstance(mod_json, dict):
            return None

        loader = _get_value(mod_json, "quilt_loader")
        if not isinstance(loader, dict):
            return None

        raw_mod_id = _get_string(loader, "id")
        mod_id = raw_mod_id or fallback_mod_id
        is_fallback_mod_id = not bool(raw_mod_id)

        raw_display_name = ""
        loader_metadata = _get_value(loader, "metadata")
        if isinstance(loader_metadata, dict):
            raw_display_name = _get_string(loader_metadata, "name")
        if not raw_display_name:
            root_metadata = _get_value(mod_json, "metadata")
            if isinstance(root_metadata, dict):
                raw_display_name = _get_string(root_metadata, "name")
        display_name = raw_display_name or mod_id
        is_fallback_display_name = not bool(raw_display_name)

        version = _get_string(loader, "version") or "Unknown"
        provided_ids = _dedupe_strings([mod_id, *collect_provided_ids(_get_value(loader, "provides"))])
        dependencies = parse_quilt_dependencies(loader, owner_mod_id=mod_id)

        record = JarMetadataRecord(
            mod_id=mod_id,
            display_name=display_name,
            version=version,
            provided_ids=provided_ids,
            dependencies=dependencies,
            loader="Quilt",
            is_fallback_mod_id=is_fallback_mod_id,
            is_fallback_display_name=is_fallback_display_name,
        )
        return JarMetadataResult(
            loader="Quilt",
            records=[record],
            dependency_records=list(dependencies),
            jar_provided_ids=list(provided_ids),
        )

    toml_text = read_text_entry(archive, "META-INF/mods.toml")
    loader_name = "Forge"
    if not toml_text:
        toml_text = read_text_entry(archive, "META-INF/neoforge.mods.toml")
        if toml_text:
            loader_name = "NeoForge"

    if toml_text:
        mods, dependencies = parse_forge_toml(toml_text)
        jar_provided_ids = _dedupe_strings([item.get("ModId", "") for item in mods if item.get("ModId", "").strip()])
        record_provided = list(jar_provided_ids) if jar_provided_ids else ([fallback_mod_id] if fallback_mod_id else [])

        records: list[JarMetadataRecord] = []
        for mod in mods:
            raw_mod_id = str(mod.get("ModId", "")).strip()
            mod_id = raw_mod_id or fallback_mod_id
            is_fallback_mod_id = not bool(raw_mod_id)

            raw_display_name = str(mod.get("DisplayName", "")).strip()
            display_name = raw_display_name or mod_id
            is_fallback_display_name = not bool(raw_display_name)

            version = str(mod.get("Version", "")).strip() or "Unknown"
            record_dependencies: list[DependencyMetadata] = []
            for dep in dependencies:
                owner = dep.owner_mod_id.strip()
                owner_matches = owner.lower() == mod_id.lower() if owner else mod_id.lower() == fallback_mod_id.lower()
                if owner_matches:
                    record_dependencies.append(dep)

            records.append(
                JarMetadataRecord(
                    mod_id=mod_id,
                    display_name=display_name,
                    version=version,
                    provided_ids=list(record_provided),
                    dependencies=record_dependencies,
                    loader=loader_name,
                    is_fallback_mod_id=is_fallback_mod_id,
                    is_fallback_display_name=is_fallback_display_name,
                )
            )

        return JarMetadataResult(
            loader=loader_name,
            records=records,
            dependency_records=dependencies,
            jar_provided_ids=jar_provided_ids,
        )

    mcmod_text = read_text_entry(archive, "mcmod.info")
    if mcmod_text:
        records = parse_mcmod_records(mcmod_text, fallback_mod_id=fallback_mod_id)
        if not records:
            return None
        dependency_records: list[DependencyMetadata] = []
        jar_provided_ids: list[str] = []
        for record in records:
            dependency_records.extend(record.dependencies)
            jar_provided_ids.extend(record.provided_ids)
        return JarMetadataResult(
            loader="Legacy",
            records=records,
            dependency_records=dependency_records,
            jar_provided_ids=_dedupe_strings(jar_provided_ids),
        )

    return None


def extract_jar_metadata(jar_path: Path, throw_on_parse_error: bool = False) -> Optional[JarMetadataResult]:
    """Extracts canonical metadata from a jar path."""
    try:
        with zipfile.ZipFile(jar_path, "r") as archive:
            return extract_jar_metadata_from_archive(
                archive=archive,
                jar_path=jar_path,
                throw_on_parse_error=throw_on_parse_error,
            )
    except (OSError, zipfile.BadZipFile):
        return None


__all__ = [
    "DependencyMetadata",
    "JarMetadataRecord",
    "JarMetadataResult",
    "extract_jar_metadata",
    "extract_jar_metadata_from_archive",
    "read_text_entry",
    "read_json_entry",
]

