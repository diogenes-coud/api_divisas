"""Tests for API Divisas (Lee Cotizacion Divisas)."""

from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from httpx import Request, Response

from main import app

client = TestClient(app)

# ---------------------------------------------------------------------------
# Sample data returned by the Frankfurter API
# ---------------------------------------------------------------------------

CURRENCIES_RESPONSE = {
    "ARS": "Argentine Peso",
    "BRL": "Brazilian Real",
    "EUR": "Euro",
    "USD": "US Dollar",
}

LATEST_RESPONSE = {
    "amount": 1.0,
    "base": "USD",
    "date": "2024-01-15",
    "rates": {"EUR": 0.9183, "BRL": 4.9478, "ARS": 814.97},
}

HISTORICAL_RESPONSE = {
    "amount": 1.0,
    "base": "USD",
    "date": "2023-06-01",
    "rates": {"EUR": 0.9258, "BRL": 4.9867},
}

PERIOD_RESPONSE = {
    "amount": 1.0,
    "base": "USD",
    "start_date": "2024-01-10",
    "end_date": "2024-01-12",
    "rates": {
        "2024-01-10": {"EUR": 0.9175},
        "2024-01-11": {"EUR": 0.9180},
        "2024-01-12": {"EUR": 0.9183},
    },
}


# ---------------------------------------------------------------------------
# Helper: build an httpx.Response that the mock will return
# ---------------------------------------------------------------------------


def _httpx_response(data: dict, status_code: int = 200) -> Response:
    import json

    return Response(
        status_code=status_code,
        content=json.dumps(data).encode(),
        headers={"content-type": "application/json"},
        request=Request("GET", "https://api.frankfurter.app/test"),
    )


# ---------------------------------------------------------------------------
# /divisas  (list currencies)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_listar_divisas():
    mock_response = _httpx_response(CURRENCIES_RESPONSE)
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = mock_response
        response = client.get("/divisas")

    assert response.status_code == 200
    body = response.json()
    assert "divisas" in body
    assert body["divisas"]["USD"] == "US Dollar"
    assert body["divisas"]["EUR"] == "Euro"


# ---------------------------------------------------------------------------
# /divisas/latest
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cotizacion_actual_default_base():
    mock_response = _httpx_response(LATEST_RESPONSE)
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = mock_response
        response = client.get("/divisas/latest")

    assert response.status_code == 200
    body = response.json()
    assert body["base"] == "USD"
    assert "cotizaciones" in body
    assert "EUR" in body["cotizaciones"]


@pytest.mark.asyncio
async def test_cotizacion_actual_custom_base_and_destino():
    mock_response = _httpx_response(
        {"amount": 1.0, "base": "EUR", "date": "2024-01-15", "rates": {"USD": 1.0888}}
    )
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = mock_response
        response = client.get("/divisas/latest?base=EUR&destino=USD")

    assert response.status_code == 200
    body = response.json()
    assert body["base"] == "EUR"
    assert "USD" in body["cotizaciones"]


# ---------------------------------------------------------------------------
# /divisas/historico
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cotizacion_historica():
    mock_response = _httpx_response(HISTORICAL_RESPONSE)
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = mock_response
        response = client.get("/divisas/historico?fecha=2023-06-01")

    assert response.status_code == 200
    body = response.json()
    assert body["fecha"] == "2023-06-01"
    assert "cotizaciones" in body


@pytest.mark.asyncio
async def test_cotizacion_historica_missing_fecha():
    response = client.get("/divisas/historico")
    assert response.status_code == 422  # Unprocessable entity - fecha is required


# ---------------------------------------------------------------------------
# /divisas/periodo
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cotizacion_periodo():
    mock_response = _httpx_response(PERIOD_RESPONSE)
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value = mock_response
        response = client.get(
            "/divisas/periodo?inicio=2024-01-10&fin=2024-01-12&base=USD&destino=EUR"
        )

    assert response.status_code == 200
    body = response.json()
    assert body["inicio"] == "2024-01-10"
    assert body["fin"] == "2024-01-12"
    assert "cotizaciones" in body


@pytest.mark.asyncio
async def test_cotizacion_periodo_inicio_despues_de_fin():
    response = client.get("/divisas/periodo?inicio=2024-01-15&fin=2024-01-10")
    assert response.status_code == 400
    assert "inicio" in response.json()["detail"].lower()
