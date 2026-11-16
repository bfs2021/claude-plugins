# users-api

## Title

Authors can register, sign in and fetch their account through the API

## Description

## Summary

Add the three account endpoints: register (`POST /api/members`), login (`POST /api/members/login`) and current user (`GET /api/user`). Add the token check that every author-only endpoint uses. Each endpoint returns the same `user` object, and every error case returns the agreed error body.

## Outcome

**Serves:** O1

**Who:** Author (a registered user who signs in and publishes articles)

**Need:** Create an account and sign in, so the app knows who they are.

**Outcome:** A person can register an account, sign in with it, and see that the app recognises them as signed in.

## Background / Motivation

Authors need an account before they can publish, and the frontend needs a token to show who is signed in. These endpoints and the token check are the base for the publish endpoint and for the sign-up and sign-in pages.

## Proposed Behaviour

- **Register.** `POST /api/members` with `{"user":{"username","email","password"}}` returns 201 and `{"user":{"email","token","username","bio","image"}}`. For a new user, `bio` and `image` are `null`.
- **Login.** `POST /api/members/login` with `{"user":{"email","password"}}` returns 200 with the same `user` object. The email match ignores letter case.
- **Current user.** `GET /api/user` with the header `Authorization: Token <jwt>` returns 200 with the `user` object. Its `token` is the token that was sent.
- **Blank fields.** A field is blank when it is missing, is not a string, or is empty after trimming spaces. Any blank field gives 422 with one `["can't be blank"]` entry per blank field, all in one body, for example `{"errors":{"email":["can't be blank"],"password":["can't be blank"]}}`. When a request has a blank field, no duplicate check runs.
- **Duplicates.** On register, an email that already exists (ignoring letter case) gives 422 `{"errors":{"email":["has already been taken"]}}`. A username that already exists (exact match, letter case counts) gives 422 `{"errors":{"username":["has already been taken"]}}`. When both are taken, both keys appear in one body.
- **Wrong login.** An unknown email or a wrong password gives 401 `{"errors":{"email or password":["is invalid"]}}`.
- **Bad token.** On `GET /api/user`, a missing header, a scheme other than `Token`, a token signed with another secret, an expired token, or a token for a user id that does not exist gives 401 `{"errors":{"token":["is missing or invalid"]}}`.
- **Token contents.** The token is a JWT signed with HS256. Its payload holds the user's `id` and `username`. It expires 24h after it is issued. The signing secret is the `JWT_SECRET` environment variable, or `conduit-dev-secret` when that is unset.
- **No passwords out.** No response contains the password or its hash.
- **Password storage.** Passwords are stored as a bcrypt hash with cost 10.

## Technical Context

- Repo: `app`. New files: `backend/src/auth.js`, `backend/src/routes/users.js`, `backend/test/users.test.js` (and a test file for the token check if the implementer splits it). Edit `backend/src/app.js` (from backend-foundation) to mount the users router under `/api`.
- `backend/src/auth.js`: `hashPassword` and `verifyPassword` with `bcryptjs` at cost 10 (`auth.bcrypt_cost`). `signToken(user)` signs `{id, username}` with `jsonwebtoken`, `algorithm: 'HS256'`, `expiresIn: '24h'` (`auth.token_expiry`), secret `process.env.JWT_SECRET || 'conduit-dev-secret'` (`auth.jwt_secret_default`). `verifyToken` calls `verify` from `jsonwebtoken` with `algorithms: ['HS256']` pinned. `requireAuth` parses `Authorization: Token <jwt>`, verifies it, loads the user by `id`, and sets it on the request; every failure throws `HttpError(401, {"token":["is missing or invalid"]})`. `optionalAuth` does the same but continues with no user when the header is absent; nothing uses it in this ticket.
- `backend/src/routes/users.js`: `POST /users`, `POST /members/login`, `GET /user` (behind `requireAuth`), and `toUserResponse(user, token)`, which returns only `email`, `token`, `username`, `bio`, `image`. Blank checks use `blankErrors` from `backend/src/errors.js` (from backend-foundation) and run before the duplicate check (`validation.report_all_fields`). Lookups use `findUserByEmail` (ignores letter case) and `findUserByUsername` (exact) from `backend/src/store.js`. New users are added with `insertUser`.
- The email is stored as submitted; only comparisons ignore letter case.
- Tests use Supertest against `createApp` with a freshly seeded store and app per test (the isolation unit set in backend-foundation), so a user one test registers never exists in another test. A test that needs an earlier state, such as a registered `newuser1` before its stored hash is checked, creates it inside the same test. Expired-token tests sign with `expiresIn: -1`; wrong-secret tests sign with a different secret; the missing-user test signs `{id: 999, username: "ghost"}` with the right secret.

