from __future__ import annotations

from datetime import date, datetime, timedelta


def iter_dates(start: date, end: date):
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def parse_ddmmyyyy(raw: str) -> date:
    return datetime.strptime(raw, "%d/%m/%Y").date()


def now_local_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")
