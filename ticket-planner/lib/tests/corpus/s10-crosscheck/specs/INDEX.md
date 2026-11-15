# Spec Index — INIT-corpus-s10

| Spec | Title | Affected service | Kind | Depends on |
|------|-------|------------------|------|------------|
| `api-read-articles` | Anonymous readers can list and open articles through the API | app (BE) | business, O1 | none |
| `api-register` | People can register an author account through the API | app (BE) | business, O2 | `api-read-articles` |
| `api-sign-in` | Authors can sign in and fetch their own account through the API | app (BE) | business, O2 | `api-read-articles`, `api-register` |
| `api-publish-article` | Signed-in authors can publish articles through the API | app (BE) | business, O3, O4 | `api-read-articles`, `api-register`, `api-sign-in` |
| `web-read-articles` | Anonymous readers can browse and open articles in the browser | app (FE) | business, O1 | `api-read-articles` |
| `web-accounts` | Authors can sign up and sign in from the browser | app (FE) | business, O2 | `web-read-articles`, `api-register`, `api-sign-in`, `api-read-articles` |
| `web-publish-article` | Signed-in authors can publish an article from the editor page | app (FE) | business, O3, O4 | `web-read-articles`, `web-accounts`, `api-publish-article`, `api-sign-in`, `api-read-articles` |
| `docs-conduit-lite` | Replace the calculator wording in the repository docs | app (docs) | enabler | `api-read-articles` |
