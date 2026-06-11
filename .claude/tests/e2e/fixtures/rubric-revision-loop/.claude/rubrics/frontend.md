---
version: 1
name: frontend
extends: default
---

# Frontend rubric (v1)

Applied additionally when the task carries the `frontend` label. Default criteria still apply; these add domain-specific checks pulled from `.claude/agents/frontend.md`. The leverage is default + bugfix — these are the few frontend-specific failure modes that recur.

## Criteria

### F1. Accessibility on changed interactive surfaces.

Every interactive surface the diff touches (form, modal, route, navigation, focus path) clears the a11y bar in `.claude/agents/frontend.md`: programmatic labels on inputs, focus management, `aria-live` for errors, visible focus rings, 44x44 px hit targets on touch, `prefers-reduced-motion` respected for non-essential animation. A new button without an accessible name or a dialog without focus trapping fails this criterion.

Evidence that satisfies it: each new interactive element carries a semantic role or `aria-label`, keyboard navigation reaches it in the expected tab order, and the `decisions` or `llm_observations` field cites the a11y checks the specialist ran (keyboard, screen-reader, focus order).

### F2. Performance budget respected where the diff touches the hot path.

Changes to bundles, routes, images, fonts, or rendering paths respect the performance budget in `frontend.md` (FCP < 1.8s, LCP < 2.5s, TTI < 3.9s, CLS < 0.1, initial JS < 200 KB gzipped). A new heavyweight dependency added without a deviation note in `decisions` fails this criterion; so does a route that ships locale bundles for every supported language on first load.

Evidence that satisfies it: any new dependency is either lightweight (under the dependency-swap-table thresholds in `frontend.md`) or carries a deviation note in `decisions` explaining the trade-off. Images carry `width`/`height` (or `aspect-ratio`) to prevent CLS; off-screen images use `loading="lazy"`.

### F3. Loading, error, and empty states on every new data-driven surface.

A new component that fetches data renders distinct, actionable states for loading, error, and empty. A spinner that never resolves on a fetch failure, or a list that renders as blank space when empty, fails this criterion.

Evidence that satisfies it: every new data-driven component in the diff has a loading state (skeleton, spinner, suspense fallback), an error state with an actionable next step (retry button, support link), and an empty state with copy that tells the user why they see nothing and what to do next.

### F4. Client/server component boundaries respected.

In App Router (RSC) projects, the diff keeps `'use client'` boundaries as leaf islands and does not read secrets, env vars, or DB rows inside Client Components. A top-down `'use client'` tree added to satisfy a single button fails this criterion. In non-RSC projects, the equivalent rule is `useEffect` on a static page or hydration-only logic on a Server-Rendered page.

Evidence that satisfies it: any new `'use client'` directive is scoped to the smallest tree that needs interactivity; no secret / env / DB read inside a Client Component; the `decisions` array documents any deliberate exception (e.g. a Client-only route that needs browser APIs throughout).
