# Tally

An iOS calorie and exercise tracker built around **one net number**:

```
net calories = food − exercise
```

shown everywhere as `x / y` against a daily goal derived from your weight target. The lock
screen, the home-screen widget, and the app all lead with the same three metrics — net
calories, protein, fiber — so the number you glance at is the number you edit.

Data is stored **only on your device**. There is no account, no server, and no sync. The one
outbound network call is to the LLM that turns "two eggs and sourdough toast" into numbers,
using an API key you supply.

> **Status: in development.** The Swift package (models, storage, goal engine, LLM parsing) is
> being built first; the SwiftUI app and widget targets follow. See "Project status" below.

---

## Table of contents

- [What you must fill in](#what-you-must-fill-in) — **read this before building**
- [Getting an API key](#getting-an-api-key)
- [Building](#building)
- [Architecture](#architecture)
- [GitHub Actions secrets](#github-actions-secrets)
- [Project status](#project-status)

---

## What you must fill in

The repository ships without Apple-account-specific values, because they are unique to you and
some cannot be shared. **The app will not build or run correctly until these are set.**

### 1. Signing and identifiers

Set these in `project.yml` (the XcodeGen manifest that generates `Tally.xcodeproj`), or
override them with a local `Secrets.xcconfig` — which is gitignored, so your team ID never
lands in version control.

| Value | Where | What it is | If you skip it |
|---|---|---|---|
| `DEVELOPMENT_TEAM` | `project.yml` | Your 10-character Apple Developer Team ID, from the Membership page of the developer portal. | Builds for the simulator still work. Installing on a physical device fails to sign. |
| Bundle ID prefix | `project.yml` | Reverse-DNS prefix you control, e.g. `com.yourname`. Targets become `<prefix>.tally` and `<prefix>.tally.widget`. | The placeholder prefix may already be taken, so provisioning fails. |
| App Group ID | `project.yml`, both targets | `group.<prefix>.tally`. Must be registered in the developer portal and enabled on **both** the app and widget targets. | **The widget shows no data.** The App Group container is how the widget reaches the database — without it the two targets have separate sandboxes. |
| Keychain access group | `project.yml` | `<team-id>.<prefix>.tally`. | The API key cannot be saved, so LLM logging is unavailable. |

The App Group is the one people most often get half-right. It has to be the *same string* on
both targets and registered in the portal; a mismatch fails silently at runtime rather than at
build time, and presents as a permanently empty widget.

### 2. Fonts

The design is set entirely in **Archivo** (weights 400, 600, 800). It is licensed under the SIL
Open Font License but is not redistributed here, so fetch it yourself:

1. Download from [Google Fonts](https://fonts.google.com/specimen/Archivo).
2. Put `Archivo-Regular.ttf`, `Archivo-SemiBold.ttf`, `Archivo-ExtraBold.ttf` into
   `App/Resources/Fonts/`.

If the files are absent the app falls back to the system font rather than crashing — it will
simply look wrong, losing the flat Modernist character the design depends on.

### 3. Info.plist usage descriptions

Each of these is a string iOS shows the user when it asks permission. **iOS terminates the app
immediately** if a capability is used without its description present, so a missing string is a
crash, not a degraded feature.

| Key | Needed for | Suggested text |
|---|---|---|
| `NSCameraUsageDescription` | Photographing a meal to log it | "Take a photo of a meal to estimate its calories and macros." |
| `NSPhotoLibraryUsageDescription` | Logging from an existing photo | "Choose a photo of a meal to estimate its calories and macros." |
| `NSMicrophoneUsageDescription` | Voice logging | "Describe what you ate out loud instead of typing it." |
| `NSSpeechRecognitionUsageDescription` | Transcribing voice logs | "Speech is transcribed on your device to turn what you say into a log entry." |
| `NSHealthShareUsageDescription` | Importing weight and workouts | "Read your weight and workouts from Health so Tally can fill them in for you." |

Tally requests **read-only** Health access and never writes back, so
`NSHealthUpdateUsageDescription` is not required.

### 4. URL scheme

The widget's quick-log buttons open the app through `tally://`. The scheme is declared in
`project.yml` under the app target's `CFBundleURLTypes`. Change it only if `tally` collides with
another app you have installed; if you do, update `DeepLink.scheme` in
`Sources/TallyCore/Routing/` to match, or the buttons will open the app to the default tab.

---

## Getting an API key

Text, photo, and voice logging call the Anthropic API with **your own key** — you are billed
directly, and there is no intermediary server.

1. Create a key at [console.anthropic.com](https://console.anthropic.com/settings/keys).
2. In Tally, open **Settings → AI logging** and paste it.

The key is stored in the **iOS Keychain**, never in `UserDefaults`, never in the App Group's
shared storage, and never written to logs. It is read only when a request is built, and sent
only to `api.anthropic.com`.

**Tally is fully usable without a key.** Every screen works and entries can be added by hand
with calories and macros typed in; the AI quick-log simply prompts you to add a key instead of
failing quietly. Because the key lives on the device, treat it as you would any credential in a
personal app — anyone with your unlocked phone can use it.

Model choice is in Settings. The default is `claude-opus-5` at low effort, which keeps
quick-log latency down; `claude-haiku-4-5` is offered for lower cost per log.

---

## Building

### The Swift package (works anywhere, including Linux)

All of Tally's logic — models, storage, goal arithmetic, LLM request and response handling,
deep-link routing — is a platform-agnostic SPM package, so it builds and tests without Xcode:

```sh
source scripts/dev-env.sh
swift test
```

### Building on Linux

Two prerequisites that a Mac gets for free:

- **A Swift 6.1 or newer toolchain.** Install from [swift.org/download](https://swift.org/download),
  or extract a tarball anywhere and point `SWIFT_TOOLCHAIN` at its `usr/` directory.

  6.1 is a hard floor, and the failure mode if you ignore it is nasty. GRDB's manifest declares
  `swift-tools-version:6.1`, and SPM silently skips dependency versions whose tools-version
  exceeds your toolchain — so an older Swift resolves *backwards* to a GRDB release that predates
  its Linux snapshot guard, and the build dies with undefined references to `sqlite3_snapshot_*`
  rather than telling you the toolchain is too old. The version floor in `Package.swift` now turns
  that into a clear resolution error instead.
- **SQLite headers.** GRDB compiles against `<sqlite3.h>`, which Ubuntu ships in a separate
  package (Apple platforms get SQLite from the SDK):

  ```sh
  sudo apt-get install -y libsqlite3-dev
  ```

  Without root, extract the matching-version headers instead — matching matters, because a
  newer header would make GRDB compile against APIs the installed library lacks:

  ```sh
  mkdir -p ~/.local/sqlite-dev && cd ~/.local/sqlite-dev
  apt-get download --print-uris libsqlite3-dev   # note the URL for your exact version
  curl -fsSLO '<the URL printed above>'
  dpkg-deb -x libsqlite3-dev_*.deb extracted
  mkdir -p lib && ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 lib/libsqlite3.so
  ```

  `scripts/dev-env.sh` picks that up automatically and prefers a real system install when one
  is present.

### The iOS app

Requires a Mac with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is **generated, not committed** — a YAML manifest is
reviewable and merges cleanly, where a `.pbxproj` is neither:

```sh
xcodegen generate
open Tally.xcodeproj
```

Re-run `xcodegen generate` after adding or removing source files.

---

## Architecture

```
Sources/TallyCore/     no dependencies — builds and tests anywhere
  Model/               Day, Entry, DayTotals, WeightSample, UserProfile, GoalSettings
  Store/               EntryStore / WeightStore / SettingsStore protocols + in-memory ones
  Goal/                BMR, weight trend, adaptive TDEE, daily goal
  LLM/                 NutritionParser protocol and the Anthropic implementation
  Routing/             deep-link parsing
Sources/TallyStore/    the SQLite conformances — the only target that links GRDB
App/                   SwiftUI app (Xcode only)
Widget/                WidgetKit extension (Xcode only)
```

**Storage is behind protocols on purpose.** Feature code, view models, widgets, and intents
depend on `EntryStore` / `WeightStore` / `SettingsStore` and never on a database type. The GRDB
conformances live in a separate module, so "don't reach past the abstraction" is enforced by the
module graph rather than by discipline — feature code cannot import GRDB even by accident.
Replacing SQLite with SwiftData or flat files means writing new conformances and editing one
composition root.

The in-memory stores in `TallyCore` are not only test doubles; they define the reference
semantics, and the same suite runs against both implementations to keep them in agreement.

**The daily goal is derived, not guessed.** It starts from a Mifflin-St Jeor estimate of your
expenditure and, once about two weeks of data exist, blends toward what your logged intake and
smoothed weight trend say your expenditure actually is. Daily weight is far too noisy to use
raw, so the trend is an exponentially-weighted average — that is also the line the 30-day chart
plots. The goal is clamped so an aggressive target can never produce a starvation number; if
your chosen rate would breach the floor, the app says so rather than silently obeying.

---

## GitHub Actions secrets

**The default CI needs no secrets at all.** It runs the package tests on Linux and builds the
app for the iOS Simulator with `CODE_SIGNING_ALLOWED=NO`, neither of which needs credentials.
Forks and pull requests work with no setup.

Optional, only if you want the extra capability:

| Secret | Enables | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | A smoke test that calls the real API once, verifying the request shape against the live endpoint. | Costs a fraction of a cent per run. The job is skipped when the secret is absent, so forks are unaffected. Never required — the parser's own tests use recorded fixtures and no network. |
| `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY` | TestFlight / App Store distribution. | Not used by the current workflow. Only add these if you add a release job. |

Do not add secrets you don't need. In particular there is no build-time API key: Tally reads
the key from the device Keychain at runtime, so baking one into the binary would leak it to
anyone who has the app.

---

## Project status

| Phase | State |
|---|---|
| 1. Toolchain, package scaffold | Done |
| 2. Domain model and storage | Done |
| 3. Goal engine | Done |
| 4. LLM nutrition parser | Done |
| 5. Xcode project, design system, CI | Done — CI green on both platforms |
| 6. Screens | Today, Log, History, Progress, Settings — build and launch |
| 7. Widgets and deep links | Both widgets build; `.appex` validates |
| 8. HealthKit, voice, Siri | Done |
| 9. Polish, UI tests, docs | Smoke tests passing; visual polish pending |

CI currently verifies, on every push:

- **210 tests** — 194 in the package on Linux, 13 app unit tests and 3 UI tests on an iOS simulator
- The app and widget compile, and `Tally.app` and `TallyWidget.appex` both validate
- The app launches, all four tabs are reachable, and the compose field enables sending

### Health, voice, and Siri

**Apple Health** import is read-only and user-triggered from Settings — Tally never writes to
Health and never syncs. Three rules are worth knowing because they're deliberate: a weight you
entered by hand is never overwritten; only one reading per day is taken, the earliest, since a
late-evening reading followed by a morning one would manufacture a swing that never happened; and
only a workout's **active** calories are counted, because total energy includes the basal calories
already inside your expenditure estimate.

**Voice** transcribes on the device (`requiresOnDeviceRecognition`). Audio never leaves the phone —
only the resulting text, and only if you send it. The transcript lands in the editable field first,
which is what makes on-device accuracy acceptable.

**Siri** works without opening the app: "log food in Tally", "how many calories do I have left in
Tally", "log my weight in Tally". The logging phrase confirms with the number it recorded rather
than just "done", so a bad estimate is noticeable while it's still easy to correct.

> ⚠️ **Nobody has looked at this app yet.** It compiles, launches, and its logic is well covered,
> but no screenshot of it has ever been seen — it was written on Linux against a design spec.
> Expect layout and spacing to need work once you run it: numbers that overflow their frames,
> spacing that reads differently on device than the design's mockups, and the Archivo font not
> loading until you add the files (see above).

Still to do:

- **Photo capture** in the Log screen. The parser already handles images end to end and is tested;
  only the camera/library picker is missing, which is why the button is visible but disabled.
- **Editing a logged entry's numbers.** Saved cards can be deleted but not corrected, which
  undercuts the "estimates are editable" premise the design leans on.
- **First-run onboarding**, rather than sending new users to Settings to find the fields the goal
  engine needs.
- **Visual polish against real screenshots** — see the warning above.

`design/tally-design.html` is the source design, kept for reference. Open it in a browser to see
the six specified surfaces.
