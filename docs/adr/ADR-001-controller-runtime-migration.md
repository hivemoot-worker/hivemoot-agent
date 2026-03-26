# ADR-001: Controller Runtime Migration Triggers

- Status: Accepted
- Date: 2026-03-26
- Related issue: #89

## Context

`scripts/controller.sh` is the Phase 2 host-side controller. Today it is a Bash
orchestrator that launches one isolated worker container per job, manages queue
artifacts, and coordinates periodic, mention, and delegated-task flows.

That is still the right default for the current product stage:

- the rest of the runtime is already Bash-first
- operators can run and debug it with standard shell tooling
- shipping one more script is simpler than introducing a second runtime early

The risk is drift. Once the controller starts behaving like a long-lived control
plane instead of a host-side batch orchestrator, shell stops being the simplest
or safest tool. We need an explicit line for when to graduate to a compiled
runtime instead of letting complexity accumulate by accident.

## Decision

Keep the controller in Bash for the Phase 2 MVP. Start a controller-runtime
migration when any of the trigger classes below becomes a committed product
requirement rather than a one-off experiment.

### Trigger Classes

| Trigger | Fires when | Why Bash stops fitting |
| --- | --- | --- |
| `T1` concurrent async control-plane I/O | The controller must coordinate multiple long-lived I/O responsibilities in one process, such as job dispatch plus health delivery plus token minting, with shared cancellation, retry, and backpressure. | Shell polling loops are workable one at a time, but become fragile when several concurrent I/O paths need structured coordination and lifecycle management. |
| `T2` durable controller-owned state | The controller becomes the authoritative owner of queue or state across restarts, or queue scans become an operational bottleneck. The initial threshold is queue artifact count `>1000` together with scan latency `>200ms` on normal runs. | Once correctness depends on durable state, locking, replay, and recovery semantics, filesystem conventions and ad hoc shell cleanup are no longer enough. |
| `T3` externally consumed control-plane endpoints | The controller must expose health, metrics, or API endpoints that other systems or humans depend on directly. | At that point the controller is a service, not just a launcher, and it needs structured request handling, observability, and concurrency primitives. |

### Non-Triggers

These do not justify a runtime migration by themselves:

- adding more providers
- adding more environment variables
- refactoring shell helpers into more focused libraries
- one additional polling loop that remains independent and short-lived

## Runtime Comparison

| Option | Strengths for this repo | Weak spots for this repo |
| --- | --- | --- |
| Go | Single static binary, straightforward concurrency, good standard library for HTTP/JSON/filesystem work, readable for infra-oriented contributors. | Adds a compile/test toolchain and stronger up-front structure than shell. |
| Python | Fast to prototype, widely familiar, rich ecosystem. | Worse single-binary story, more packaging drift, and more moving parts for host installs than Go or shell. |
| Rust | Strongest safety and performance profile, excellent single-binary deployment. | Highest implementation and maintenance cost for an ops-heavy control plane with a Bash-heavy contributor base. |

## Chosen Compiled Runtime

When a compiled runtime is required, use Go first.

Why Go:

- it preserves the repo's operational bias toward simple deployment artifacts
- it handles controller-shaped concurrency without pulling in an interpreter
- it is a lower maintenance jump from Bash than Rust for this contributor set

Python stays viable for tooling around the controller, but not as the primary
runtime target for the controller itself. Rust remains a valid future revisit if
security or performance constraints materially change.

## Migration Plan

1. Treat `scripts/controller.sh` as the reference behavior until cutover.
2. When a trigger fires, open a migration epic and stop adding new long-lived
   controller responsibilities to Bash except for reliability fixes.
3. Build the Go controller around the existing seams first:
   - worker spawn contract
   - queue directory layout
   - job status and summary artifacts
   - current environment variable surface
4. Port the existing shell integration coverage as parity tests before default
   cutover, especially for shutdown, queue recovery, worker caps, and watcher
   flows.
5. Ship both runtimes behind an explicit selector during rollout so operators
   can fall back without changing the rest of their deployment.
6. Make Go the default only after parity is proven and rollback is documented.

## Cutover Criteria

Do not switch runtimes on intuition alone. Cutover requires all of:

- at least one trigger is explicitly called out in a tracked issue or PR
- the Go controller reaches feature parity for the production paths in use
- operator-facing config and artifact formats are preserved or migrated with docs
- rollback to the shell controller remains available for at least one release

## Consequences

- Phase 2 stays shell-first on purpose, not by inertia.
- Queue growth and scan latency now have an explicit architectural meaning.
- Future controller features should be evaluated against `T1`/`T2`/`T3` before
  they are added to Bash.
