from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path


@dataclass(frozen=True)
class RuntimeConfig:
    fecha_inicial: date | None
    fecha_final: date | None
    usar_fecha_inicial_base_datos: bool
    usar_fecha_final_ayer: bool
    from_currency: str | None
    reintentos: int
    sleep_entre_fechas_seg: float
    fallback_dias_anteriores: int
    log_filas_saltadas: bool
    auto_desde_ultima_fecha_db: bool


def _to_bool(raw: str | None, default: bool) -> bool:
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "t", "yes", "y", "si", "sí", "s"}:
        return True
    if value in {"0", "false", "f", "no", "n"}:
        return False
    return default


def _parse_date(raw: str | None) -> date | None:
    if not raw:
        return None
    value = raw.strip()
    if not value:
        return None
    for fmt in ("%d/%m/%Y", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"Fecha inválida '{value}'. Usá dd/mm/yyyy o yyyy-mm-dd")


def _normalize_token(raw: str | None) -> str:
    if raw is None:
        return ""
    return raw.strip().lower()


def load_runtime_config(path: str | Path) -> RuntimeConfig:
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"No existe config.txt en: {config_path.resolve()}")

    data: dict[str, str] = {}
    for raw in config_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("sqlserver:"):
            continue
        if "=" in line:
            key, value = line.split("=", 1)
        elif ":" in line:
            key, value = line.split(":", 1)
        else:
            continue
        data[key.strip().upper()] = value.strip()

    from_currency_raw = data.get("FROM_CURRENCY")
    from_currency = from_currency_raw.upper() if from_currency_raw else None
    if from_currency not in {None, "ARS", "USD"}:
        raise ValueError("FROM_CURRENCY debe ser ARS o USD")

    reintentos_raw = data.get("REINTENTOS", "3")
    try:
        reintentos = max(1, int(reintentos_raw))
    except ValueError as exc:
        raise ValueError("REINTENTOS debe ser entero") from exc

    sleep_raw = data.get("SLEEP_ENTRE_FECHAS_SEG", "1")
    try:
        sleep_entre_fechas_seg = max(0.0, float(sleep_raw))
    except ValueError as exc:
        raise ValueError("SLEEP_ENTRE_FECHAS_SEG debe ser numérico") from exc

    fallback_raw = data.get("FALLBACK_DIAS_ANTERIORES", "3")
    try:
        fallback_dias_anteriores = max(0, int(fallback_raw))
    except ValueError as exc:
        raise ValueError("FALLBACK_DIAS_ANTERIORES debe ser entero") from exc

    log_filas_saltadas = _to_bool(data.get("LOG_FILAS_SALTADAS"), True)

    fecha_inicial_raw = data.get("FECHA_INICIAL", "base_datos")
    fecha_final_raw = data.get("FECHA_FINAL", "ayer")

    start_token = _normalize_token(fecha_inicial_raw)
    end_token = _normalize_token(fecha_final_raw)

    usar_fecha_inicial_base_datos = start_token in {"", "base_datos", "db", "base"}
    usar_fecha_final_ayer = end_token in {"", "ayer", "yesterday"}

    fecha_inicial = None if usar_fecha_inicial_base_datos else _parse_date(fecha_inicial_raw)
    fecha_final = None if usar_fecha_final_ayer else _parse_date(fecha_final_raw)

    return RuntimeConfig(
        fecha_inicial=fecha_inicial,
        fecha_final=fecha_final,
        usar_fecha_inicial_base_datos=usar_fecha_inicial_base_datos,
        usar_fecha_final_ayer=usar_fecha_final_ayer,
        from_currency=from_currency,
        reintentos=reintentos,
        sleep_entre_fechas_seg=sleep_entre_fechas_seg,
        fallback_dias_anteriores=fallback_dias_anteriores,
        log_filas_saltadas=log_filas_saltadas,
        auto_desde_ultima_fecha_db=_to_bool(data.get("AUTO_DESDE_ULTIMA_FECHA_DB"), True),
    )
