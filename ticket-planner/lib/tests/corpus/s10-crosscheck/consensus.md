# Consensus — INIT-corpus-s10

**Result:** 12 accepted, 0 rejected, 1 deferred. The finalized plan is `artifacts/proposal.md`.

(Snapshot reduced to the headings and the sections the tests read; the finding bodies are omitted.)

## Findings Addressed

### F1 — major — no stated way to start the API during browser verification — accepted

### F2 — major — browser verification is not repeatable against a long-running in-memory API — accepted

### F3 — major — `requireAuth` is attributed to two different tickets — accepted

### F4 — minor — proposal Target Symbols list is a subset of what the specs declare — accepted

### F5 — minor — password hashing is needed in ticket 1 but was assigned to ticket 2 — accepted

### F6 — minor — `docs-conduit-lite` independence drops the architecture's ordering note — accepted

### F7 — minor — tie-break for equal `createdAt` is unspecified — deferred

### F8 — minor — bcrypt cost 10 runs on every test's reseed — accepted

### F9 — minor — the proposal leaves out the branching recommendation — accepted

### F10 — minor — the port-clash criterion conflicts with the verify environment — accepted

### F11 — nit — "including a sign-out control" is a proposal addition — accepted

### F12 — nit — test-file names differ between the architecture and the specs — accepted

### F13 — nit — O2's measure only partly matches its outcome — accepted

### Missing-from-Proposal items in the review

- Backend start command: covered by F1.

### Other criterion added while walking an edited spec

- In `web-publish-article`, a new criterion for the "Publish Article" button.

## Changes from Original Proposal

(omitted)

## Deferred Items

- **F7, ordering of articles with equal `createdAt`.** Deferred because no criterion depends on it.

## Open Questions

None. Discovery listed no cited artifact that it could not retrieve, so `planner_cited_artifacts_questions` printed no lines.

## Readiness

ready-for-spec. No blocker findings.

## Goldfish Findings Addressed

Goldfish review: disabled
