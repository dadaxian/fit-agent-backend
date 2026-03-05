"""Time utilities with configurable timezone."""

from __future__ import annotations

import os
from datetime import UTC, datetime
from zoneinfo import ZoneInfo


def get_timezone() -> ZoneInfo:
    tz_name = os.environ.get("APP_TIMEZONE", "").strip()
    if not tz_name:
        return ZoneInfo("UTC")
    try:
        return ZoneInfo(tz_name)
    except Exception:
        return ZoneInfo("UTC")


def now_with_tz() -> datetime:
    return datetime.now(tz=get_timezone())
