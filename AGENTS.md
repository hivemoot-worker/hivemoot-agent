# AGENTS.md

This file gives provider-agnostic startup context for autonomous agents working in
`hivemoot-agent`.

## Repository Purpose

`hivemoot-agent` is the runtime container that launches autonomous coding agents
against a GitHub repository. The runtime supports Claude, Codex, Gemini, Kilo,
and OpenCode.

## Runtime Architecture

- Entrypoint: `scripts/entrypoint.sh`
- One-shot orchestration: `scripts/run-multi.sh`
- Loop orchestration: `scripts/run-loop.sh`
- Per-agent execution unit: `scripts/run-once.sh`
- Shared shell helpers: `scripts/lib.sh`
- Host controller (per-job worker containers): `scripts/controller.sh`

High-level flow:

1. `entrypoint.sh` loads secrets and selects `RUN_MODE`.
2. `run-multi.sh` or `run-loop.sh` validates config, initializes per-agent state,
   and launches `run-once.sh` per agent.
3. `run-once.sh` prepares isolated workspace and home paths, then runs provider
   CLI tasks for issue/PR/discussion work.

## Provider and Auth Model

`AGENT_PROVIDER` selects the runtime provider (`claude|codex|gemini|kilo|opencode`).

Auth modes:

- `api_key`
- `subscription`
- `auto` (resolved per provider via `resolve_effective_auth_mode` in `scripts/lib.sh`)

Provider secrets can be set inline or via `*_FILE` env vars and are loaded through
`load_provider_secrets` in `scripts/lib.sh`.

## Shell Conventions

Scripts in `scripts/*.sh` are Bash scripts and should follow existing patterns:

- `#!/usr/bin/env bash`
- `set -euo pipefail`
- Use `local` variables inside functions
- Prefer `printf` for structured output/logging
- Use command arrays for safe argument handling
- Reuse shared helpers in `scripts/lib.sh` instead of duplicating logic

## Key Implementation Patterns

Secret loading pattern:

```bash
load_secret_from_file VAR_NAME
```

This reads `VAR_NAME_FILE` when `VAR_NAME` is unset and exports `VAR_NAME`.

Credential seeding pattern:

- `seed_shared_provider_state` copies shared provider state to agent homes
- `seed_provider_auth` copies only auth material (not session state)

Both are defined in `scripts/lib.sh`.

## CI and Quality Gates

The CI workflow (`.github/workflows/ci.yml`) enforces:

- `ShellCheck`
- `Script Validation` (repo test scripts)
- `Hadolint`
- `Compose Config`
- `Env Documentation` (compose vars must exist in `.env.example`)
- `Markdown Lint`
- `Docker Build & Security Scan`
- Provider stage builds for all supported providers

Before opening a PR, run the relevant local checks for changed files.

## Governance Labels

This repository uses Hivemoot governance labels:

- `hivemoot:discussion`
- `hivemoot:voting`
- `hivemoot:ready-to-implement`
- `hivemoot:candidate`
- `hivemoot:merge-ready`

See `.github/hivemoot.yml` for lifecycle rules.

## De-duplication Rule

Before starting a new implementation PR:

1. Check open PRs for the target issue.
2. Prefer improving an existing implementation if it is viable.
3. Open a competing PR only when the existing one is blocked or materially wrong.

Keep issue/PR comments short, decision-oriented, and tied to concrete checks or
code paths.
