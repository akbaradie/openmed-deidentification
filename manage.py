"""Thin auth shim around openmed's bundled FastAPI service.

openmed.service.app has no built-in authentication (see
https://openmed.life/docs/rest-service/). This module re-exports that exact
app -- no endpoints reimplemented -- and adds one thing: every request must
carry a matching X-API-Key header, except the platform health-check paths
and the API documentation pages. Same enforcement on a VM (behind Caddy,
which now only does TLS) and on Cloud Run (deployed directly, no reverse
proxy needed), so auth behavior doesn't depend on where this runs.

Entrypoint: `uvicorn manage:app`.
"""

from __future__ import annotations

import hmac
import os

from fastapi.openapi.utils import get_openapi
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from openmed.service.app import app

# /docs, /redoc, /openapi.json only expose the API's shape (endpoint names,
# request/response schemas) -- no PHI, no data. Left open so the docs are
# browsable without a key. The "Try it out" calls Swagger UI makes still go
# through this same middleware like any other request, so they 401 without
# a key regardless -- this only exempts *viewing* the schema.
_UNAUTHENTICATED_PATHS = {"/health", "/livez", "/readyz", "/docs", "/redoc", "/openapi.json"}

_API_KEY = os.environ.get("OPENMED_API_KEY", "")
if not _API_KEY:
    raise RuntimeError(
        "OPENMED_API_KEY is not set. Refusing to start a PHI-handling "
        "service without authentication -- set it in .env (VM) or as a "
        "Cloud Run env var / secret before deploying."
    )


class ApiKeyMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path not in _UNAUTHENTICATED_PATHS:
            provided = request.headers.get("x-api-key", "")
            if not hmac.compare_digest(provided, _API_KEY):
                return JSONResponse(
                    {"error": {"code": "unauthorized", "message": "missing or invalid X-API-Key"}},
                    status_code=401,
                )
        return await call_next(request)


app.add_middleware(ApiKeyMiddleware)


def _openapi_with_api_key_auth() -> dict:
    """Declare X-API-Key as a security scheme purely so Swagger UI shows an
    Authorize button. Enforcement is still the middleware above -- FastAPI
    never validates this itself, since these routes have no `Depends()` on
    it. This just lets you authorize once in /docs and have every
    "Try it out" call carry the header automatically, instead of having no
    field to enter it in at all.
    """
    if app.openapi_schema:
        return app.openapi_schema

    schema = get_openapi(title=app.title, version=app.version, description=app.description, routes=app.routes)
    schema.setdefault("components", {}).setdefault("securitySchemes", {})["ApiKeyAuth"] = {
        "type": "apiKey",
        "in": "header",
        "name": "X-API-Key",
    }
    for path, operations in schema.get("paths", {}).items():
        if path in _UNAUTHENTICATED_PATHS:
            continue
        for operation in operations.values():
            if isinstance(operation, dict):
                operation.setdefault("security", []).append({"ApiKeyAuth": []})

    app.openapi_schema = schema
    return app.openapi_schema


app.openapi = _openapi_with_api_key_auth
