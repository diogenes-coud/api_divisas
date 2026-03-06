from __future__ import annotations

import argparse
from datetime import date, timedelta
from pathlib import Path

from src.app.config.env import bootstrap_db_environment
from src.app.config.loader import load_runtime_config
from src.app.database.db import connect, get_last_divisas_date, read_db_settings_from_env
from src.app.jobs.load_divisas_job import load_divisas_range
from src.app.utils.dates import parse_ddmmyyyy


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Carga histórica de divisas XE a SQL Server")
    parser.add_argument("--config", default="config.txt", help="Ruta a config.txt (default: config.txt)")
    parser.add_argument("--fecha-inicial", required=False, help="Formato dd/mm/yyyy")
    parser.add_argument("--fecha-final", required=False, help="Formato dd/mm/yyyy")
    parser.add_argument(
        "--from",
        dest="from_currency",
        default=None,
        choices=["ARS", "USD", "ars", "usd"],
        help="Moneda base forzada. Si no se indica: USD antes de 2001-11-16, ARS desde 2001-11-16.",
    )
    parser.add_argument("--reintentos", type=int, default=3, help="Reintentos por fecha en caso de error")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    base_dir = Path(__file__).resolve().parent
    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = base_dir / config_path

    runtime_cfg = load_runtime_config(config_path)
    bootstrap_db_environment(base_dir)

    db_settings = read_db_settings_from_env()
    with connect(db_settings) as conn:
        start_date = parse_ddmmyyyy(args.fecha_inicial) if args.fecha_inicial else runtime_cfg.fecha_inicial
        end_date = parse_ddmmyyyy(args.fecha_final) if args.fecha_final else runtime_cfg.fecha_final
        from_currency = args.from_currency.upper() if args.from_currency else runtime_cfg.from_currency
        reintentos = max(1, args.reintentos) if args.reintentos else runtime_cfg.reintentos

        if start_date is None and runtime_cfg.usar_fecha_inicial_base_datos and runtime_cfg.auto_desde_ultima_fecha_db:
            last_date = get_last_divisas_date(conn)
            if last_date is not None:
                start_date = last_date + timedelta(days=1)
                print(
                    f"Fecha inicial resuelta desde DB: {start_date.isoformat()} "
                    f"(día siguiente a última cargada {last_date.isoformat()})"
                )

        if start_date is None:
            raise ValueError("No se pudo resolver FECHA_INICIAL. Usá 'base_datos' o una fecha explícita en config.txt")

        if end_date is None and runtime_cfg.usar_fecha_final_ayer:
            end_date = date.today() - timedelta(days=1)
            print(f"Fecha final resuelta automáticamente: {end_date.isoformat()} (ayer)")

        if end_date is None:
            raise ValueError("No se pudo resolver FECHA_FINAL. Usá 'ayer' o una fecha explícita en config.txt")

        if end_date < start_date:
            print(
                "No hay rango para procesar: "
                f"fecha_inicial={start_date.isoformat()} fecha_final={end_date.isoformat()}"
            )
            return 0

        print(f"Rango a procesar: {start_date.isoformat()} -> {end_date.isoformat()}")
        print(f"Fallback hacia días anteriores activo: {runtime_cfg.fallback_dias_anteriores} días")

        stats = load_divisas_range(
            conn=conn,
            start_date=start_date,
            end_date=end_date,
            from_currency=from_currency,
            retries_per_day=reintentos,
            sleep_between_dates_seconds=runtime_cfg.sleep_entre_fechas_seg,
            fallback_previous_days=runtime_cfg.fallback_dias_anteriores,
            log_skipped_rows=runtime_cfg.log_filas_saltadas,
        )

    print(
        "Proceso finalizado. "
        f"días={stats.processed_days}, insertadas={stats.inserted_rows}, "
        f"saltadas={stats.skipped_rows}, días_fallidos={stats.failed_days}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
