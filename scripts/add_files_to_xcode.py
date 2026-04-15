#!/usr/bin/env python3
"""Add Swift source files to PhotoRawManager.xcodeproj.

Usage:
    python3 scripts/add_files_to_xcode.py <relative-path-from-repo-root> [more-paths...]

Each path is added to the main PhotoRawManager target's Sources phase. The file
is registered into the matching PBXGroup based on the parent directory name.
For unknown groups, a new sub-group is created under the closest known parent.
"""
import sys
from pathlib import Path
from pbxproj import XcodeProject

REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECT_PATH = REPO_ROOT / "PhotoRawManager.xcodeproj" / "project.pbxproj"
TARGET_NAME = "PhotoRawManager"

# Known top-level groups in the project. Files placed under these directories
# get added to the matching group automatically.
KNOWN_GROUPS = {
    "Models": "Models",
    "Views": "Views",
    "Services": "Services",
    "Settings": ("Views", "Settings"),
    "Hardware": ("Services", "Hardware"),
    "Thumbnails": ("Services", "Thumbnails"),
    "Analysis": ("Services", "Analysis"),
    "AI": ("Services", "AI"),
    "Cloud": ("Services", "Cloud"),
    "Preview": ("Views", "Preview"),
    "Common": ("Views", "Common"),
    "ProgressBars": ("Views", "ProgressBars"),
}


def find_group(project: XcodeProject, group_path: tuple) -> object:
    """Find or create a nested group given a tuple of names."""
    parent = project.get_or_create_group(group_path[0])
    for sub in group_path[1:]:
        existing = next((c for c in project.objects.get_objects_in_section("PBXGroup")
                         if getattr(c, "name", None) == sub or getattr(c, "path", None) == sub),
                        None)
        if existing is None:
            existing = project.add_group(sub, parent=parent)
        parent = existing
    return parent


def add_file(project: XcodeProject, rel_path: str) -> bool:
    abs_path = REPO_ROOT / rel_path
    if not abs_path.is_file():
        print(f"  ✗ MISSING: {rel_path}", file=sys.stderr)
        return False

    # Determine destination group from the parent dir name.
    # e.g. PhotoRawManager/Views/Settings/Foo.swift → ("Views", "Settings")
    parts = abs_path.relative_to(REPO_ROOT).parts
    # Strip leading "PhotoRawManager" if present
    if parts[0] == "PhotoRawManager":
        parts = parts[1:]
    parent_dirs = parts[:-1]  # everything except filename

    if not parent_dirs:
        group_tuple = ("PhotoRawManager",)
    elif len(parent_dirs) == 1 and parent_dirs[0] in KNOWN_GROUPS:
        group_tuple = (KNOWN_GROUPS[parent_dirs[0]],) if isinstance(KNOWN_GROUPS[parent_dirs[0]], str) else KNOWN_GROUPS[parent_dirs[0]]
    elif len(parent_dirs) >= 2 and parent_dirs[-1] in KNOWN_GROUPS:
        mapped = KNOWN_GROUPS[parent_dirs[-1]]
        group_tuple = (mapped,) if isinstance(mapped, str) else mapped
    else:
        group_tuple = parent_dirs

    parent_group = find_group(project, group_tuple)

    # Skip if file is already in project
    existing_refs = [f for f in project.objects.get_objects_in_section("PBXFileReference")
                     if getattr(f, "path", None) == abs_path.name]
    if existing_refs:
        # Check whether ANY existing ref already points to this exact path location
        for ref in existing_refs:
            ref_dict = ref.__dict__
            # naive duplicate guard by name only
            print(f"  • already in project: {abs_path.name}")
            return True

    project.add_file(str(abs_path), parent=parent_group, target_name=TARGET_NAME, force=False)
    print(f"  ✓ added: {rel_path}  → group: {'/'.join(group_tuple)}")
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    project = XcodeProject.load(str(PROJECT_PATH))
    ok_all = True
    for rel in sys.argv[1:]:
        if not add_file(project, rel):
            ok_all = False
    project.save()
    return 0 if ok_all else 2


if __name__ == "__main__":
    sys.exit(main())
