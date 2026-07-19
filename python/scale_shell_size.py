#!/usr/bin/env python3
"""Scale the `size` field of every ShellParams resource in the Godot project.

ShellParams resources are identified by the `script` they reference
(res://src/artillary/Shells/shell_params.gd). They show up as
`[sub_resource ...]` or `[resource]` blocks inside .tscn/.tres files.

On the first run for a given file, whatever `size` values currently sit in
that file are treated as the baseline ("source of truth") and are recorded in
a JSON map file, keyed by the res:// path of the file, e.g.:

    "res://assets/Ships/H44/H44.tscn": [5.0, 5.0, 2.25, 2.25]

On every run (including the first), the new size written to disk is
`baseline_size * scale_factor`, so re-running with different scale factors
never compounds on top of a previous scaling pass.

Usage:
    python scale_shell_size.py SCALE_FACTOR [--root PATH] [--map PATH] [--dry-run]

Example:
    python scale_shell_size.py 1.1
"""

import argparse
import json
import re
import sys
from pathlib import Path

SHELL_PARAMS_UID = "uid://d0r4vucnli08f"
SHELL_PARAMS_SCRIPT_PATH = "res://src/artillary/Shells/shell_params.gd"

SKIP_DIR_NAMES = {".godot", ".git", ".import", ".vscode", ".zed", "build", "bin"}

EXT_RESOURCE_RE = re.compile(r'\[ext_resource\s+type="Script"[^\]]*\]')
ATTR_RE = re.compile(r'(\w+)="([^"]*)"')
BLOCK_HEADER_RE = re.compile(r'^\[(sub_resource|resource)\b[^\]]*\]\s*$', re.MULTILINE)
SCRIPT_LINE_RE = re.compile(r'^script\s*=\s*ExtResource\("([^"]+)"\)\s*$', re.MULTILINE)
SIZE_LINE_RE = re.compile(r'^size\s*=\s*([\-0-9.eE]+)\s*$', re.MULTILINE)


def find_shell_ext_resource_ids(content: str) -> set[str]:
    ids = set()
    for match in EXT_RESOURCE_RE.finditer(content):
        attrs = dict(ATTR_RE.findall(match.group(0)))
        if attrs.get("uid") == SHELL_PARAMS_UID or attrs.get("path") == SHELL_PARAMS_SCRIPT_PATH:
            ids.add(attrs["id"])
    return ids


def find_size_spans(content: str, shell_ids: set[str]) -> list[tuple[int, int, float]]:
    """Return (start, end, value) spans for each `size = X` line that belongs
    to a ShellParams resource block, in file order."""
    if not shell_ids:
        return []

    headers = list(BLOCK_HEADER_RE.finditer(content))
    spans = []
    for i, header in enumerate(headers):
        body_start = header.end()
        body_end = headers[i + 1].start() if i + 1 < len(headers) else len(content)
        body = content[body_start:body_end]

        script_match = SCRIPT_LINE_RE.search(body)
        if not script_match or script_match.group(1) not in shell_ids:
            continue

        size_match = SIZE_LINE_RE.search(body)
        if not size_match:
            continue

        start = body_start + size_match.start(1)
        end = body_start + size_match.end(1)
        spans.append((start, end, float(size_match.group(1))))

    return spans


def format_size(value: float) -> str:
    if value == int(value):
        return f"{value:.1f}"
    text = f"{value:.6f}".rstrip("0")
    if text.endswith("."):
        text += "0"
    return text


def to_res_path(path: Path, root: Path) -> str:
    return "res://" + path.relative_to(root).as_posix()


def iter_target_files(root: Path):
    for path in root.rglob("*"):
        if path.suffix not in (".tscn", ".tres"):
            continue
        if any(part in SKIP_DIR_NAMES for part in path.parts):
            continue
        yield path


def load_map(map_path: Path) -> dict:
    if not map_path.exists():
        return {}
    return json.loads(map_path.read_text())


def save_map(map_path: Path, data: dict) -> None:
    map_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def process_file(
    path: Path,
    root: Path,
    scale_factor: float,
    size_map: dict,
    map_path: Path,
    dry_run: bool,
) -> bool:
    content = path.read_text()
    shell_ids = find_shell_ext_resource_ids(content)
    spans = find_size_spans(content, shell_ids)
    if not spans:
        return False

    res_path = to_res_path(path, root)
    current_values = [value for _, _, value in spans]

    if res_path in size_map:
        baseline = size_map[res_path]
        if len(baseline) != len(current_values):
            raise RuntimeError(
                f"{res_path}: expected {len(baseline)} shell size entries from "
                f"map, found {len(current_values)} in file. Refusing to guess; "
                f"fix the mismatch (or the map file) manually."
            )
    else:
        baseline = current_values
        size_map[res_path] = baseline
        if not dry_run:
            save_map(map_path, size_map)

    new_values = [b * scale_factor for b in baseline]

    pieces = []
    cursor = 0
    for (start, end, _old_value), new_value in zip(spans, new_values):
        pieces.append(content[cursor:start])
        pieces.append(format_size(new_value))
        cursor = end
    pieces.append(content[cursor:])
    new_content = "".join(pieces)

    if new_content == content:
        return False

    print(f"{res_path}: {current_values} -> {new_values}")
    if not dry_run:
        path.write_text(new_content)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scale_factor", type=float, help="Factor to multiply each baseline size by")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Godot project root (defaults to the parent of this script's directory)",
    )
    parser.add_argument(
        "--map",
        type=Path,
        default=Path(__file__).resolve().parent / "shell_size_map.json",
        help="JSON file used to remember the original (baseline) sizes",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print changes without writing files")
    args = parser.parse_args()

    root = args.root.resolve()
    size_map = load_map(args.map)

    changed = 0
    for path in sorted(iter_target_files(root)):
        if process_file(path, root, args.scale_factor, size_map, args.map, args.dry_run):
            changed += 1

    if not args.dry_run:
        save_map(args.map, size_map)

    print(f"\n{changed} file(s) updated.")


if __name__ == "__main__":
    main()
