import argparse
import re
import sys
import zipfile
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable, Optional, Sequence

from shared.jar_metadata import extract_jar_metadata_from_archive

# * User-tunable defaults.
DEFAULT_NAME_SIMILARITY_THRESHOLD = 0.88
DEFAULT_TOKEN_JACCARD_THRESHOLD = 0.58
DEFAULT_PACKAGE_SIMILARITY_THRESHOLD = 0.68
DEFAULT_MIN_LABEL_LENGTH = 5

GENERIC_MOD_IDS = {
    "api",
    "common",
    "core",
    "fabric",
    "forge",
    "lib",
    "library",
    "minecraft",
    "mod",
    "mods",
    "neoforge",
    "quilt",
}

GENERIC_TOKENS = {
    "api",
    "common",
    "fabric",
    "forge",
    "library",
    "loader",
    "minecraft",
    "mod",
    "mods",
    "neoforge",
    "quilt",
}

PACKAGE_EXCLUDE_PREFIXES = {
    "assets/",
    "data/",
    "kotlin/",
    "meta-inf/",
    "mozilla/",
    "org/apache/",
    "org/intellij/",
}

SPACES_RE = re.compile(r"\s+")


@dataclass
class ModRecord:
    """Stores extracted identifiers for a mod jar file."""

    file_path: Path
    ids: set[str] = field(default_factory=set)
    names: set[str] = field(default_factory=set)
    package_roots: set[str] = field(default_factory=set)
    fallback_name: str = ""

    def all_labels(self) -> set[str]:
        """Returns candidate labels used for fuzzy comparison."""
        labels = set()
        labels.update(self.ids)
        labels.update(self.names)
        if self.fallback_name:
            labels.add(self.fallback_name)
        return {value for value in labels if value}

    def canonical_labels(self) -> set[str]:
        """Returns canonicalized labels for exact overlap checks."""
        result = set()
        for label in self.all_labels():
            canonical = canonicalize_text(label)
            if not canonical:
                continue
            if is_generic_label(canonical):
                continue
            result.add(canonical)
        return result

    def best_label(self) -> str:
        """Returns a stable representative label for the mod."""
        if self.names:
            return sorted(self.names, key=len, reverse=True)[0]
        if self.ids:
            return sorted(self.ids, key=len, reverse=True)[0]
        return self.fallback_name

    def best_tokens(self) -> set[str]:
        """Returns normalized tokens for fuzzy similarity checks."""
        return tokenize(self.best_label())


def canonicalize_text(value: str) -> str:
    """Converts text into a compact canonical representation."""
    lowered = value.lower()
    lowered = re.sub(r"[^a-z0-9]+", " ", lowered)
    lowered = SPACES_RE.sub(" ", lowered).strip()
    return lowered


def normalize_mod_id(value: str) -> str:
    """Normalizes mod id values for reliable equality checks."""
    normalized = re.sub(r"[^a-z0-9]+", "", value.lower())
    return normalized


def tokenize(value: str) -> set[str]:
    """Splits a label into informative lowercase tokens."""
    canonical = canonicalize_text(value)
    if not canonical:
        return set()
    tokens = set()
    for token in canonical.split(" "):
        if len(token) < 3:
            continue
        if token in GENERIC_TOKENS:
            continue
        tokens.add(token)
    return tokens


def is_generic_label(value: str) -> bool:
    """Checks whether a canonicalized label is too generic for equality matching."""
    compact = value.replace(" ", "")
    if not compact:
        return True
    if compact in GENERIC_MOD_IDS:
        return True
    if value in GENERIC_TOKENS:
        return True
    if re.fullmatch(r"\d+", compact):
        return True
    return False


def jaccard_similarity(left: set[str], right: set[str]) -> float:
    """Computes Jaccard similarity for two token sets."""
    if not left and not right:
        return 1.0
    if not left or not right:
        return 0.0
    intersection = len(left & right)
    union = len(left | right)
    if union == 0:
        return 0.0
    return intersection / union


