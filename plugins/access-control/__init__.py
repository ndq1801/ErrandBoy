"""access-control: per-user x per-tool permission for the ErrandBoy gateway.

Mirrors assistant-bot's two-tier model:
  tier 1: TELEGRAM_ALLOWED_USERS gates who may chat with the bot (native).
  tier 2: this plugin gates which state-changing MCP tools each user may call.

Control layers added for the ErrandBoy gateway:
  tier 3: built-in file-write tools (write_file/patch) are gated by target
          path — /app/** is hard-blocked (infrastructure is immutable;
          change it via the repo and redeploy), and the defined-source files
          (config.yaml/.env/SOUL.md/cli-config.yaml) are hard-blocked
          anywhere they live, reverted on every boot by entrypoint.sh.
          $HERMES_HOME, /tmp and DEV_PROJECTS_ROOTS (e.g. /root/projects, a
          Docker volume persisted across redeploys) are allowed; any other
          path requires the user's approval in chat.
  tier 4: terminal commands that reference /app or a defined-source file are
          hard-blocked (regardless of read/write intent); use the dedicated
          read_file/search_files tools instead.
  Cron management (the cronjob tool and `hermes cron ...` shell commands) is
  pre-authorized: the agent may create/update/pause/resume/remove/run jobs
  without user approval.

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
    # obsidian (mutations only; reads are harmless)
    "__create_note",
    "__append_note",
    "__update_note",
    "__delete_note",
    # calendar (mutations only; reads are harmless)
    "__create_event",
    "__update_event",
    "__delete_event",
)

# Built-in file-write tools (file toolset); read_file/search_files are
# read-only and stay ungated.
WRITE_TOOLS = ("write_file", "patch")

# Defined-source files: source-controlled, change via repo + redeploy, and
# reverted on every boot by entrypoint.sh. NEVER touchable, wherever they live
# (including copies under $HERMES_HOME). Runtime state (memory/skills/cron)
# is NOT in this set and stays freely writable by the agent.
PROTECTED_BASENAMES = ("config.yaml", ".env", "SOUL.md", "cli-config.yaml")

# Dev project roots: agent-editable code checked out here (persisted via the
# projects_data Docker volume, so it survives redeploys). Unlike the /app
# image, these are not infrastructure — writes are auto-allowed.
DEV_PROJECTS_ROOTS = ("/root/projects",)

# Tokens that mark a terminal command as touching /app or a defined-source
# file. Any match blocks the command outright (even read-only ones) — the
# agent has read_file/search_files for that.
SHELL_BLOCK_TOKENS = ("/app",) + PROTECTED_BASENAMES


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
    basename = os.path.basename(p)
    if basename in PROTECTED_BASENAMES:
        return {
            "action": "block",
            "message": f"BLOCKED: {basename} is a defined-source file (change it via the ErrandBoy repo and redeploy).",
        }
    home = _hermes_home()
    if p == home or p.startswith(home + "/"):
        return None  # Runtime state under $HERMES_HOME (skills, scripts, ...)
    if p == "/tmp" or p.startswith("/tmp/"):
        return None  # Scratch space for one-off scripts
    for root in DEV_PROJECTS_ROOTS:
        if p == root or p.startswith(root + "/"):
            return None  # Dev projects (persisted volume) the agent may edit
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


def _patch_payload_references_protected(args):
    """A mode='patch' payload embeds target paths as text (*** Update File:
    <path>); scan it for defined-source basenames and block if found."""
    return any(b in str((args or {}).get("patch") or "") for b in PROTECTED_BASENAMES)


def _gate_terminal_command(command):
    """Return a block action for a terminal command that references /app or a
    defined-source file, or None to allow. Any match blocks regardless of
    read/write intent; the agent should use read_file/search_files instead."""
    cmd = str(command or "").strip()
    if not cmd:
        return None
    for token in SHELL_BLOCK_TOKENS:
        if token in cmd:
            return {
                "action": "block",
                "message": f"BLOCKED: shell command references '{token}' (protected path/file). Change via the ErrandBoy repo and redeploy.",
            }
    return None


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
            if target is None and _patch_payload_references_protected(args):
                return {
                    "action": "block",
                    "message": "BLOCKED: patch payload references a defined-source file (change it via the ErrandBoy repo and redeploy).",
                }
        else:
            target = (args or {}).get("path")
        return _gate_write_path(target)

    # Tier 4: terminal commands touching protected paths/files are blocked.
    if tool_name == "terminal":
        return _gate_terminal_command((args or {}).get("command"))

    return None


def register(ctx):
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
