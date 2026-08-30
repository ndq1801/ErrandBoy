# AGENTS.md — Coding conventions for ErrandBoy

Guidelines for AI agents and humans editing this repo. Follow these when
changing code; when in doubt, favor the smallest diff that follows the pattern
already established here.

## Communication & language

- All code comments and commit messages are written in English.
- The maintainer communicates with agents in Vietnamese — respond in Vietnamese
  in chat, but keep everything written into files/comments in English.

## Scope & changes

- Only modify exactly what was requested. Do not refactor, optimize, or change
  unrelated code unless explicitly asked.
- Prefer minimal changes (smallest possible diff). Match the existing style,
  structure, and conventions of the file you are editing.
- Do not introduce new patterns, libraries, or styles unless requested.
- If the request is unclear, ask instead of assuming.

## Execution constraints

- Do not run commands that deploy or mutate the VPS unless explicitly asked.
- When deployment is needed, provide/execute the compose command on the VPS
  (`/srv/errandboy`) and verify the container is healthy afterwards.

## Path convention — single source of truth (IMPORTANT)

Container-internal paths shared by **2+ systems** (docker-compose, entrypoint,
plugins, configs) MUST follow this 3-layer rule:

1. **`.env`** (host) — the ONLY place the real value is assigned.
   Document the default in `.env.example` (value + why it exists).
2. **`docker-compose.yml`** — interpolate `${VAR}` only. NEVER hardcode a
   shared container path in compose.
3. **Python plugin / runtime code** — read the env var with exactly one
   fallback: `os.environ.get("VAR") or "<default>"`.

The default literal therefore appears at most ONCE per consumer, and the real
value is changed in a single place (`.env`).

Established variables (already migrated):

| Env var | Default | Consumers |
|---|---|---|
| `OBSIDIAN_VAULT_PATH` | `/root/obsidian-vault` | compose mount, entrypoint, cli-config, access-control plugin |
| `DEV_PROJECTS_PATH` | `/root/projects` | compose mount, access-control plugin |
| `TOOLS_ROOT` | `/opt/tools` | compose mount, entrypoint (mkdir/PATH/coding_instructions), access-control plugin |
| `HERMES_HOME` | `/root/.hermes` | compose mount + GIT_CONFIG_GLOBAL, entrypoint, access-control plugin |

Keep these literal (do not env-ify) — they are single-context or fixed by the
image:

- `/app` and everything under `/app/mcp-hub/*` — immutable image infrastructure.
- `EPHEMERAL_BIN_PATHS` (`/usr/local/bin`, `/usr/bin`, `/root/.local/bin`) —
  only the access-control plugin references them (block rules).
- Tool state dirs used only in compose: `/root/.config/gh`, `/root/.config/rclone`,
  `/root/.cache/rclone/bisync`, `/usr/bin/rclone`.
- Host-side paths (`/srv/errandboy/...`) — they exist outside the container.
- `/tmp` — universal scratch space.

To add a NEW shared path: add the env var to `.env.example`, reference it in
compose as `${VAR}`, and read it in code as `os.environ.get("VAR") or "<default>"`.
Always verify the VPS `.env` also defines the variable before deploying.

## Access-control plugin specifics

- `plugins/access-control/__init__.py` gates file-write tools by target path:
  allow-listed roots auto-pass, protected paths hard-block, everything else asks
  the user for approval.
- Auto-allowed: `$HERMES_HOME`, `/tmp`, `DEV_PROJECTS_ROOTS`, `TOOLS_ROOT`,
  `OBSIDIAN_VAULT_ROOT`.
- Hard-blocked: `/app/**`, defined-source files (`config.yaml`, `.env`,
  `SOUL.md`, `cli-config.yaml`) anywhere.
- Blocked as ephemeral: `EPHEMERAL_BIN_PATHS`.
- Alternatives of one concept are mutually exclusive: normalize the discriminator
  at the decision point, then branch once. Do not append sibling-case `if`s that
  can both fire for one case.

## Verification

- After changing paths, confirm `docker compose config` resolves cleanly and the
  volume mount targets match the env var values.
- After deploy, spot-check the bot can still read/write the vault
  (`/root/obsidian-vault`) and list its notes without approval prompts.