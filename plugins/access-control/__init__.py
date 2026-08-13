"""access-control: per-user x per-tool permission for the ErrandBoy gateway.

Mirrors assistant-bot's two-tier model:
  tier 1: TELEGRAM_ALLOWED_USERS gates who may chat with the bot (native).
  tier 2: this plugin gates which state-changing MCP tools each user may call.

Policy:
- Tools are matched by suffix (works regardless of the ``mcp_<server>__``
  prefix Hermes generates), so no assumption on tool naming is needed.
- A blocked tool is only denied when the caller is a Telegram user who is
  NOT in the allowed list. Contexts without a user identity (CLI, cron) are
  allowed, matching assistant-bot where scheduled tasks are pre-authorized.
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


def _on_pre_tool_call(tool_name: str, args: dict, task_id: str, **kwargs):
    if not any(tool_name.endswith(s) for s in SENSITIVE_SUFFIXES):
        return None
    uid = _current_user_id()
    if not uid:
        return None  # CLI/cron: pre-authorized
    if uid in _allowed_users():
        return None
    return {
        "action": "block",
        "message": f"BLOCKED: user {uid} is not allowed to call {tool_name}",
    }


def register(ctx):
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
