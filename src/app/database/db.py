from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import date, datetime

import pyodbc


@dataclass(frozen=True)
class DbSettings:
    server: str
    database: str
    user: str
    password: str
    driver: str = "ODBC Driver 17 for SQL Server"


def read_db_settings_from_env() -> DbSettings:
    server = os.getenv("DB_SERVER")
    database = os.getenv("DB_DATABASE")
    user = os.getenv("DB_USER")
    password = os.getenv("DB_PASSWORD")

    missing = [
        key
        for key, value in {
            "DB_SERVER": server,
            "DB_DATABASE": database,
            "DB_USER": user,
            "DB_PASSWORD": password,
        }.items()
        if not value
    ]

    if missing:
        raise EnvironmentError(f"Faltan variables de entorno: {', '.join(missing)}")

    return DbSettings(
        server=server,
        database=database,
        user=user,
        password=password,
        driver=os.getenv("DB_DRIVER", "ODBC Driver 17 for SQL Server"),
    )


def connect(db: DbSettings) -> pyodbc.Connection:
    encrypt = os.getenv("DB_ENCRYPT", "yes")
    trust_server_certificate = os.getenv("DB_TRUST_SERVER_CERTIFICATE", "yes")

    conn_str = (
        f"DRIVER={{{db.driver}}};"
        f"SERVER={db.server};"
        f"DATABASE={db.database};"
        f"UID={db.user};"
        f"PWD={db.password};"
        f"Encrypt={encrypt};"
        f"TrustServerCertificate={trust_server_certificate};"
    )
    conn = pyodbc.connect(conn_str, autocommit=False, timeout=30)
    conn.timeout = 30
    return conn


insert_report: list[dict[str, str]] = []


def safe_execute_insert(cursor: pyodbc.Cursor, sql: str, params: tuple, row_ref: str | int) -> bool:
    try:
        cursor.execute(sql, params)
        affected = cursor.rowcount if cursor.rowcount is not None else 0
        if affected > 0:
            insert_report.append(
                {
                    "row": str(row_ref),
                    "status": "INSERTED",
                    "detail": "Insert ejecutado correctamente",
                }
            )
            return True

        insert_report.append(
            {
                "row": str(row_ref),
                "status": "NOT_INSERTED",
                "detail": "Registro ya existente (omitido por condición)",
            }
        )
        return False
    except Exception as exc:
        insert_report.append(
            {
                "row": str(row_ref),
                "status": "NOT_INSERTED",
                "detail": str(exc),
            }
        )
        return False


def get_last_divisas_date(conn: pyodbc.Connection) -> date | None:
    sql = """
    SELECT TOP (1) [Fecha]
    FROM [GJO_CCO].[dbo].[Divisas]
    ORDER BY [Fecha] DESC
    """.strip()
    cursor = conn.cursor()
    cursor.execute(sql)
    row = cursor.fetchone()
    cursor.close()

    if not row or row[0] is None:
        return None

    raw = row[0]
    if isinstance(raw, date):
        return raw
    if isinstance(raw, datetime):
        return raw.date()
    return datetime.strptime(str(raw), "%Y-%m-%d").date()
