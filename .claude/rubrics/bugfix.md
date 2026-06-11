---
version: 1
name: bugfix
applies_to: bug
---

# Bugfix overlay (v1)

Applied additionally whenever the task type is `bug` (created with `-t bug` or carrying the `bug` label). Default + the relevant domain rubric still apply; this overlay enforces the evidence-before-fix protocol from spec 0.5. The protocol exists to break symptom-patching chains — speculative fixes stacking into double-digit follow-up PRs for a single issue, none of which can be proved to be the one that worked. Every criterion below is mandatory for bug-typed tasks.

## Criteria

### G1. A failing test demonstrating the root cause exists and predates the fix.

The diff contains a test that fails on the broken commit and passes on the fix commit. The test is committed BEFORE the fix in the commit sequence (or in a single commit if the workflow squashes), so a reviewer can run the test against the parent of the fix and watch it fail.

Evidence that satisfies it: the commit log (or the diff structure) shows the test arriving before the fix; the test is keyed to the user-visible symptom in the bug report, not to an internal symptom the fix happens to flip. A diff where the test and the fix arrive in the same blob with no failing-test evidence fails this criterion. A test that asserts only against the fix's new code path (and would not have been red against the broken version) also fails — it does not demonstrate the root cause.

### G2. A root-cause statement with cited evidence is attached to the Beads task.

The Beads task carries a comment in the shape "X did Y because W; evidence: Z" — with actual evidence: a trace excerpt, a `git bisect` SHA, log lines, a profiler output, a network HAR. A prose hand-wave without a citation fails this criterion. The evidence must name the specific input, code path, or contract that flips behavior.

Evidence that satisfies it: a Beads comment (or a section in `notes`) on the task that cites at least one concrete artefact — file:line of the bad code, a deploy log timestamp, a database row that triggered the failure. "Probably a race condition" with no trace fails.

### G3. The fix rationale contains no speculative language.

The `decisions` array, `llm_observations`, and the Beads notes describe the fix in declarative terms: "the X path now does Y; this makes Z hold because W". Hedging language — "might", "should fix", "probably", "in theory", "I think this works" — fails this criterion. Speculation in the fix description is the strongest signal that the root cause is not understood and the patch is a guess.

Evidence that satisfies it: a reviewer can read the fix rationale and predict, without running the test, whether the patch addresses the documented root cause. If the rationale leaves the reviewer guessing, this criterion fails.

### G4. The fix flips the failing test from G1.

The test added in G1 fails on the pre-fix code and passes on the post-fix code — exactly. A test that was already passing before the fix and continues to pass is not regression coverage; it is a smoke check. The fix must be the change that turns the test from red to green.

Evidence that satisfies it: a side-by-side run against the parent commit and the fix commit shows the same test transitioning from FAIL to PASS. If the test passes on both sides, G4 fails (and likely G1 fails too — the test does not encode the root cause).
