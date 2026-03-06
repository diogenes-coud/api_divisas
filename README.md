# api_divisas
Lee Cotizacion Divisas

REST API construida con **FastAPI** que lee cotizaciones de divisas usando la API pública [Frankfurter](https://www.frankfurter.app/).

## Requisitos

- Python 3.10+
- Instalar dependencias:

```bash
pip install -r requirements.txt
```

## Ejecución

```bash
uvicorn main:app --reload
```

La documentación interactiva estará disponible en <http://localhost:8000/docs>.

## Endpoints

| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/divisas` | Lista todas las divisas disponibles |
| GET | `/divisas/latest` | Cotización actual |
| GET | `/divisas/historico` | Cotización en una fecha específica |
| GET | `/divisas/periodo` | Cotizaciones en un rango de fechas |

### Parámetros comunes

| Parámetro | Tipo | Por defecto | Descripción |
|-----------|------|-------------|-------------|
| `base` | string | `USD` | Divisa de origen |
| `destino` | string | *(todas)* | Divisas de destino separadas por coma |

### Ejemplos

```bash
# Cotización actual de USD a EUR y ARS
curl "http://localhost:8000/divisas/latest?base=USD&destino=EUR,ARS"

# Cotización histórica
curl "http://localhost:8000/divisas/historico?fecha=2023-06-01&base=EUR"

# Cotizaciones en un periodo
curl "http://localhost:8000/divisas/periodo?inicio=2024-01-10&fin=2024-01-12&base=USD&destino=EUR"
```

## Tests

```bash
pytest tests/
```
