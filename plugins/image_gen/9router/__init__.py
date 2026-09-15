"""9router image generation backend.

Text-to-image sends a plain OpenAI-wire request to the self-hosted 9router
gateway:

    POST {ROUTER9_BASE_URL}/images/generations
    Authorization: Bearer {ROUTER9_API_KEY}
    {"model": "<image_gen.model>", "prompt": ..., "size": ..., "n": 1}

The model id is whatever `image_gen.model` holds — a 9router combo name — so the
actual upstream image model is chosen on the gateway, not here. Responses are
accepted in either OpenAI shape (`data[].b64_json` or `data[].url`).

Image-to-image uses the multimodal chat route instead:

    POST {ROUTER9_BASE_URL}/chat/completions
    {"model": "<ROUTER9_IMAGE_EDIT_MODEL>",
     "messages": [{"role": "user", "content": [{"type": "text", ...},
       {"type": "image_url", ...}, ...]}],
     "modalities": ["image", "text"],
     "image_config": {"aspect_ratio": "16:9"},
     "stream": false}

The generated image is read back from `choices[0].message.images[0].image_url.url`
(a base64 data URI); a list `message.content` part of type `image_url` and a raw
`data:image/...` string in `message.content` are also accepted. The images route
cannot be used for edits: 9router's openai-family adapter whitelists only
`model, prompt, n, size` and silently drops source-image fields, so
`POST /images/generations` with `image`/`images` returns HTTP 200 with a fresh
text-to-image result and the source ignored, and `/images/edits` does not exist.
Because a request that loses the source image still looks like a success on the
wire, editing is only offered once an edit-capable target is configured — see
`capabilities()` — and a chat reply that carries no image is reported as an
error instead of being passed off as a result.

The edit model comes from `ROUTER9_IMAGE_EDIT_MODEL` (a model id OR a combo whose
members are all edit-capable, so the image model can be swapped on the gateway
alone).

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
    ROUTER9_IMAGE_EDIT_MODEL=...       # optional; edit-capable model or combo, enables image input
"""

from __future__ import annotations

import base64
import logging
import mimetypes
from pathlib import Path
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
MAX_SOURCE_IMAGES = 3

# OpenAI image sizes per tool aspect ratio.
SIZE_BY_ASPECT = {
    "landscape": "1536x1024",
    "square": "1024x1024",
    "portrait": "1024x1536",
}

# OpenRouter chat image_config aspect ratio per tool aspect ratio.
IMAGE_CONFIG_ASPECT = {"landscape": "16:9", "square": "1:1", "portrait": "9:16"}


def _base_url() -> str:
    return (get_secret("ROUTER9_BASE_URL") or "").strip().rstrip("/")


def _api_key() -> str:
    return (get_secret("ROUTER9_API_KEY") or "").strip()


def _edit_model() -> str:
    """Edit-capable model id or combo; empty means image input is not configured."""
    return (get_secret("ROUTER9_IMAGE_EDIT_MODEL") or "").strip()


def _source_image_ref(source: str) -> Optional[str]:
    """Normalise a source image into a reference the gateway can read.

    Data URIs and public http(s) URLs pass through untouched; local file paths
    are inlined as data URIs because the gateway cannot read this host's disk.
    """
    value = (source or "").strip()
    if not value:
        return None
    if value.startswith(("data:", "http://", "https://")):
        return value
    path = Path(value)
    if not path.is_file():
        return None
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    mime = mimetypes.guess_type(path.name)[0] or "image/png"
    return f"data:{mime};base64,{base64.b64encode(raw).decode('ascii')}"


def _image_ref(item: Any) -> Optional[str]:
    """Extract a non-empty image URL string from an image entry or content part."""
    if isinstance(item, str):
        return item.strip() or None
    if not isinstance(item, dict):
        return None
    image_url = item.get("image_url")
    if isinstance(image_url, str):
        return image_url.strip() or None
    if isinstance(image_url, dict):
        url = image_url.get("url")
        if isinstance(url, str):
            return url.strip() or None
    return None


def _extract_edit_image(message: Dict[str, Any]) -> Optional[str]:
    """Pull the first usable image reference out of a chat completion message.

    Producers differ in where they put the generated image, so the known shapes
    are tried in order: `message.images` (any index), then an `image_url` part in
    a list `message.content`, then a raw `data:image/...` string.
    """
    images = message.get("images")
    if isinstance(images, list):
        for item in images:
            ref = _image_ref(item)
            if ref:
                return ref
    content = message.get("content")
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and part.get("type") == "image_url":
                ref = _image_ref(part)
                if ref:
                    return ref
    elif isinstance(content, str) and content.startswith("data:image/"):
        return content
    return None


def _edit_failure_message(model_id: str, choice: Dict[str, Any], message: Dict[str, Any]) -> str:
    """Describe a chat edit reply that carried no image, loudly enough to debug."""
    text = message.get("refusal")
    if not text:
        content = message.get("content")
        if isinstance(content, list):
            text = " ".join(
                part.get("text", "")
                for part in content
                if isinstance(part, dict) and isinstance(part.get("text"), str)
            )
        else:
            text = content
    details = [f"model '{model_id}'"]
    finish_reason = choice.get("finish_reason")
    if finish_reason:
        details.append(f"finish_reason={finish_reason}")
    if text:
        details.append(f"text={str(text).strip()[:400]!r}")
    return "9router chat completion returned no image (" + ", ".join(details) + ")."


