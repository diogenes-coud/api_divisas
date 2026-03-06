from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from time import sleep

from src.app.database.db import safe_execute_insert
from src.app.services.xe_service import fetch_xe_rows, normalize_rate
from src.app.utils.dates import iter_dates, now_local_iso


@dataclass(frozen=True)
class LoadStats:
    processed_days: int
    inserted_rows: int
    skipped_rows: int
    failed_days: int


INSERT_SQL = """
INSERT INTO GJO_CCO.[dbo].[Divisas] (Fecha, Fuente, Simbolo, Divisa, Compra, Venta, Promedio)
SELECT ?, ?, ?, ?, ?, ?, ?
WHERE NOT EXISTS (
    SELECT 1
    FROM GJO_CCO.[dbo].[Divisas]
    WHERE Fecha = ? AND Fuente = ? AND Simbolo = ? AND Divisa = ?
)
""".strip()


def _resolve_base_currency(target_date: date, forced_currency: str | None = None) -> str:
    if forced_currency:
        return forced_currency.upper()
    threshold = date(2001, 11, 16)
    return "USD" if target_date < threshold else "ARS"


def load_divisas_range(
    conn,
    start_date: date,
    end_date: date,
    fuente: str = "XE",
    from_currency: str | None = None,
    retries_per_day: int = 3,
    retry_sleep_seconds: float = 1.5,
    sleep_between_dates_seconds: float = 1.0,
    fallback_previous_days: int = 3,
    log_skipped_rows: bool = True,
) -> LoadStats:
    cursor = conn.cursor()
    processed_days = 0
    inserted_rows = 0
    skipped_rows = 0
    failed_days = 0

    for current_date in iter_dates(start_date, end_date):
        processed_days += 1
        day_str = current_date.strftime("%Y-%m-%d")
        base_currency = _resolve_base_currency(current_date, from_currency)
        inserted_this_day = 0
        skipped_this_day = 0

        day_rows = None
        last_error = None
        source_date_used: date | None = None
        fallback_limit = max(0, int(fallback_previous_days))

        for back_days in range(0, fallback_limit + 1):
            lookup_date = current_date - timedelta(days=back_days)
            lookup_str = lookup_date.strftime("%Y-%m-%d")
            for attempt in range(1, retries_per_day + 1):
                try:
                    print(
                        f"[{now_local_iso()}] Descargando XE objetivo={day_str} "
                        f"consulta={lookup_str} (base={base_currency}) intento {attempt}/{retries_per_day}"
                    )
                    day_rows = fetch_xe_rows(lookup_date, from_currency=base_currency)
                    source_date_used = lookup_date
                    break
                except Exception as exc:
                    last_error = exc
                    if attempt < retries_per_day:
                        sleep(retry_sleep_seconds)

            if day_rows is not None:
                break

        if day_rows is None:
            failed_days += 1
            print(f"[{now_local_iso()}] [WARN] Sin datos para {day_str}: {last_error}")
            continue

        if source_date_used and source_date_used != current_date:
            print(
                f"[{now_local_iso()}] [INFO] {day_str} sin cotización directa, "
                f"se usa cotización disponible de {source_date_used.strftime('%Y-%m-%d')}"
            )

        for idx, row in enumerate(day_rows, start=1):
            symbol = row.symbol
            if row.units_per_base == "0":
                symbol = "ARS"

            rate = normalize_rate(row.base_per_unit)
            skip_reason = None
            if symbol == "ARS":
                skip_reason = "Simbolo ARS"
            elif rate == "Infinity":
                skip_reason = "Cotizacion Infinity"
            elif not rate:
                skip_reason = "Cotizacion vacía/no válida"

            if skip_reason is not None:
                skipped_rows += 1
                skipped_this_day += 1
                if log_skipped_rows:
                    print(
                        f"[{now_local_iso()}] [SKIP] fecha_objetivo={day_str} "
                        f"fila={idx} simbolo={symbol} divisa={row.name} "
                        f"units_per_base={row.units_per_base} base_per_unit={row.base_per_unit} "
                        f"motivo={skip_reason}"
                    )
                continue

            params = (
                day_str,
                fuente,
                symbol,
                row.name,
                rate,
                rate,
                rate,
                day_str,
                fuente,
                symbol,
                row.name,
            )
            did_insert = safe_execute_insert(cursor, INSERT_SQL, params, f"{day_str}:{idx}")
            if did_insert:
                inserted_rows += 1
                inserted_this_day += 1

        conn.commit()
        print(
            f"[{now_local_iso()}] OK {day_str} -> "
            f"insertadas_dia={inserted_this_day} saltadas_dia={skipped_this_day} "
            f"insertadas_total={inserted_rows} saltadas_total={skipped_rows}"
        )

        if sleep_between_dates_seconds > 0:
            sleep(sleep_between_dates_seconds)

    cursor.close()
    return LoadStats(
        processed_days=processed_days,
        inserted_rows=inserted_rows,
        skipped_rows=skipped_rows,
        failed_days=failed_days,
    )