## Acceptance Criteria

- [ ] Registering username `newuser1`, email `newuser1@conduit.test`, password `New-Pass-123` returns status 201
- [ ] The register response for `newuser1` has `user.username` equal to `newuser1`
- [ ] The register response for `newuser1` has `user.email` equal to `newuser1@conduit.test`
- [ ] The register response for `newuser1` has `user.bio` equal to `null`
- [ ] The register response for `newuser1` has `user.image` equal to `null`
- [ ] The register response for `newuser1` has a non-empty string in `user.token`
- [ ] No key in the register response body has a name containing the text `password`
- [ ] The stored password hash for newly registered `newuser1` carries bcrypt cost `10`
- [ ] Registering with the `username` key missing returns 422 with body `{"errors":{"username":["can't be blank"]}}`
- [ ] Registering with `email` set to an empty string returns 422 with body `{"errors":{"email":["can't be blank"]}}`
- [ ] Registering with `password` set to three spaces returns 422 with body `{"errors":{"password":["can't be blank"]}}`
- [ ] Registering with `username` set to the number `123` returns 422 with body `{"errors":{"username":["can't be blank"]}}`
- [ ] Registering with all three fields empty returns 422 with `can't be blank` entries under `username`, `email` and `password` in one body
- [ ] Registering username `jake` with an empty email returns a 422 body whose only key is `email`
- [ ] Registering a new username with email `JAKE@conduit.test` returns 422 with body `{"errors":{"email":["has already been taken"]}}`
- [ ] Registering username `jake` with a new email returns 422 with body `{"errors":{"username":["has already been taken"]}}`
- [ ] Registering username `jake` with email `jake@conduit.test` returns 422 with `has already been taken` entries under both `email` and `username`
- [ ] Registering username `Jake` with email `jake2@conduit.test` returns status 201
- [ ] Logging in as `jake@conduit.test` with password `Jake-Pass-123` returns status 200 with `user.username` equal to `jake`
- [ ] Logging in as `JAKE@CONDUIT.TEST` with password `Jake-Pass-123` returns status 200
- [ ] No key in the login response body has a name containing the text `password`
- [ ] Logging in as `jake@conduit.test` with password `wrong-pass` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`
- [ ] Logging in as `nobody@conduit.test` returns 401 with body `{"errors":{"email or password":["is invalid"]}}`
- [ ] Logging in with an empty email returns 422 with body `{"errors":{"email":["can't be blank"]}}`
- [ ] Logging in with the `password` key missing returns 422 with body `{"errors":{"password":["can't be blank"]}}`
- [ ] The login token for `jake` decodes to a header whose `alg` is `HS256`
- [ ] The login token for `jake` decodes to a payload with `username` equal to `jake`
- [ ] The login token for `jake` decodes to a payload whose `id` equals the stored id of `jake`
- [ ] The login token for `jake` decodes to a payload whose `exp` is 86400 greater than its `iat`
- [ ] With `JWT_SECRET` unset, the login token for `jake` verifies with the secret `conduit-dev-secret`
- [ ] With `JWT_SECRET` set to `test-secret-1`, the login token for `jake` verifies with the secret `test-secret-1`
- [ ] `GET /api/user` with `jake`'s login token in `Authorization: Token <jwt>` returns status 200 with `user.username` equal to `jake`
- [ ] `GET /api/user` with `jake`'s login token returns `user.token` equal to the token that was sent
- [ ] No key in the `GET /api/user` response body has a name containing the text `password`
- [ ] `GET /api/user` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with `jake`'s token sent as `Authorization: Bearer <jwt>` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a token signed by the secret `other-secret` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with an expired token for `jake` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] `GET /api/user` with a correctly signed token for user id `999` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Running `npm test` in `backend/` runs a test for every criterion above and exits with code 0
- [ ] Running `npm test -- --randomize` in `backend/` exits with code 0
- [ ] In `npm test`, a test-only route behind `optionalAuth`, called with no `Authorization` header, runs its handler with no user set on the request
- [ ] In `npm test`, a test-only route behind `optionalAuth`, called with a seeded author's login token in `Authorization: Token <jwt>`, runs its handler with that author set on the request
- [ ] In `npm test`, a test-only route behind `optionalAuth`, called with a token signed by the secret `other-secret`, returns 401 with body `{"errors":{"token":["is missing or invalid"]}}`
- [ ] Registering a new username with a seeded author's email followed by one trailing space returns 422 with body `{"errors":{"email":["has already been taken"]}}`
- [ ] Logging in with a seeded author's email preceded by one leading space and that author's correct password returns status 200 with that author's `user.username`
- [ ] Logging in with a seeded author's email followed by one trailing space and that author's correct password returns status 200 with that author's `user.username`

## Out of Scope

Articles, profiles, user settings, sign-out, and any frontend page.

## Scope

| Layer | Service | Area |
|-------|---------|------|
| BE | app | `backend/src/auth.js`, `backend/src/routes/users.js`, users tests |

- Assumption: Email comparisons for duplicates and login ignore leading and trailing spaces as well as letter case, while the email is still stored as submitted and usernames keep their exact comparison.

## Test User

`jake@conduit.test` — password `Jake-Pass-123`

## Navigation Path

None: this ticket has no page. Run `npm test` from `backend/`, or send requests with an HTTP client to the backend on port 3000.

## Labels

planned, INIT-0000000000-7752, feature, blocked-by:backend-foundation

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 7,
  "prior_art_found": false,
  "complexity": "moderate",
  "exploration_depth": "deep",
  "Strategy": "Conservative",
  "Decision": "Modular CommonJS Express 5 API with a createApp factory, resettable in-memory store and seed, bcryptjs, jsonwebtoken and Jest + Supertest; Vite + vanilla JS SPA with a History router and an /api proxy.",
  "AffectedServices": "app",
  "TargetSymbols": "requireAuth (new):app/backend/src/auth.js;toUserResponse (new):app/backend/src/routes/users.js;createApp (new in backend-foundation):app/backend/src/app.js;blankErrors (new in backend-foundation):app/backend/src/errors.js;findUserByEmail (new in backend-foundation):app/backend/src/store.js",
  "Kind": "business",
  "Serves": ["O1"],
  "Enables": []
}
```

