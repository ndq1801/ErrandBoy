"""access-control: per-user x per-tool permission for the ErrandBoy gateway.

Mirrors assistant-bot's two-tier model:
  tier 1: TELEGRAM_ALLOWED_USERS gates who may chat with the bot (native).
  tier 2: this plugin gates which state-changing MCP tools each user may call.

Control layers added for the ErrandBoy gateway:
  tier 3: built-in file-write tools (write_file/patch) are gated by target
          path — /app/** is hard-blocked (infrastructure is immutable;
          change it via the repo and redeploy), $HERMES_HOME and /tmp are
          allowed (except .env files, which always require approval), any
          other path requires the user's approval in chat.
  tier 4: the cronjob tool (any action except list) requires approval, so
          scheduled automation can only be created or changed with explicit
          user consent.

Policy notes:
- Tools are matched by suffix (works regardless of the ``mcp_<server>__``
  prefix Hermes generates), so no assumption on tool naming is needed.
- A blocked tool is only denied when the caller is a Telegram user who is
  NOT in the allowed list. Contexts without a user identity (CLI, cron) are
  allowed, matching assistant-bot where scheduled tasks are pre-authorized.
- Cron sessions are non-interactive: anything that needs approval fails
  closed (approvals.cron_mode: deny), so pre-authorized cron jobs must stay
  within MCP/read tools or no_agent scripts.
"""

import os

# Suffixes of state-changing tools (finlog + daily-report writes/deletes).
# Anything not matching these suffixes is never touched by this plugin.
SENSITIVE_SUFFIXES = (
    # daily-report
    "__submit_daily_report",
    "__submit_request",
    "__register_overtime",
    "__delete_record",
    "__post_data",
    # finlog (mutations only; reads are harmless)
    "__add_expense",
    "__add_income",
    "__add_loan",
    "__add_lending",
    "__add_transactions_bulk",
    "__pay_loan",
    "__collect_lending",
    "__delete_transactions",
    "__update_transaction_category",
    "__update_user_settings",
    "__delete_user",
    "__update_user",
    "__add_category",
    "__update_category",
    "__delete_category",
)

# Built-in file-write tools (file toolset); read_file/search_files are
# read-only and stay ungated.
WRITE_TOOLS = ("write_file", "patch")

# Built-in tool that manages cron jobs. Only ``list`` is read-only.
CRON_TOOL = "cronjob"
CRON_READ_ACTIONS = ("list",)


def _allowed_users() -> set:
    raw = os.environ.get("ACCESS_CONTROL_ALLOWED_USERS") or os.environ.get("TELEGRAM_ALLOWED_USERS") or ""
    return {u.strip() for u in raw.split(",") if u.strip()}


def _current_user_id() -> str:
    """Telegram user id of the message being handled (gateway mode).

    Empty when the call comes from CLI/cron (no active session) -> allowed.
    """
    try:
        from gateway.session_context import get_session_env
        return (get_session_env("HERMES_SESSION_USER_ID") or "").strip()
    except Exception:
        return ""


def _hermes_home() -> str:
    home = os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
    return home.replace("\\", "/").rstrip("/")


def _gate_write_path(path):
    """Return an approval action for a write tool call, or None to allow."""
    p = str(path or "").replace("\\", "/")
    if not p:
        # Unknown target — fail closed: ask the user.
        return {"action": "approve", "message": "File write without a clear path — please confirm."}
    if p == "/app" or p.startswith("/app/"):
        return {
            "action": "block",
            "message": "BLOCKED: /app is immutable infrastructure. Change it via the ErrandBoy repo and redeploy.",
        }
    if os.path.basename(p) == ".env":
        # Secrets file — always needs explicit user approval.
        return {"action": "approve", "message": f"Write to secrets file {p} requires your approval."}
    home = _hermes_home()
    if p == home or p.startswith(home + "/"):
        return None  # Runtime state under $HERMES_HOME (skills, scripts, ...)
    if p == "/tmp" or p.startswith("/tmp/"):
        return None  # Scratch space for one-off scripts
    return {"action": "approve", "message": f"Write outside allowed paths: {p} — approve or deny?"}


def _patch_target_path(args):
    """Extract the target path from a patch call.

    mode='replace' carries ``path``; mode='patch' embeds the target paths
    inside the patch payload (*** Update File: <path>), which we treat as
    needing approval rather than parsing.
    """
    mode = (args or {}).get("mode") or "replace"
    if mode == "replace":
        return (args or {}).get("path")
    return None  # patch-format payload -> falls back to approval


def _on_pre_tool_call(tool_name: str, args: dict, task_id: str, **kwargs):
    # Tier 2: MCP state-changing tools.
    if any(tool_name.endswith(s) for s in SENSITIVE_SUFFIXES):
        uid = _current_user_id()
        if not uid:
            return None  # CLI/cron: pre-authorized
        if uid in _allowed_users():
            return None
        return {
            "action": "block",
            "message": f"BLOCKED: user {uid} is not allowed to call {tool_name}",
        }

    # Tier 3: built-in file-write tools gated by target path.
    if tool_name in WRITE_TOOLS:
        if tool_name == "patch":
            target = _patch_target_path(args)
        else:
            target = (args or {}).get("path")
        return _gate_write_path(target)

    # Tier 4: cron management (anything but listing) needs user consent.
    if tool_name == CRON_TOOL:
        action = (args or {}).get("action", "")
        if action in CRON_READ_ACTIONS:
            return None
        return {"action": "approve", "message": f"cronjob '{action}' requires your approval."}

    return None


def register(ctx):
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
