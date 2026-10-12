#!/usr/bin/env python3
"""Disambiguate CoreStore 9.3.0's typed-throws overload for Xcode 27.

Run after package resolution, before building:
    python3 Scripts/fix-corestore-xcode27.py <CoreStore checkout directory>

Only renames the CoreStoreError overload and its caller; behavior is unchanged.
The patch is idempotent and rejects unexpected dependency sources.
"""

import sys
import stat
from pathlib import Path


def main():
    sources = Path(sys.argv[1]) / "Sources"
    replacements = {
        "DispatchQueue+CoreStore.swift": (
            "internal func cs_sync<T>(\n        _ closure: () throws(CoreStoreError) -> T",
            "internal func cs_syncCoreStore<T>(\n        _ closure: () throws(CoreStoreError) -> T",
        ),
        "DataStack+Transaction.swift": (
            "transaction.transactionQueue.cs_sync { () throws(CoreStoreError) -> T in",
            "transaction.transactionQueue.cs_syncCoreStore { () throws(CoreStoreError) -> T in",
        ),
    }
    changes = []
    for filename, (old, new) in replacements.items():
        path = sources / filename
        text = path.read_text()
        if old not in text and text.count(new) == 1:
            continue
        if text.count(old) != 1 or new in text:
            raise SystemExit(f"Unexpected CoreStore source: {path}; no files changed")
        changes.append((path, text.replace(old, new)))
    for path, text in changes:
        original_mode = stat.S_IMODE(path.stat().st_mode)
        try:
            path.chmod(original_mode | stat.S_IWUSR)
            path.write_text(text)
        finally:
            path.chmod(original_mode)
    print(f"CoreStore Xcode 27 workaround ready ({len(changes)} files patched)")


if __name__ == "__main__":
    main()
