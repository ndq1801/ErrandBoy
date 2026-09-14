"""9router image generation backend.

Sends a plain OpenAI-wire request to the self-hosted 9router gateway:

    POST {ROUTER9_BASE_URL}/images/generations
    Authorization: Bearer {ROUTER9_API_KEY}
    {"model": "<image_gen.model>", "prompt": ..., "size": ..., "n": 1}

The model id is whatever `image_gen.model` holds — a 9router combo name — so the
actual upstream image model is chosen on the gateway, not here. Responses are
accepted in either OpenAI shape (`data[].b64_json` or `data[].url`).

Config (`$HERMES_HOME/config.yaml`):

    plugins:
      enabled:
        - image_gen/9router
    image_gen:
      provider: 9router
      model: hermes-image

Env (`$HERMES_HOME/.env`):
    ROUTER9_BASE_URL=https://9router.example.com/v1
    ROUTER9_API_KEY=sk-...
    ROUTER9_IMAGE_MODEL=hermes-image   # optional fallback when image_gen.model is unset
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

import requests

from agent.image_gen_provider import (
    DEFAULT_ASPECT_RATIO,
    ImageGenProvider,
    error_response,
    resolve_aspect_ratio,
    save_b64_image,
    save_url_image,
    success_response,
)
from agent.secret_scope import get_secret

logger = logging.getLogger(__name__)

PROVIDER_NAME = "9router"
DEFAULT_MODEL = "hermes-image"
REQUEST_TIMEOUT = 300.0

# OpenAI image sizes per tool aspect ratio.
SIZE_BY_ASPECT = {
    "landscape": "1536x1024",
    "square": "1024x1024",
    "portrait": "1024x1536",
}


def _base_url() -> str:
    return (get_secret("ROUTER9_BASE_URL") or "").strip().rstrip("/")


def _api_key() -> str:
    return (get_secret("ROUTER9_API_KEY") or "").strip()


class NineRouterImageGenProvider(ImageGenProvider):
    """Text-to-image through the 9router gateway."""

    @property
    def name(self) -> str:
        return PROVIDER_NAME

    @property
    def display_name(self) -> str:
        return "9router"

    def is_available(self) -> bool:
        """The tool only appears when the gateway endpoint and key are configured."""
        return bool(_base_url() and _api_key())

    def generate(
        self,
        prompt: str,
        aspect_ratio: str = DEFAULT_ASPECT_RATIO,
        *,
        model: Optional[str] = None,
        image_url: Optional[str] = None,
        reference_image_urls: Optional[List[str]] = None,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        aspect = resolve_aspect_ratio(aspect_ratio)
        model_id = (model or "").strip() or (get_secret("ROUTER9_IMAGE_MODEL") or "").strip() or DEFAULT_MODEL
        base_url = _base_url()
        api_key = _api_key()

        def fail(message: str, error_type: str = "provider_error") -> Dict[str, Any]:
            return error_response(
                error=message,
                error_type=error_type,
                provider=PROVIDER_NAME,
                model=model_id,
                prompt=prompt,
                aspect_ratio=aspect,
            )

        if not base_url or not api_key:
            return fail(
                "9router image backend is not configured (ROUTER9_BASE_URL / ROUTER9_API_KEY).",
                error_type="configuration_error",
            )
        if image_url or reference_image_urls:
            # Image-to-image is not wired up; failing loudly beats silently ignoring
            # the caller's source images.
            return fail(
                "9router image backend does not support image input yet.",
                error_type="modality_unsupported",
            )

        payload = {
            "model": model_id,
            "prompt": prompt,
            "size": SIZE_BY_ASPECT[aspect],
            "n": 1,
        }
        try:
            response = requests.post(
                f"{base_url}/images/generations",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=REQUEST_TIMEOUT,
            )
        except requests.RequestException as exc:
            return fail(f"Request to 9router failed: {exc}")

        if response.status_code >= 400:
            return fail(f"9router returned HTTP {response.status_code}: {response.text[:400]}")

        try:
            data = response.json().get("data") or []
        except ValueError:
            return fail("9router returned a non-JSON response.")

        if not data or not isinstance(data[0], dict):
            return fail(
                f"9router returned no image data (model '{model_id}' may not be an image model)."
            )

        first = data[0]
        b64_data = first.get("b64_json")
        remote_url = first.get("url")
        prefix = f"9router_{model_id}".replace("/", "_")

        try:
            if b64_data:
                image_path = save_b64_image(b64_data, prefix=prefix)
            elif remote_url:
                image_path = save_url_image(remote_url, prefix=prefix)
            else:
                return fail("9router response contained neither b64_json nor url.")
        except Exception as exc:  # storage/network failures must surface as a tool error
            return fail(f"Failed to store the generated image: {exc}")

        return success_response(
            image=str(image_path),
            model=model_id,
            prompt=prompt,
            aspect_ratio=aspect,
            provider=PROVIDER_NAME,
        )


def register(ctx) -> None:
    """Plugin entry point — called once at load time."""
    ctx.register_image_gen_provider(NineRouterImageGenProvider())
