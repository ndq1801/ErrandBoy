#!/usr/bin/env python3
"""wakeAgent gate: only wake the agent once the user's local hour has passed.

Hermes cron jobs have no per-job timezone and run in the gateway timezone
(config.yaml ``timezone``). For a job that must fire at a user's local time,
attach this script as the job's ``script`` (gate) field; the scheduler parses
the LAST non-empty stdout line as JSON and skips the tick when
``{"wakeAgent": false}`` (no LLM call, no delivery).

Example (via ``hermes cron create``):
    hermes cron create "0 8 * * *" \\
        --script check_user_hour.py \\
        --prompt "Remind me to do X" \\
        --deliver telegram \\
        --name "morning-reminder"

Note: gate scripts run with a sanitized environment (no secrets), so the
target hour/timezone are hardcoded below; edit per use case or read from a
non-secret config file.
"""

import json
from datetime import datetime
from zoneinfo import ZoneInfo

USER_TZ = "Asia/Ho_Chi_Minh"
TARGET_HOUR = 8  # wake only at or after this local hour


def main() -> None:
    now = datetime.now(ZoneInfo(USER_TZ))
    print(json.dumps({"wakeAgent": now.hour >= TARGET_HOUR}))


if __name__ == "__main__":
    main()
