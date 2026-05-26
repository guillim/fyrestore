# Fyrestore

A light, read-only macOS browser for Google Firestore. Think DBeaver for Postgres, but for Firestore — sign in with your Google account and browse any Firestore project your account has access to.

- **Read-only**: no write/delete endpoints are wired anywhere
- **Single-binary**: pure Swift Package, no Firebase SDK
- **Google sign-in**: click one button, consent in your browser, you're in. Works for any Google account in any organization.
- **Three panes**: projects/collections sidebar → document list (with filter + pagination) → document inspector (with sub-collection drill-down)

## For users (running the released app)

1. Download the latest `.app` (or clone and `swift run Fyrestore`).
2. Launch it → click **Sign in with Google** → your browser opens.
3. Consent on the Google screen → you're back in the app.
4. Pick a project, click a collection, browse.

That's it. No client IDs, no service accounts, no JSON files. Tokens are cached in your macOS Keychain so you don't sign in again unless you click Sign out.

> If you see a *"Google hasn't verified this app"* warning during sign-in, that's normal for apps under independent review. Click **Advanced → Continue** to proceed. The warning goes away once the app's OAuth verification with Google is complete.

### What you can do in the app

- **Pick a project** — only projects your Google account has IAM access to show up.
- **Browse collections** — root collections appear in the sidebar.
- **Documents** — first 100 load by default; click **Load more** at the bottom for the next page.
- **Filter** — type a single condition in the box at the top of the document list and press Enter. Examples:
  - `age >= 18`
  - `name == "alice"`
  - `active == true`
  - Operators: `==`, `!=`, `<`, `<=`, `>`, `>=`. Bare strings work too (`status == active`).
- **Sub-collections** — when a doc has child collections, chips appear at the bottom of the right pane. Click one to drill in. The breadcrumb at the top of the document list lets you click back up.

### Required permissions on the Google side

Your Google account needs:

- **`roles/datastore.viewer`** (or any role granting `datastore.documents.list/get`) on each project you want to browse.
- **`roles/browser`** at the org/folder level (or `roles/resourcemanager.projectViewer` on each project) so the app can list which projects exist for you.

If a project doesn't appear, it's an IAM gap on that project — not a bug.

---

## For maintainers / forking the repo

If you're building this from source for the first time, or you forked it to ship your own variant, you'll need to register your own Google OAuth client once.

### 1. Create the OAuth client (one-time, ~5 min)

1. Pick a Google Cloud project to **host** the OAuth client. This is just an administrative home for the client — it has nothing to do with which projects users will browse.
2. **APIs & Services → OAuth consent screen**:
   - User type: **External** (lets people outside your Workspace org sign in).
   - Fill in the required app info (name, support email, logo optional).
   - Add scopes: `openid`, `email`, `https://www.googleapis.com/auth/cloud-platform.read-only`, `https://www.googleapis.com/auth/datastore`.
   - While in "Testing" status, add the Google accounts you want to be able to sign in (max 100).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app**. Copy the **Client ID** and **Client secret**.
4. **APIs & Services → Library**, enable on this host project:
   - **Cloud Resource Manager API**
   - **Cloud Firestore API**

### 2. Generate `Secrets.swift` locally

```sh
export FYRESTORE_CLIENT_ID="1234…apps.googleusercontent.com"
export FYRESTORE_CLIENT_SECRET="GOCSPX-…"
./scripts/setup-secrets.sh
```

This writes `Sources/Fyrestore/Secrets.swift` — gitignored, so your credentials never enter version control. The file is required for the package to compile; without it `swift build` will error with *"cannot find 'Secrets' in scope"*.

Per RFC 8252, the "client secret" Google issues for Desktop clients isn't actually secret — it's a public string the token endpoint expects. It's safe to ship in the binary. We keep it out of git for two reasons: automated secret scanners (GitHub push protection) reject pushes that contain it, and forking developers should register their own OAuth client rather than reuse yours.

