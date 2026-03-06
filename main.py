"""
API Divisas - Lee Cotizacion Divisas
Reads currency quotations from the Frankfurter public API.
"""

from datetime import date
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Query

BASE_URL = "https://api.frankfurter.app"

app = FastAPI(
    title="API Divisas",
    description="Lee Cotizacion Divisas - Reads currency quotations",
    version="1.0.0",
)


async def _get(path: str, params: Optional[dict] = None) -> dict:
    """Perform a GET request to the Frankfurter API."""
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(f"{BASE_URL}{path}", params=params, timeout=10)
            response.raise_for_status()
            return response.json()
        except httpx.HTTPStatusError as exc:
            raise HTTPException(
                status_code=exc.response.status_code,
                detail=f"Error from upstream service: {exc.response.text}",
            ) from exc
        except httpx.RequestError as exc:
            raise HTTPException(
                status_code=503,
                detail=f"Could not reach currency service: {exc}",
            ) from exc


@app.get("/divisas", summary="List available currencies")
async def listar_divisas():
    """Return all available currency codes and their full names."""
    data = await _get("/currencies")
    return {"divisas": data}


@app.get("/divisas/latest", summary="Latest exchange rates")
async def cotizacion_actual(
    base: str = Query("USD", description="Base currency code (e.g. USD, EUR, ARS)"),
    destino: Optional[str] = Query(
        None, description="Comma-separated target currency codes (e.g. EUR,ARS,BRL)"
    ),
):
    """
    Return the latest exchange rates for the given base currency.

    - **base**: Source currency (default: USD)
    - **destino**: Target currencies, comma-separated (optional; returns all if omitted)
    """
    params: dict = {"from": base.upper()}
    if destino:
        params["to"] = destino.upper()
    data = await _get("/latest", params)
    return {
        "base": data.get("base"),
        "fecha": data.get("date"),
        "cotizaciones": data.get("rates", {}),
    }


@app.get("/divisas/historico", summary="Historical exchange rates")
async def cotizacion_historica(
    fecha: date = Query(..., description="Date in YYYY-MM-DD format"),
    base: str = Query("USD", description="Base currency code (e.g. USD, EUR, ARS)"),
    destino: Optional[str] = Query(
        None, description="Comma-separated target currency codes (e.g. EUR,ARS,BRL)"
    ),
):
    """
    Return exchange rates for a specific historical date.

    - **fecha**: The date to query (YYYY-MM-DD)
    - **base**: Source currency (default: USD)
    - **destino**: Target currencies, comma-separated (optional; returns all if omitted)
    """
    params: dict = {"from": base.upper()}
    if destino:
        params["to"] = destino.upper()
    data = await _get(f"/{fecha}", params)
    return {
        "base": data.get("base"),
        "fecha": data.get("date"),
        "cotizaciones": data.get("rates", {}),
    }


@app.get("/divisas/periodo", summary="Exchange rates over a date range")
async def cotizacion_periodo(
    inicio: date = Query(..., description="Start date in YYYY-MM-DD format"),
    fin: date = Query(..., description="End date in YYYY-MM-DD format"),
    base: str = Query("USD", description="Base currency code (e.g. USD, EUR, ARS)"),
    destino: Optional[str] = Query(
        None, description="Comma-separated target currency codes (e.g. EUR,ARS,BRL)"
    ),
):
    """
    Return exchange rates for every available date within a date range.

    - **inicio**: Start date (YYYY-MM-DD)
    - **fin**: End date (YYYY-MM-DD)
    - **base**: Source currency (default: USD)
    - **destino**: Target currencies, comma-separated (optional; returns all if omitted)
    """
    if inicio > fin:
        raise HTTPException(
            status_code=400, detail="'inicio' must be earlier than or equal to 'fin'."
        )
    params: dict = {"from": base.upper()}
    if destino:
        params["to"] = destino.upper()
    data = await _get(f"/{inicio}..{fin}", params)
    return {
        "base": data.get("base"),
        "inicio": str(inicio),
        "fin": str(fin),
        "cotizaciones": data.get("rates", {}),
    }
