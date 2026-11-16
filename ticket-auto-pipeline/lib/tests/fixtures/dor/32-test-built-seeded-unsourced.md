## Summary

Reject a signed session token whose username belongs to another user.

## Background / Motivation

A token mixing one author's id with another author's username still passes the signature check.

## Proposed Behaviour

The current-user endpoint answers 401 unless the stored user under the token's id has the token's username.

## Acceptance Criteria

- [ ] `GET /api/user` with the token from the seeded author's login returns status 200 with that author's username
- [ ] `GET /api/user` with an unexpired token signed with the server's secret, whose payload `id` belongs to one registered author and whose `username` is the other author's, returns status 401

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
| 2 | Mixed token rejected | author | API | 2 `user` in state registered; a test-built token mixing one author's `id` with the other author's `username` | 401 | ✓ |

## Test Data Prerequisites

- 1 `user` in state registered (the seeded author). Source: seeded-by:auth-test-data-pack
- 2 `user` in state registered; a test-built token mixing one author's `id` with the other author's `username`
