## Summary

Reject a signed session token whose user no longer exists.

## Background / Motivation

A token issued before a data reset still passes the signature check, so the current-user endpoint answers for a user nobody can find.

## Proposed Behaviour

The current-user endpoint looks up the user named by the token and answers 401 when no stored user has that id.

## Acceptance Criteria

- [ ] `GET /api/user` with the token from the seeded author's login returns status 200 with that author's username
- [ ] `GET /api/user` with an unexpired token signed with the server's secret, whose payload `id` matches no stored user, returns status 401
- [ ] `GET /api/user` with an unexpired token signed with the server's secret and an empty payload returns status 401

## Scope

| Layer | Service  | Area            |
| ----- | -------- | --------------- |
| BE    | auth-svc | CurrentUserRoute |

## Test User

`author@example.com` — password `Author-Pass-123`

## Navigation Path

`Not applicable — API only`

## Verification Plan

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Seeded author reads self | author | API | 1 `user` in state registered (the seeded author) (Source: seeded-by:auth-test-data-pack) | 200, the author's username | ✓ |
| 2 | Unknown id rejected | anonymous reader | API | a test-built token whose `id` no stored user has | 401 | ✓ |
| 3 | Empty payload rejected | anonymous reader | API | a token with an empty payload, built by the test (Source: none) | 401 | ✓ |

## Test Data Prerequisites

- 1 `user` in state registered (the seeded author). Source: seeded-by:auth-test-data-pack
- A test-built token whose `id` no stored user has
- A token with an empty payload, built by the test. Source: none
