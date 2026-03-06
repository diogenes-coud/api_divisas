# api_divisas

Carga histórica de cotizaciones desde XE hacia SQL Server, migrada desde macro VBA.

## Flujo implementado

- Recorre un rango de fechas (`dd/mm/yyyy`).
- Obtiene la tabla diaria de XE (`currencytables`) para base `ARS` o `USD`.
- Normaliza cotizaciones (incluyendo notación científica).
- Inserta en `GJO_CCO.dbo.Divisas` los campos:
	- `Fecha`, `Fuente`, `Simbolo`, `Divisa`, `Compra`, `Venta`, `Promedio`
- Omite filas con `Simbolo = ARS` o cotización `Infinity`.

## Estructura

- `main.py`: orquestador y CLI.
- `src/app/config/env.py`: bootstrap de variables de entorno y carga de credenciales desde Windows (`credentials.xml`).
- `src/app/database/db.py`: conexión a SQL Server (mismo patrón que `api_so`).
- `src/app/services/xe_service.py`: descarga y parseo de tabla XE.
- `src/app/jobs/load_divisas_job.py`: job ETL por rango de fechas.

## Instalación

```bash
pip install -r requirements.txt
```

## Variables de entorno requeridas

- `DB_SERVER`
- `DB_DATABASE` (default: `GJO_CCO`)
- `DB_USER`
- `DB_PASSWORD`
- `DB_DRIVER` (opcional, default: `ODBC Driver 17 for SQL Server`)

Si no están seteadas, el proyecto intenta cargarlas desde:

- `%USERPROFILE%\.api_divisas\config.txt` y `%USERPROFILE%\.api_divisas\credentials.xml`
- fallback compatible: `%USERPROFILE%\.api_so\config.txt` y `%USERPROFILE%\.api_so\credentials.xml`

## config.txt

El proceso usa `config.txt` (en raíz del proyecto) con estas claves:

- `FECHA_INICIAL` (`base_datos` o fecha `dd/mm/yyyy` / `yyyy-mm-dd`)
- `FECHA_FINAL` (`ayer` o fecha `dd/mm/yyyy` / `yyyy-mm-dd`)
- `FROM_CURRENCY` (`ARS` o `USD`, opcional)
- `REINTENTOS` (default `3`)
- `SLEEP_ENTRE_FECHAS_SEG` (default `1`)
- `FALLBACK_DIAS_ANTERIORES` (default `3`)
- `LOG_FILAS_SALTADAS` (default `true`)
- `AUTO_DESDE_ULTIMA_FECHA_DB` (default `true`)

Si `FECHA_INICIAL=base_datos` y `AUTO_DESDE_ULTIMA_FECHA_DB=true`, se calcula automáticamente con:

```sql
SELECT TOP (1) [Fecha]
FROM [GJO_CCO].[dbo].[Divisas]
ORDER BY [Fecha] DESC
```

y usa como inicio **el día siguiente** a esa fecha (evita reprocesar la última fecha ya cargada).

Si `FECHA_FINAL=ayer`, toma automáticamente la fecha de ayer como fin de procesamiento.

Para reducir bloqueos/rate-limit de XE, se aplica una pausa entre fechas (`SLEEP_ENTRE_FECHAS_SEG`).

Si una fecha no tiene cotización (ej: fin de semana/feriado), el proceso busca hacia atrás hasta `FALLBACK_DIAS_ANTERIORES` y usa la última fecha disponible encontrada, cargándola en la fecha objetivo.

Cuando `LOG_FILAS_SALTADAS=true`, se imprime cada fila saltada con motivo (ej: `Simbolo ARS`, `Cotizacion Infinity`).

La inserción es idempotente por (`Fecha`, `Fuente`, `Simbolo`, `Divisa`) y está alineada con la constraint única de la tabla: si el registro ya existe, se omite sin error.

## Ejecución

```bash
python main.py
```

Opcionalmente podés overridear por CLI:

```bash
python main.py --fecha-inicial 01/01/1999 --fecha-final 10/01/1999 --from USD --reintentos 5
```

Parámetros:

- `--fecha-inicial` (obligatorio)
- `--fecha-final` (obligatorio)
- `--from` (`ARS` o `USD`, opcional)
- `--reintentos` (default `3`)