## Verification Notes

| Criterion | Role | Test data | Source | Navigation path | Expected | Verifiable |
|-----------|------|-----------|--------|-----------------|----------|------------|
| Registering username `newuser1`, email `newuser1@conduit.test`, password `New-Pass-123` returns status 201 | anonymous reader | none | — | `POST /api/members` | status 201 | yes |
| The register response for `newuser1` has `user.username` equal to `newuser1` | anonymous reader | none | — | `POST /api/members` | `newuser1` | yes |
| The register response for `newuser1` has `user.email` equal to `newuser1@conduit.test` | anonymous reader | none | — | `POST /api/members` | `newuser1@conduit.test` | yes |
| The register response for `newuser1` has `user.bio` equal to `null` | anonymous reader | none | — | `POST /api/members` | `null` | yes |
| The register response for `newuser1` has `user.image` equal to `null` | anonymous reader | none | — | `POST /api/members` | `null` | yes |
| The register response for `newuser1` has a non-empty string in `user.token` | anonymous reader | none | — | `POST /api/members` | string of length greater than 0 | yes |
| No key in the register response body has a name containing the text `password` | anonymous reader | none | — | `POST /api/members` | zero matching keys | yes |
| The stored password hash for newly registered `newuser1` carries bcrypt cost `10` | developer | none | — | `npm test` | `bcryptjs.getRounds` returns `10` | yes |
| Registering with the `username` key missing returns 422 with body `{"errors":{"username":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members` | status 422; body `{"errors":{"username":["can't be blank"]}}` | yes |
| Registering with `email` set to an empty string returns 422 with body `{"errors":{"email":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members` | status 422; body `{"errors":{"email":["can't be blank"]}}` | yes |
| Registering with `password` set to three spaces returns 422 with body `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members` | status 422; body `{"errors":{"password":["can't be blank"]}}` | yes |
| Registering with `username` set to the number `123` returns 422 with body `{"errors":{"username":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members` | status 422; body `{"errors":{"username":["can't be blank"]}}` | yes |
| Registering with all three fields empty returns 422 with `can't be blank` entries under `username`, `email` and `password` in one body | anonymous reader | none | — | `POST /api/members` | status 422; body `{"errors":{"username":["can't be blank"],"email":["can't be blank"],"password":["can't be blank"]}}` (key order not checked) | yes |
| Registering username `jake` with an empty email returns a 422 body whose only key is `email` | anonymous reader | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members` | status 422; body `{"errors":{"email":["can't be blank"]}}` | yes |
| Registering a new username with email `JAKE@conduit.test` returns 422 with body `{"errors":{"email":["has already been taken"]}}` | anonymous reader | 1 `user` record with email `jake@conduit.test` | seeded-by:backend-foundation | `POST /api/members` | status 422; body `{"errors":{"email":["has already been taken"]}}` | yes |
| Registering username `jake` with a new email returns 422 with body `{"errors":{"username":["has already been taken"]}}` | anonymous reader | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members` | status 422; body `{"errors":{"username":["has already been taken"]}}` | yes |
| Registering username `jake` with email `jake@conduit.test` returns 422 with `has already been taken` entries under both `email` and `username` | anonymous reader | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members` | status 422; body `{"errors":{"email":["has already been taken"],"username":["has already been taken"]}}` (key order not checked) | yes |
| Registering username `Jake` with email `jake2@conduit.test` returns status 201 | anonymous reader | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members` | status 201; `user.username` `Jake` | yes |
| Logging in as `jake@conduit.test` with password `Jake-Pass-123` returns status 200 with `user.username` equal to `jake` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | status 200; `user.username` `jake` | yes |
| Logging in as `JAKE@CONDUIT.TEST` with password `Jake-Pass-123` returns status 200 | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | status 200 | yes |
| No key in the login response body has a name containing the text `password` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | zero matching keys | yes |
| Logging in as `jake@conduit.test` with password `wrong-pass` returns 401 with body `{"errors":{"email or password":["is invalid"]}}` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | status 401; body `{"errors":{"email or password":["is invalid"]}}` | yes |
| Logging in as `nobody@conduit.test` returns 401 with body `{"errors":{"email or password":["is invalid"]}}` | anonymous reader | none | — | `POST /api/members/login` | status 401; body `{"errors":{"email or password":["is invalid"]}}` | yes |
| Logging in with an empty email returns 422 with body `{"errors":{"email":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members/login` | status 422; body `{"errors":{"email":["can't be blank"]}}` | yes |
| Logging in with the `password` key missing returns 422 with body `{"errors":{"password":["can't be blank"]}}` | anonymous reader | none | — | `POST /api/members/login` | status 422; body `{"errors":{"password":["can't be blank"]}}` | yes |
| The login token for `jake` decodes to a header whose `alg` is `HS256` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | `HS256` | yes |
| The login token for `jake` decodes to a payload with `username` equal to `jake` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | `jake` | yes |
| The login token for `jake` decodes to a payload whose `id` equals the stored id of `jake` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | `1` | yes |
| The login token for `jake` decodes to a payload whose `exp` is 86400 greater than its `iat` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | `exp - iat` = `86400` | yes |
| With `JWT_SECRET` unset, the login token for `jake` verifies with the secret `conduit-dev-secret` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `npm test` | `verify` from `jsonwebtoken` succeeds | yes |
| With `JWT_SECRET` set to `test-secret-1`, the login token for `jake` verifies with the secret `test-secret-1` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `npm test` | `verify` from `jsonwebtoken` succeeds | yes |
| `GET /api/user` with `jake`'s login token in `Authorization: Token <jwt>` returns status 200 with `user.username` equal to `jake` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | status 200; `user.username` `jake` | yes |
| `GET /api/user` with `jake`'s login token returns `user.token` equal to the token that was sent | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | `user.token` equals the sent token | yes |
| No key in the `GET /api/user` response body has a name containing the text `password` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | zero matching keys | yes |
| `GET /api/user` with no `Authorization` header returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | `GET /api/user` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with `jake`'s token sent as `Authorization: Bearer <jwt>` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a token signed by the secret `other-secret` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with an expired token for `jake` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `GET /api/user` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| `GET /api/user` with a correctly signed token for user id `999` returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | anonymous reader | none | — | `GET /api/user` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Running `npm test` in `backend/` runs a test for every criterion above and exits with code 0 | developer | 2 `user` records (`jake`, `jane`) | seeded-by:backend-foundation | terminal in `backend/` | exit code 0 | yes |
| Running `npm test -- --randomize` in `backend/` exits with code 0 | developer | 2 `user` records (`jake`, `jane`) | seeded-by:backend-foundation | terminal in `backend/` | exit code 0 | yes |
| In `npm test`, a test-only route behind `optionalAuth`, called with no `Authorization` header, runs its handler with no user set on the request | developer | none | — | `npm test` | handler runs; no user on the request | yes |
| In `npm test`, a test-only route behind `optionalAuth`, called with a seeded author's login token in `Authorization: Token <jwt>`, runs its handler with that author set on the request | developer | 1 `user` record `jake` | seeded-by:backend-foundation | `npm test` | handler runs; request user has `username` `jake` | yes |
| In `npm test`, a test-only route behind `optionalAuth`, called with a token signed by the secret `other-secret`, returns 401 with body `{"errors":{"token":["is missing or invalid"]}}` | developer | none | — | `npm test` | status 401; body `{"errors":{"token":["is missing or invalid"]}}` | yes |
| Registering a new username with a seeded author's email followed by one trailing space returns 422 with body `{"errors":{"email":["has already been taken"]}}` | anonymous reader | 1 `user` record with email `jake@conduit.test` | seeded-by:backend-foundation | `POST /api/members` | status 422; body `{"errors":{"email":["has already been taken"]}}` | yes |
| Logging in with a seeded author's email preceded by one leading space and that author's correct password returns status 200 with that author's `user.username` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | status 200; `user.username` `jake` | yes |
| Logging in with a seeded author's email followed by one trailing space and that author's correct password returns status 200 with that author's `user.username` | author | 1 `user` record `jake` | seeded-by:backend-foundation | `POST /api/members/login` | status 200; `user.username` `jake` | yes |

## Writes

| Key | Op |
|-----|----|
| `user` | append |

## Reads

| Key | Source |
|-----|--------|
| `user.id` | spec |
| `user.username` | spec |
| `user.email` | spec |
| `user.password_hash` | spec |
| `user.bio` | spec |
| `user.image` | spec |

## Preconditions

| Criterion | Key | Mode | Requires | Basis |
|-----------|-----|------|----------|-------|
| Registering with the `username` key missing returns 422 with body `{"errors":{"username":["can't be blank"]}}` | `user.username` | input | null | — |
| Registering username `jake` with a new email returns 422 with body `{"errors":{"username":["has already been taken"]}}` | `user.username` | state | value:jake | spec:backend-foundation |