def apply_metadata_to_record(metadata, record: ModRecord) -> None:
    """Transfers canonical metadata fields into a ModRecord."""
    raw_provided_ids = {item.lower() for item in metadata.jar_provided_ids}
    is_forge_like = metadata.loader in ("Forge", "NeoForge")

    for entry in metadata.records:
        if entry.mod_id and not entry.is_fallback_mod_id:
            record.ids.add(entry.mod_id)

        for provided_id in entry.provided_ids:
            provided = str(provided_id).strip()
            if not provided:
                continue
            if is_forge_like and provided.lower() not in raw_provided_ids:
                continue
            record.ids.add(provided)

        if entry.display_name and not entry.is_fallback_display_name:
            record.names.add(entry.display_name)


def collect_package_roots(archive: zipfile.ZipFile) -> set[str]:
    """Collects stable package roots from .class entries."""
    roots: set[str] = set()
    for entry in archive.namelist():
        entry_lower = entry.lower()
        if not entry_lower.endswith(".class"):
            continue
        if any(entry_lower.startswith(prefix) for prefix in PACKAGE_EXCLUDE_PREFIXES):
            continue
        parts = [segment for segment in entry_lower.split("/") if segment]
        if len(parts) < 3:
            continue
        root = "/".join(parts[:2])
        if root in ("com/mojang", "net/minecraft"):
            continue
        roots.add(root)
    return roots


def iter_mod_files(root: Path, recursive: bool) -> Iterable[Path]:
    """Yields mod jar files from the selected folder."""
    if recursive:
        yield from root.rglob("*.jar")
    else:
        yield from root.glob("*.jar")


def extract_mod_record(jar_path: Path) -> ModRecord:
    """Builds a ModRecord for the specified mod jar file."""
    record = ModRecord(file_path=jar_path, fallback_name=jar_path.stem)
    try:
        with zipfile.ZipFile(jar_path, "r") as archive:
            metadata = extract_jar_metadata_from_archive(
                archive=archive,
                jar_path=jar_path,
                throw_on_parse_error=False,
            )
            if metadata is not None:
                apply_metadata_to_record(metadata, record)

            record.package_roots.update(collect_package_roots(archive))
    except (OSError, zipfile.BadZipFile):
        return record

    return record


def normalized_id_set(record: ModRecord) -> set[str]:
    """Returns a filtered set of normalized ids."""
    normalized = {normalize_mod_id(mod_id) for mod_id in record.ids if mod_id}
    return {value for value in normalized if value and value not in GENERIC_MOD_IDS}


def labels_similarity(left: str, right: str) -> float:
    """Returns sequence similarity for two labels."""
    return SequenceMatcher(None, canonicalize_text(left), canonicalize_text(right)).ratio()


def is_suspicious_pair(
    left: ModRecord,
    right: ModRecord,
    name_threshold: float,
    token_threshold: float,
    package_threshold: float,
    min_label_length: int,
) -> bool:
    """Checks whether two mod records look like duplicate/similar mods."""
    left_ids = normalized_id_set(left)
    right_ids = normalized_id_set(right)
    if left_ids and right_ids and (left_ids & right_ids):
        return True

    left_labels = left.canonical_labels()
    right_labels = right.canonical_labels()
    if left_labels and right_labels and (left_labels & right_labels):
        return True

    package_overlap = left.package_roots & right.package_roots
    if package_overlap:
        best_similarity = labels_similarity(left.best_label(), right.best_label())
        if best_similarity >= package_threshold:
            return True

    left_best = left.best_label()
    right_best = right.best_label()
    if len(canonicalize_text(left_best)) < min_label_length or len(canonicalize_text(right_best)) < min_label_length:
        return False

    name_similarity = labels_similarity(left_best, right_best)
    token_similarity = jaccard_similarity(left.best_tokens(), right.best_tokens())
    return name_similarity >= name_threshold and token_similarity >= token_threshold


