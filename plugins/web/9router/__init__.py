"""9router web search/extract backend.

Routes Hermes' built-in ``web_search`` / ``web_extract`` tools through the
self-hosted 9router gateway instead of calling each vendor directly:

    POST {ROUTER9_BASE_URL}/search     {"model": <search combo>, "query": ..., "max_results": ...}
    POST {ROUTER9_BASE_URL}/web/fetch  {"model": <fetch combo>,  "url": ..., "format": "markdown"}

Both calls authenticate with ``ROUTER9_API_KEY``; vendor keys (Brave, Jina,
...) stay on the gateway. Combo names are read from:

    ROUTER9_WEB_SEARCH_MODEL   (default: search-combo)
    ROUTER9_WEB_FETCH_MODEL    (default: fetch-combo)

Config (``$HERMES_HOME/config.yaml``):

    web:
      backend: 9router
    plugins:
      enabled:
        - web/9router
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List

import httpx

from agent.web_search_provider import WebSearchProvider, get_provider_env

logger = logging.getLogger(__name__)

PROVIDER_NAME = "9router"
DEFAULT_SEARCH_MODEL = "search-combo"
DEFAULT_FETCH_MODEL = "fetch-combo"
SEARCH_TIMEOUT = 30.0
FETCH_TIMEOUT = 60.0


def _base_url() -> str:
    return (get_provider_env("ROUTER9_BASE_URL") or "").strip().rstrip("/")


def _api_key() -> str:
    return (get_provider_env("ROUTER9_API_KEY") or "").strip()


def _model(env_name: str, default: str) -> str:
    return (get_provider_env(env_name) or "").strip() or default


def _headers() -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {_api_key()}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


class NineRouterWebProvider(WebSearchProvider):
    """Search + extract through the 9router gateway."""

    @property
    def name(self) -> str:
        return PROVIDER_NAME

    @property
    def display_name(self) -> str:
        return "9router (search + fetch)"

    def is_available(self) -> bool:
        """The tool only appears when the gateway endpoint and key are configured."""
        return bool(_base_url() and _api_key())

    def supports_search(self) -> bool:
        return True

    def supports_extract(self) -> bool:
        return True

    def search(self, query: str, limit: int = 5) -> Dict[str, Any]:
        try:
            response = httpx.post(
                f"{_base_url()}/search",
                headers=_headers(),
                json={
                    "model": _model("ROUTER9_WEB_SEARCH_MODEL", DEFAULT_SEARCH_MODEL),
                    "query": query,
                    "max_results": max(1, min(int(limit), 20)),
                },
                timeout=SEARCH_TIMEOUT,
            )
            response.raise_for_status()
            payload = response.json()
        except Exception as exc:  # noqa: BLE001 — surface as the legacy failure shape
            logger.warning("9router search failed: %s", exc)
            return {"success": False, "error": f"9router search failed: {exc}"}

        rows: List[Dict[str, Any]] = []
        for index, item in enumerate(payload.get("results") or []):
            if not isinstance(item, dict):
                continue
            rows.append(
                {
                    "title": str(item.get("title") or ""),
                    "url": str(item.get("url") or ""),
                    "description": str(item.get("snippet") or item.get("content") or ""),
                    "position": int(item.get("position") or index + 1),
                }
            )

        if not rows:
            errors = payload.get("errors") or []
            detail = "; ".join(str(err) for err in errors) or "no results returned"
            return {"success": False, "error": f"9router search returned no results: {detail}"}

        return {"success": True, "data": {"web": rows}}

    async def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        fmt = kwargs.get("format") or "markdown"
        model = _model("ROUTER9_WEB_FETCH_MODEL", DEFAULT_FETCH_MODEL)
        base = _base_url()
        headers = _headers()

        results: List[Dict[str, Any]] = []
        async with httpx.AsyncClient(timeout=FETCH_TIMEOUT) as client:
            for url in urls:
                try:
                    response = await client.post(
                        f"{base}/web/fetch",
                        headers=headers,
                        json={"model": model, "url": url, "format": fmt},
                    )
                    response.raise_for_status()
                    payload = response.json()
                    content = payload.get("content")
                    text = content.get("text") if isinstance(content, dict) else content
                    text = text or ""
                    results.append(
                        {
                            "url": payload.get("url") or url,
                            "title": payload.get("title") or "",
                            "content": text,
                            "raw_content": text,
                            "metadata": payload.get("metadata") or {},
                        }
                    )
                except Exception as exc:  # noqa: BLE001 — per-URL failure, never raise
                    logger.warning("9router fetch failed for %s: %s", url, exc)
                    results.append(
                        {
                            "url": url,
                            "title": "",
                            "content": "",
                            "error": f"9router fetch failed: {exc}",
                        }
                    )
        return results


def register(ctx) -> None:
    """Plugin entry point — called once at load time."""
    ctx.register_web_search_provider(NineRouterWebProvider())