class NineRouterImageGenProvider(ImageGenProvider):
    """Text-to-image and image editing through the 9router gateway."""

    @property
    def name(self) -> str:
        return PROVIDER_NAME

    @property
    def display_name(self) -> str:
        return "9router"

    def is_available(self) -> bool:
        """The tool only appears when the gateway endpoint and key are configured."""
        return bool(_base_url() and _api_key())

    def capabilities(self) -> Dict[str, Any]:
        """Advertise image input only when an edit-capable model is configured.

        Advertising `image` without a known edit-capable model would let the
        model request an edit that the gateway silently downgrades to a plain
        text-to-image result (HTTP 200, source image ignored).
        """
        if _edit_model():
            return {
                "modalities": ["text", "image"],
                "max_reference_images": 2,
                "max_source_images": MAX_SOURCE_IMAGES,
            }
        return {"modalities": ["text"], "max_reference_images": 0}

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

        def fail(message: str, error_type: str = "provider_error", used_model: Optional[str] = None) -> Dict[str, Any]:
            return error_response(
                error=message,
                error_type=error_type,
                provider=PROVIDER_NAME,
                model=used_model or model_id,
                prompt=prompt,
                aspect_ratio=aspect,
            )

        if not base_url or not api_key:
            return fail(
                "9router image backend is not configured (ROUTER9_BASE_URL / ROUTER9_API_KEY).",
                error_type="configuration_error",
            )

        sources = [image_url] if image_url else []
        sources.extend(reference_image_urls or [])
        sources = sources[:MAX_SOURCE_IMAGES]

        if not sources:
            return self._text_to_image(prompt, aspect, model_id, base_url, api_key, fail)

        edit_model = _edit_model()
        if not edit_model:
            # No edit model configured: failing loudly beats letting the gateway
            # silently ignore the sources and return a text-to-image result.
            return fail(
                "9router image backend is configured for text-to-image only "
                "(set ROUTER9_IMAGE_EDIT_MODEL to an edit-capable model to enable image input).",
                error_type="modality_unsupported",
            )

        resolved = []
        for source in sources:
            ref = _source_image_ref(source)
            if ref is None:
                return fail(
                    f"Source image could not be read: {source!r}",
                    error_type="invalid_source_image",
                )
            resolved.append(ref)

        def edit_fail(message: str, error_type: str = "provider_error") -> Dict[str, Any]:
            return fail(message, error_type=error_type, used_model=edit_model)

        return self._edit(prompt, aspect, edit_model, base_url, api_key, resolved, edit_fail)

    def _text_to_image(
        self,
        prompt: str,
        aspect: str,
        model_id: str,
        base_url: str,
        api_key: str,
        fail,
    ) -> Dict[str, Any]:
        """Text-to-image: plain OpenAI-wire request to `/images/generations`."""
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

    def _edit(
        self,
        prompt: str,
        aspect: str,
        model_id: str,
        base_url: str,
        api_key: str,
        sources: List[str],
        fail,
    ) -> Dict[str, Any]:
        """Image-to-image: multimodal chat completion carrying `image_url` parts.

        The chat route is used because the images route cannot forward the source
        image (see the module docstring). `modalities` is required to get an
        image back, and `size`/`n` are Images-API fields that do not apply here.
        """
        content: List[Dict[str, Any]] = [{"type": "text", "text": prompt}]
        content.extend({"type": "image_url", "image_url": {"url": ref}} for ref in sources)
        payload = {
            "model": model_id,
            "messages": [{"role": "user", "content": content}],
            "modalities": ["image", "text"],
            "image_config": {"aspect_ratio": IMAGE_CONFIG_ASPECT[aspect]},
            # 9router's chat route streams by default when `stream` is absent, which would
            # return SSE instead of a JSON body; the edit response is parsed as JSON.
            "stream": False,
        }
        try:
            response = requests.post(
                f"{base_url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=REQUEST_TIMEOUT,
            )
        except requests.RequestException as exc:
            return fail(f"Request to 9router failed: {exc}")

        if response.status_code >= 400:
            return fail(f"9router returned HTTP {response.status_code}: {response.text[:400]}")

        try:
            data = response.json()
        except ValueError:
            return fail("9router returned a non-JSON response.")

        if not isinstance(data, dict) or not data.get("choices"):
            return fail(f"9router returned no completion choices for the image edit (model '{model_id}').")

        choice: Dict[str, Any] = data["choices"][0] if isinstance(data["choices"][0], dict) else {}
        message: Dict[str, Any] = {}
        if isinstance(choice.get("message"), dict):
            message = choice["message"]
        candidate = _extract_edit_image(message)
        if not candidate:
            return fail(_edit_failure_message(model_id, choice, message))

        prefix = f"9router_{model_id}".replace("/", "_")
        try:
            if candidate.startswith(("http://", "https://")):
                image_path = save_url_image(candidate, prefix=prefix)
            elif candidate.startswith("data:"):
                image_path = save_b64_image(candidate.split(",", 1)[1], prefix=prefix)
            else:
                image_path = save_b64_image(candidate, prefix=prefix)
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