def build_groups(
    records: list[ModRecord],
    name_threshold: float,
    token_threshold: float,
    package_threshold: float,
    min_label_length: int,
) -> list[list[ModRecord]]:
    """Builds connected suspicious groups from pairwise similarity links."""
    parents = list(range(len(records)))

    def find(node: int) -> int:
        while parents[node] != node:
            parents[node] = parents[parents[node]]
            node = parents[node]
        return node

    def union(left: int, right: int) -> None:
        root_left = find(left)
        root_right = find(right)
        if root_left != root_right:
            parents[root_right] = root_left

    for left_index in range(len(records)):
        for right_index in range(left_index + 1, len(records)):
            if is_suspicious_pair(
                records[left_index],
                records[right_index],
                name_threshold=name_threshold,
                token_threshold=token_threshold,
                package_threshold=package_threshold,
                min_label_length=min_label_length,
            ):
                union(left_index, right_index)

    buckets: dict[int, list[ModRecord]] = {}
    for index, record in enumerate(records):
        root = find(index)
        buckets.setdefault(root, []).append(record)

    result = []
    for group in buckets.values():
        if len(group) < 2:
            continue
        sorted_group = sorted(group, key=lambda item: item.file_path.name.lower())
        result.append(sorted_group)

    result.sort(key=lambda group: (len(group), group[0].file_path.name.lower()), reverse=True)
    return result


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    """Parses CLI arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Find suspiciously similar mods by reading metadata inside jars. "
            "Looks at mod ids, display names, package roots, and fuzzy label similarity."
        )
    )
    parser.add_argument(
        "mods_dir",
        type=Path,
        help="Path to folder with mod jar files.",
    )
    parser.add_argument(
        "--recursive",
        action="store_true",
        help="Scan nested folders recursively.",
    )
    parser.add_argument(
        "--name-threshold",
        type=float,
        default=DEFAULT_NAME_SIMILARITY_THRESHOLD,
        help=f"Minimum label similarity (0..1), default: {DEFAULT_NAME_SIMILARITY_THRESHOLD}.",
    )
    parser.add_argument(
        "--token-threshold",
        type=float,
        default=DEFAULT_TOKEN_JACCARD_THRESHOLD,
        help=f"Minimum token Jaccard similarity (0..1), default: {DEFAULT_TOKEN_JACCARD_THRESHOLD}.",
    )
    parser.add_argument(
        "--package-threshold",
        type=float,
        default=DEFAULT_PACKAGE_SIMILARITY_THRESHOLD,
        help=f"Minimum label similarity for package-overlap matches (0..1), default: {DEFAULT_PACKAGE_SIMILARITY_THRESHOLD}.",
    )
    parser.add_argument(
        "--min-label-length",
        type=int,
        default=DEFAULT_MIN_LABEL_LENGTH,
        help=f"Minimum canonical label length for fuzzy matching, default: {DEFAULT_MIN_LABEL_LENGTH}.",
    )
    parser.add_argument(
        "-help",
        action="help",
        help="Show this help message and exit.",
    )
    return parser.parse_args(argv)


def validate_ratio(value: float, argument_name: str) -> Optional[str]:
    """Validates ratio arguments."""
    if 0.0 <= value <= 1.0:
        return None
    return f"{argument_name} must be in range [0, 1], got: {value}"


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

    for arg_name, arg_value in (
        ("--name-threshold", args.name_threshold),
        ("--token-threshold", args.token_threshold),
        ("--package-threshold", args.package_threshold),
    ):
        validation_error = validate_ratio(arg_value, arg_name)
        if validation_error:
            print(validation_error)
            return 1

    if args.min_label_length < 1:
        print(f"--min-label-length must be >= 1, got: {args.min_label_length}")
        return 1

    records = [extract_mod_record(path) for path in iter_mod_files(mods_dir, args.recursive)]
    groups = build_groups(
        records=records,
        name_threshold=args.name_threshold,
        token_threshold=args.token_threshold,
        package_threshold=args.package_threshold,
        min_label_length=args.min_label_length,
    )

    print(f"checked_mods: {len(records)}")
    if not groups:
        print("suspicious_groups: 0")
        return 0

    print(f"suspicious_groups: {len(groups)}")
    for index, group in enumerate(groups, start=1):
        names = " | ".join(item.file_path.name for item in group)
        print(f"group_{index} ({len(group)}): {names}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
