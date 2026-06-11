---
version: 1
name: backend
extends: default
---

# Backend rubric (v1)

Applied additionally when the task carries the `backend` label. Default criteria still apply; these add domain-specific checks pulled from `.claude/agents/backend.md`. Keep the leverage at default + bugfix — these are the few backend-specific failure modes that recur.

## Criteria

### B1. Inputs are validated at the trust boundary.

Every new request handler, queue consumer, or external-facing entry point validates inputs (type, range, length, encoding) before they reach business logic. Reject early with a stable error envelope; never interpolate untrusted input into SQL, shell, or template strings.

Evidence that satisfies it: parameterised queries / prepared statements throughout the diff; a validation layer (schema, decoder, guard clause) on every new boundary. A diff that passes a raw query string into a SQL builder, a shell command, or a template fails this criterion (extends C5 / INJECTION).

### B2. Migrations are reversible and safe to deploy ahead of code.

Schema migrations in the diff are additive-first (add column, backfill, switch code, drop later); never long-locking on hot tables; carry an explicit rollback path documented in the migration file or the `decisions` array. A breaking column rename or destructive drop without a multi-step rollout plan fails this criterion.

Evidence that satisfies it: each migration file is paired with a rollback, the deploy order is documented (additive deploy ⇒ backfill ⇒ code switch ⇒ optional drop), and any locking operation cites the engine's online-schema-change tooling or explains why a brief lock is acceptable.

### B3. Error paths return the documented contract.

New error paths (4xx, 5xx, exception envelopes, queue DLQ payloads) map to the stable error codes the rest of the system uses. A new endpoint that invents its own error shape or leaks an internal stack trace fails this criterion.

Evidence that satisfies it: every new throw / return path maps to a documented domain error code; the response shape matches the consistent `{error: {code, message, details?}}` (or equivalent) envelope the codebase uses elsewhere; no internal exception text is exposed to the client.

### B4. Outbound calls have explicit timeouts and backpressure.

Any new outbound call (HTTP, RPC, queue publish, DB query on a new path) declares an explicit timeout. Long-running consumers carry bounded concurrency (semaphore, work-queue depth, circuit breaker) so a flaky downstream cannot exhaust the service. A `requests.get(url)` or `axios.get(url)` with no timeout fails this criterion.

Evidence that satisfies it: every new outbound call site has a timeout argument set to a finite value, and the diff shows backpressure (bounded worker count, circuit breaker, retry policy with jitter) on any new hot loop. The `decisions` array documents the chosen timeout and the rationale.
