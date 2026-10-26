"""memoir-asr's version (DESIGN.md §9.1): from git when it runs from a checkout (the Spark does), else
the package's.

Same format as the Mac's: `0.2.0` exactly at a release tag, `0.2.0+3 (3005f27)` three commits after it,
`…, modified)` with uncommitted changes.
"""

import re
import subprocess
from pathlib import Path

from . import __version__

DESCRIBE = re.compile(r"v(\d+\.\d+\.\d+)-(\d+)-g([0-9a-f]+)(-dirty)?")


def format_described(described: str) -> str | None:
    """`git describe --tags --long --dirty` output → memoir's version string (None if it isn't one)."""
    m = DESCRIBE.fullmatch(described.strip())
    if not m:
        return None
    version, ahead, commit, dirty = m.group(1), int(m.group(2)), m.group(3)[:7], bool(m.group(4))
    if ahead == 0 and not dirty:
        return version
    return f"{version}{f'+{ahead}' if ahead else ''} ({commit}{', modified' if dirty else ''})"


def current(repo: Path = Path(__file__).resolve().parents[2]) -> str:
    try:
        described = subprocess.run(
            ["git", "-C", str(repo), "describe", "--tags", "--long", "--dirty", "--match", "v[0-9]*"],
            capture_output=True, text=True, timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        described = ""
    return format_described(described) or __version__


VERSION = current()
