"""Shared error type for the Geo tools.

The HTTP client that once talked to Geo.app's localhost API is retired — every
tool now reads/writes the vault directly (``reads.py`` over the SQLite index,
``tasks_fs.py`` over ``Tasks/``). Only this exception survives, imported by the
file-native modules to signal a vault read/write failure.
"""

from __future__ import annotations


class GeoError(Exception):
    pass
