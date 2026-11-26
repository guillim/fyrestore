# Fyrestore

A light, read-only macOS browser for Google Firestore. Sign in with your Google account and browse any Firestore project your account has access to.

![Fyrestore showing a Firestore collection with filter, document list and field inspector](img/fyrestore-overview.png)

- **Read-only** — no write or delete endpoints anywhere
- **Single-binary** — pure Swift Package, no Firebase SDK
- **Google sign-in** — one button, your browser, done. Works for any Google account.
- **Three panes** — projects/collections sidebar → document list with filter & pagination → document inspector with sub-collection drill-down

## For users

1. Download the latest `.app` (or clone and `swift run Fyrestore`).
2. Launch → **Sign in with Google** → consent in your browser → you're back in the app.
3. Pick a project, click a collection, browse.

Tokens cache in your macOS Keychain. If you see a *"Google hasn't verified this app"* warning, that's normal — **Advanced → Continue**.

### What you can do

- **Filter** — `field op value` (e.g. `age >= 18`, `name == "alice"`, `email contains "alice"`). Operators: `==`, `!=`, `<`, `<=`, `>`, `>=`, `contains` (case-insensitive substring).
- **Pagination** — first 100 docs load; **Load more** at the bottom fetches the next page.
- **Sub-collections** — chips at the bottom of the doc inspector. Click to drill in; breadcrumb at the top to navigate back up.
- **Copy** — copy any doc as JSON, copy a doc's reference path, right-click for more.
- **Open in Firebase Console** — one-click jump to the hosted UI when you want to make a change.

### Required Google permissions

- `roles/datastore.viewer` on each project you want to browse.
- `roles/browser` (or `roles/resourcemanager.projectViewer`) so the app can list which projects exist for you.

If a project doesn't appear, it's an IAM gap on that project — not a bug.

---

## For maintainers / forking the repo

You need to register your own Google OAuth client once.

### 1. Create the OAuth client (~5 min)

1. <https://console.cloud.google.com/apis/credentials> — pick or create a host project.
2. **OAuth consent screen** → **External**, fill in app info, add scopes: `openid`, `email`, `https://www.googleapis.com/auth/cloud-platform.read-only`, `https://www.googleapis.com/auth/datastore`. Add yourself as a test user.
3. **Create credentials → OAuth client ID → Desktop app** → copy the **Client ID** and **Client secret**.
4. **APIs & Services → Library** → enable **Cloud Resource Manager API** and **Cloud Firestore API**.

### 2. Set up credentials locally

```sh
export FYRESTORE_CLIENT_ID="…apps.googleusercontent.com"
export FYRESTORE_CLIENT_SECRET="GOCSPX-…"
./scripts/setup-secrets.sh
```

This writes `Sources/Fyrestore/Secrets.swift` (gitignored). Without it `swift build` errors with *"cannot find 'Secrets' in scope"*. Per RFC 8252 the Desktop "client secret" isn't actually confidential, but we keep it out of git to satisfy push-protection scanners and to remind forkers to register their own client.

### 3. Build & run

```sh
swift run Fyrestore                    # command line
open Package.swift                      # or open in Xcode and ⌘R
```

### 4. Build a distributable `.app`

```sh
./scripts/make-release.sh
```

Outputs `dist/Fyrestore-<version>.zip` ad-hoc signed and ready for a GitHub Release. Prints the exact `gh release create` line at the end. Drop an `.icns` at `Resources/AppIcon.icns` to bake in a custom icon.

The build is unsigned/un-notarized. First-time users right-click → Open to bypass Gatekeeper. To remove that warning, join the [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr) and add real Developer ID signing + Apple notarization.

### 5. Going from 100 test users to public

While the consent screen is in "Testing": max 100 named test users. To open it to anyone, click **Publish App**, then submit for **OAuth verification** (privacy policy URL + demo video + scope justification — typical turnaround 4–8 weeks). No code changes needed.

### 6. Send it to TestFlight

The TestFlight build is a second, sandboxed build of the same sources (the Mac App Store only accepts sandboxed apps). It is described by `project.yml` and `Config/`, turned into an Xcode project by [XcodeGen](https://github.com/yonaskolb/XcodeGen), and archived and uploaded by `scripts/testflight.sh`. It has not uploaded a build yet: no Apple account was available when it was written.

One-time setup (needs the [Apple Developer Program](https://developer.apple.com/programs/)):

1. Register the bundle identifier `com.fyrestore.app` at developer.apple.com → Identifiers. If it is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `Config/App.xcconfig`.
2. Create the app in App Store Connect → Apps → **+** → New App, platform macOS, with that bundle identifier.
3. Create an API key in App Store Connect → Users and Access → Integrations, with the **Admin** role (Xcode needs it to create certificates), and download the `.p8` file.
4. Store the secrets in the GitHub repository:

   ```sh
   export APPLE_TEAM_ID="ABCDE12345"            # developer.apple.com > Membership details
   export ASC_KEY_ID="XXXXXXXXXX"
   export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   export ASC_KEY_PATH="$HOME/Downloads/AuthKey_XXXXXXXXXX.p8"
   ./scripts/setup-testflight-secrets.sh
   ```

5. In App Store Connect → TestFlight, create an internal group with automatic distribution, so every new build reaches its testers without a click.

Then, for each build:

```sh
gh workflow run testflight.yml                      # or Actions tab > TestFlight > Run workflow
gh workflow run testflight.yml -f version=0.2.0     # with a new version number
```

The same exports let you upload from your Mac with `./scripts/testflight.sh`. `./scripts/testflight.sh --archive-only` builds the sandboxed app without any Apple account, at `.build/testflight/Fyrestore.xcarchive`.

The version comes from `MARKETING_VERSION` in `Config/App.xcconfig`; the build number is a UTC timestamp. The icon in `Resources/Assets.xcassets` is a placeholder: replace the PNGs to change it.

## Requirements

- macOS 13+
- Xcode 15+ or Swift 5.9+ (only needed to build from source)

## License

[MIT](LICENSE)