### 3. Build & run

```sh
swift run Fyrestore                    # from the command line
open Package.swift                      # or in Xcode → ⌘R
```

### 4. Going from testing → public (later)

While the consent screen is in "Testing" status: max 100 named test users.

To open it to anyone:

1. Click **Publish App** on the consent screen.
2. Because we use the sensitive scope `auth/datastore`, Google requires **OAuth verification** before the app can serve more than 100 users or remove the "unverified app" warning. Submit:
   - Privacy policy URL
   - Demo video showing each sensitive scope being used
   - Justification for each scope
3. Verification typically takes 4–8 weeks. No code changes needed — same client ID, same binary.

In the meantime you can still onboard up to 100 users by adding them to the test-users list; they'll see the warning screen and click through.

### Building a distributable `.app`

`swift run` is for development. To produce a `Fyrestore.app` bundle you can hand to other people, run:

```sh
./scripts/build-app.sh
```

This produces `dist/Fyrestore.app` (around 1.3 MB). To package it for distribution:

```sh
ditto -c -k --keepParent dist/Fyrestore.app dist/Fyrestore-0.1.0.zip
```

The bundle is **unsigned**. First-time users will see Gatekeeper's *"Apple cannot check this app for malicious software"* warning and need to **right-click → Open** once to bypass. Subsequent launches work normally. For internal/friend distribution this is fine.

To remove the warning (signed + notarized), you need an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year). Worth doing once you have real users; not before.

**Optional app icon**: drop an `.icns` file at `Resources/AppIcon.icns` before running `build-app.sh` and it'll be picked up automatically.

### Dev-only env-var overrides

During development, override the embedded values without recompiling:

```sh
export FYRESTORE_CLIENT_ID="…apps.googleusercontent.com"
export FYRESTORE_CLIENT_SECRET="…"
swift run Fyrestore
```

End users never set these.

---

## How it works

- **Auth**: `Auth/GoogleAuth.swift` runs OAuth 2.0 + PKCE against `accounts.google.com`. A tiny loopback HTTP listener (`Auth/LoopbackServer.swift`) catches the redirect on `127.0.0.1:<random-port>/` — no custom URL scheme required, so no `Info.plist` work.
- **Tokens**: stored in the login keychain (`KeychainTokenStore`). Refresh tokens auto-rotate access tokens.
- **Firestore REST endpoints used**:
  - `cloudresourcemanager.googleapis.com/v1/projects` — list projects
  - `firestore.googleapis.com/v1/projects/{p}/databases` — list databases
  - `firestore.googleapis.com/v1/{parent}:listCollectionIds` — list root and sub-collections
  - `firestore.googleapis.com/v1/{parent}/{collection}` with `pageSize`/`pageToken` — paginated documents
  - `firestore.googleapis.com/v1/{parent}:runQuery` — filtered queries
- **Paths**: `FirestorePath` models a path as an alternating sequence of `collection` / `document` segments. The same code path serves root collections (`[.collection("users")]`) and deeply nested ones (`[.collection("users"), .document("alice"), .collection("orders")]`).

## Limits / known gaps (kept intentionally simple)

- Filters support **one condition only** (single field, single operator). No `AND`/`OR`, no ordering, no `array-contains`. Easy to extend in `QueryFilter.swift` + `FirestoreClient.runQuery`.
- Filter results don't paginate — they're capped at the first 100 matches. Plain (unfiltered) listings *do* paginate via "Load more".
- Sub-collections are listed only for the currently selected document (not pre-expanded as a tree in the sidebar).
- The sidebar always shows the database's **root** collections; the breadcrumb in the document list pane is how you see/navigate the deeper path.

These are deliberate cut lines; everything in `FirestoreClient.swift` already returns the right shapes to extend further.

## Requirements

- macOS 13+
- Xcode 15+ or Swift 5.9+ toolchain (only needed to build from source)
