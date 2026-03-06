from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation, getcontext

import requests
from bs4 import BeautifulSoup


getcontext().prec = 40


@dataclass(frozen=True)
class XeRow:
    symbol: str
    name: str
    units_per_base: str
    base_per_unit: str


def _clean_text(value: str) -> str:
    return value.replace("\xa0", " ").strip()


def _decimal_to_plain(raw: str) -> str:
    value = _clean_text(raw).replace(",", "")
    if value in {"", "Infinity"}:
        return value

    try:
        as_decimal = Decimal(value)
    except InvalidOperation:
        return value

    plain = format(as_decimal, "f")
    if "." in plain:
        plain = plain.rstrip("0").rstrip(".")
    return plain if plain else "0"


def normalize_rate(raw: str) -> str:
    plain = _decimal_to_plain(raw)
    return plain[:27] if len(plain) > 27 else plain


def fetch_xe_rows(target_date: date, from_currency: str = "ARS", timeout: int = 30) -> list[XeRow]:
    date_str = target_date.strftime("%Y-%m-%d")
    base = from_currency.upper()
    url = f"https://www.xe.com/es/currencytables/?from={base}&date={date_str}#table-section"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    }

    response = requests.get(url, headers=headers, timeout=timeout)
    response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")
    table = soup.find("table")
    if table is None:
        raise ValueError(f"No se encontró tabla XE para fecha={date_str} base={base}")

    rows: list[XeRow] = []
    body_rows = table.find_all("tr")
    for tr in body_rows:
        cols = tr.find_all("td")
        if not cols:
            continue

        row_header = tr.find("th")
        if len(cols) >= 4:
            symbol = _clean_text(cols[0].get_text(" ", strip=True))
            name = _clean_text(cols[1].get_text(" ", strip=True)).replace("'", "_")
            units = _clean_text(cols[2].get_text(" ", strip=True))
            inverse = _clean_text(cols[3].get_text(" ", strip=True))
        elif len(cols) >= 3 and row_header is not None:
            symbol = _clean_text(row_header.get_text(" ", strip=True))
            name = _clean_text(cols[0].get_text(" ", strip=True)).replace("'", "_")
            units = _clean_text(cols[1].get_text(" ", strip=True))
            inverse = _clean_text(cols[2].get_text(" ", strip=True))
        else:
            continue

        rows.append(XeRow(symbol=symbol, name=name, units_per_base=units, base_per_unit=inverse))

    if not rows:
        raise ValueError(f"La tabla XE no tiene filas para fecha={date_str} base={base}")
    return rows
