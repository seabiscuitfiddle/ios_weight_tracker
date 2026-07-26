# Tally

An iOS calorie and exercise tracker built around **one net number**:

```
net calories = food − exercise
```

shown everywhere as `x / y` against a daily goal derived from your weight target. The lock
screen, the home-screen widget, and the app all lead with the same three metrics — net
calories, protein, fiber — so the number you glance at is the number you edit.

Data is stored **only on your device**. There is no account, no server, and no sync. The one
outbound network call is to the LLM that turns "two eggs and sourdough toast" into numbers —
**your choice of provider**, with a key you supply. Claude, ChatGPT, anything on OpenRouter,
DeepSeek, Kimi, GLM and Qwen directly, your own endpoint, or Apple's on-device model, which
makes even that one call unnecessary.

> **Status: in development.** The Swift package (models, storage, goal engine, LLM parsing) is
> being built first; the SwiftUI app and widget targets follow. See "Project status" below.

---

## Table of contents

- [Running it on a Mac](#running-it-on-a-mac) — **start here**
- [What you must fill in](#what-you-must-fill-in)
- [Choosing an AI provider](#choosing-an-ai-provider)
- [Building](#building)
- [Architecture](#architecture)
- [Keeping this repository publishable](#keeping-this-repository-publishable)
- [GitHub Actions secrets](#github-actions-secrets)
- [Project status](#project-status)
- [License](#license)

---

## Running it on a Mac

### The short version

Needs **Xcode 16.3 or newer**, which in turn needs macOS 15 (Sequoia). See
[Why 16.3 and not 16](#why-xcode-163-and-not-just-xcode-16) — `bootstrap.sh` checks this first
and stops with an explanation if the Xcode in front of it is older.

```sh
git clone <this repo> && cd ios_weight_tracker
brew install xcodegen          # only tool you need beyond Xcode
./scripts/bootstrap.sh         # generates Tally.xcodeproj, reports anything outstanding
xed Tally.xcodeproj            # then ⌘R
```

**On the simulator that is genuinely all of it.** No Apple Developer account, no team ID, no
App Group registration, no API key. The placeholder bundle prefix is fine, because a simulator
build isn't signed against a real identity.

`bootstrap.sh` is safe to re-run, and re-run it after adding or removing source files — the
`.xcodeproj` is generated from `project.yml`, not committed, because a `.pbxproj` is thousands of
lines of unreviewable XML that merges badly.

To run the same checks CI runs: `./scripts/run-tests.sh`.

### Why Xcode 16.3, and not just Xcode 16

Two separate things fail on an older Xcode, and neither error names the version you need.

**The project will not open.** XcodeGen writes the Xcode 16 project format, and Xcode 15 and
earlier refuse it:

```
The project 'Tally' cannot be opened because it is in a future Xcode project file format (77).
```

**The build then needs Swift 6.1**, which arrived in Xcode 16.3 — Xcode 16.0 through 16.2 ship
Swift 6.0, so "Xcode 16" is genuinely not enough. The floor is GRDB's, not a preference: its
manifest declares `swift-tools-version:6.1`, and SPM silently skips dependency versions whose
tools-version exceeds the toolchain, so an older Swift resolves *backwards* to a GRDB release
that predates its Linux snapshot guard and fails to link. The version floor in `Package.swift`
turns that into a clear resolution error, and `bootstrap.sh` catches it one step earlier.

| | Minimum | Why |
|---|---|---|
| macOS | 15 (Sequoia) | What Xcode 16.3 itself requires |
| Xcode | 16.3 | First release with a Swift 6.1 toolchain |
| Swift | 6.1 | GRDB 7.11.1's manifest is `swift-tools-version:6.1` |
| XcodeGen | any current | `brew install xcodegen` |

The deployment target is iOS 17, which is unrelated to any of the above — it is what the app
runs *on*, not what it is built *with*.

### What works immediately, and what needs setup

| | Simulator, no setup | Needs setup |
|---|---|---|
| All five screens, navigation | ✅ | |
| Adding entries by hand, weight logging, goal calculation | ✅ | |
| Data persisting across launches | ✅ | |
| Correct typography | | Archivo font files — see [Fonts](#2-fonts) |
| AI logging by text | On iOS 26+ with Apple Intelligence | Otherwise an API key for any supported provider, pasted into Settings |
| Widgets showing data | | App Group registered for your team |
| HealthKit import | | A real device (Health has no simulator data) |
| Voice input | | A real device (no simulator microphone) |
| Siri phrases | | A real device |

### Two things you'll notice on first run

**The app looks wrong until you add the fonts.** The whole design is set in Archivo, and without
the files SwiftUI silently falls back to the system font. It won't crash, but don't judge the
layout until they're in place — see [Fonts](#2-fonts). `bootstrap.sh` warns you if they're absent.

**You may see a grey banner saying the widget won't show your data.** That is expected on a
simulator without a registered App Group, and it is *not* data loss: Tally falls back to its own
private container, so everything you log is saved and survives relaunching. Only the widget is
affected, because it reads the shared container. The banner disappears once the App Group resolves.

If you ever see a *red* banner saying entries are not being saved, that's different and real — no
database could be opened at all.

### Putting it on your own iPhone

Two values and one registration. Both values go in `.env` — `cp .env.example .env` — and not into
any tracked file: this repository is public, and a Team ID identifies your developer account.

1. **`BUNDLE_ID_PREFIX`** — change the `com.example` placeholder to something you own.

   This is deliberately a single edit. The bundle IDs, both entitlements files, the App Group, and
   the keychain group all derive from it, and the runtime code derives the App Group from the
   bundle identifier rather than hardcoding it. Nothing else needs changing.

2. **`DEVELOPMENT_TEAM`** — your 10-character Team ID, from Xcode › Settings › Accounts, or the
   Membership page of the developer portal.

3. **Register the App Group** `group.<your-prefix>.tally` in the developer portal, and enable the
   App Groups capability on **both** the app and widget targets.

Then `./scripts/bootstrap.sh` again, and Run with your device selected.

> Step 3 is the one worth double-checking. If the group isn't registered, or is enabled on only one
> target, there is **no build error** — the app and widget just get separate containers and the
> widget stays empty forever. The grey banner described above is the app telling you this happened.

With a free Apple ID rather than a paid account, expect two limitations: the build expires after
seven days, and App Groups aren't available, so you'll get the grey banner and a blank widget. The
app itself works fine.

---

## What you must fill in

The repository ships without Apple-account-specific values, because they are unique to you and
some cannot be shared. **None of them are needed to run on a simulator** — see
[Running it on a Mac](#running-it-on-a-mac). They matter for a physical device.

### 1. Signing and identifiers

**These go in a local `.env`, never in a tracked file.** This repository is public, and an Apple
Team ID identifies the account that owns it.

```sh
cp .env.example .env      # then fill it in
./scripts/bootstrap.sh    # loads .env and regenerates the project
```

| Value | What it is | If you skip it |
|---|---|---|
| `BUNDLE_ID_PREFIX` | A reverse-DNS prefix you own, e.g. `dev.yourname`. Targets become `<prefix>.tally` and `<prefix>.tally.widget`. | Simulator builds work. On a device, the placeholder `com.example` may already be taken, and provisioning fails. |
| `DEVELOPMENT_TEAM` | Your 10-character Apple Developer Team ID, from Xcode › Settings › Accounts. | Simulator builds work. Installing on a device fails to sign. |

How they reach the build is worth one paragraph, because two different substitutions are
involved. `scripts/load-env.sh` exports what is in `.env`; XcodeGen then replaces `${VAR}` in
`project.yml` as it generates the project. Anything it leaves alone — because you have no `.env`,
which is the normal case — is expanded by **Xcode** at build time from the placeholder settings
in `project.yml`. That is why a fresh clone with no configuration at all still builds and runs on
the simulator as `com.example.tally`.

**`BUNDLE_ID_PREFIX` is a single edit.** Everything derived from it follows automatically:

- Bundle identifiers, via `project.yml`
- The App Group in both entitlements files, via the `$(APP_GROUP_ID)` build setting — defined
  once in `project.yml` so the widget cannot end up pointing at a different container than the app
- The keychain group, which is the app's own `$(PRODUCT_BUNDLE_IDENTIFIER)` and so cannot drift
- The App Group the *running code* looks up, which is derived from the bundle identifier at
  runtime rather than hardcoded — `TallyDatabase.appGroupIdentifier(for:)`, unit-tested
- The keychain service name, likewise derived from the bundle

That is deliberate. When these were separate literals, changing the prefix meant editing five
places, and missing one produced no build error — just a widget that never showed data.

### The App Group, which is the one people get half-right

You still have to **register** `group.<your-prefix>.tally` in the developer portal and enable the
App Groups capability on **both** targets. A mismatch, or enabling it on only one, fails silently at
runtime rather than at build time.

Tally handles that failure deliberately rather than crashing: it falls back to its own private
container, so **your data is still saved and survives relaunching**, and shows a grey banner
explaining that only the widget is affected. A red banner means something worse — no database could
be opened at all.

### 2. Fonts

The design is set entirely in **Archivo** (weights 400, 600, 800). It is licensed under the SIL
Open Font License but is not redistributed here, so fetch it yourself:

1. Download from [Google Fonts](https://fonts.google.com/specimen/Archivo) — the "Get font"
   button gives you a zip.
2. Create `App/Resources/Fonts/` and put the `.ttf` files in it. Either form works:
   - the static faces `Archivo-Regular.ttf`, `Archivo-SemiBold.ttf`, `Archivo-ExtraBold.ttf`, or
   - the single variable font `Archivo[wdth,wght].ttf`, which Google Fonts now ships by default.

   Both register the family name `Archivo`, which is what the code asks for. `project.yml` lists
   all four filenames in `UIAppFonts`; entries for files you don't have are harmless.
3. Re-run `./scripts/bootstrap.sh` so the new files are picked up.

If the files are absent the app falls back to the system font rather than crashing — it will simply
look wrong, losing the flat Modernist character the design depends on. `bootstrap.sh` warns you when
it can't find them.

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

## Choosing an AI provider

Text, photo, and voice logging call a language model with **your own key** — you are billed by
that provider directly, and there is no intermediary server. Open **Settings → AI logging** to
pick one.

| | Where to get a key | Notes |
|---|---|---|
| **Apple on-device** | none needed | iOS 26+ with Apple Intelligence. Free, offline, nothing leaves the phone. Rougher portion estimates, and no photos. |
| **Anthropic** | [console.anthropic.com](https://console.anthropic.com/settings/keys) | The default. Strict schema support. |
| **OpenAI** | [platform.openai.com](https://platform.openai.com/api-keys) | Strict schema support. |
| **OpenRouter** | [openrouter.ai/keys](https://openrouter.ai/keys) | One key, several hundred models including every Chinese lab. The easy way to try them. |
| **DeepSeek, Moonshot (Kimi), Zhipu (GLM), Alibaba (Qwen)** | each provider's console | Cheaper than routing through OpenRouter. Most support JSON mode but not strict schemas — see below. |
| **Custom** | your own | Any OpenAI-compatible endpoint: a gateway, a self-hosted model, or Ollama / LM Studio on your network, where no key is needed at all. |

The model is a **free-text field**, not a fixed list, because identifiers change faster than any
shipped app can keep up with. "Fetch models" asks the provider what your key can actually reach.

Keys are stored in the **iOS Keychain**, never in `UserDefaults`, never in the App Group's shared
storage, and never written to logs. There is **one item per provider**, so switching between them
doesn't mean pasting a key in again and no provider can be sent a key minted for another. A key is
read only when a request is built, and sent only to that provider's own host — which the settings
footer names explicitly.

**Tally is fully usable without any of this.** Every screen works and entries can be added by hand
with calories and macros typed in; the AI quick-log prompts you to add a key instead of failing
quietly. Because keys live on the device, treat them as you would any credential in a personal
app — anyone with your unlocked phone can use them.

### Why structured output is the interesting part

Tally asks for a JSON document matching a schema. Only some providers can enforce that:

- **Strict `json_schema`** — OpenAI, Anthropic, OpenRouter (model permitting). The reply is
  guaranteed to match.
- **JSON mode only** — DeepSeek, Qwen and most compatible-mode endpoints. Valid JSON, schema
  ignored, so the schema is sent in the prompt instead.
- **Neither** — self-hosted and older endpoints. Schema in the prompt, and the reply is scraped
  for the first JSON document in it.

Each provider declares which it supports and `LLMWire` adapts, so the app passes a schema once and
never branches on vendor. The decoder is deliberately forgiving under the weaker two: `"280"`
where `280` was asked for costs one field, not the whole meal.

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

See [Running it on a Mac](#running-it-on-a-mac) — `./scripts/bootstrap.sh` does the setup. The
short version is Xcode 16.3+ (Swift 6.1, on macOS 15), `brew install xcodegen`, then:

```sh
./scripts/bootstrap.sh    # or: xcodegen generate
xed Tally.xcodeproj
```

The `.xcodeproj` is **generated, not committed**, so re-run bootstrap after adding or removing
source files. `./scripts/run-tests.sh` runs everything CI runs, including the simulator tests.

### The app icon

The icon is drawn in code, not stored as artwork:

```sh
swift scripts/render-icon.swift   # rewrites App/Resources/Assets.xcassets/AppIcon.appiconset
```

It is a body, an arrow, and the same body taken in, in the design system's paper/ink/accent. The
generator is committed for the same reason the palette lives in `TallyCore`: a proportion or a
hex value that drifts from the design shows up in a diff rather than only in a screenshot. Edit
the script and re-run it — the PNGs it emits are build products that happen to be checked in.

It writes all three appearances iOS 18 asks for: the light icon, a **dark** one, and a
**tinted** greyscale one. Only the light icon paints its own background — the system draws the
ground behind the other two, so they are rendered on transparency, and the tinted one is
greyscale because iOS keys the user's tint to its luminance rather than to its colours.

---

## Architecture

```
Sources/LLMWire/       provider-agnostic LLM calling — MIT licensed, no dependencies,
                       knows nothing about Tally. Two wire formats (Anthropic Messages,
                       OpenAI Chat Completions), provider definitions, error taxonomy.
Sources/TallyCore/     depends only on LLMWire — builds and tests anywhere
  Model/               Day, Entry, DayTotals, WeightSample, UserProfile, GoalSettings, AISettings
  Store/               EntryStore / WeightStore / SettingsStore protocols + in-memory ones
  Goal/                BMR, weight trend, adaptive TDEE, daily goal
  LLM/                 the nutrition prompt, schema, and result validation
  Routing/             deep-link parsing
Sources/TallyStore/    the SQLite conformances — the only target that links GRDB
App/                   SwiftUI app (Xcode only), including the on-device parser
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

**The AI provider is data, not a type.** Adding one is a value in `LLMWire.builtIn` — an
endpoint, a wire format, and a declaration of what it can do about JSON schemas and images — not
a new parser and never a branch in a screen. `LLMWire` abstracts the *transport* rather than the
generation call, which is what keeps the whole path testable: every request goes through an
`HTTPTransport`, so both wire formats are verified against recorded responses on a machine with
no Xcode, no network and no key.

**The daily goal is derived, not guessed.** It starts from a Mifflin-St Jeor estimate of your
expenditure and, once about two weeks of data exist, blends toward what your logged intake and
smoothed weight trend say your expenditure actually is. Daily weight is far too noisy to use
raw, so the trend is an exponentially-weighted average — that is also the line the 30-day chart
plots. The goal is clamped so an aggressive target can never produce a starvation number; if
your chosen rate would breach the floor, the app says so rather than silently obeying.

---

## Keeping this repository publishable

Everything account-specific is kept out of tracked files by construction rather than by care:

| Where it lives | What it holds | Why not in the repo |
|---|---|---|
| `.env`, gitignored | `BUNDLE_ID_PREFIX`, `DEVELOPMENT_TEAM` | An Apple Team ID identifies its owner. Template: `.env.example`. |
| GitHub repository secrets | The same two, optional | Only needed if you add a job that signs for a device. |
| The device keychain | Your API keys, one item per provider, keyed by provider id | Entered in Settings at runtime. There is no build-time key for any provider, so no binary can leak one, and no provider can be sent a key minted for another. |

Three things enforce it, in increasing order of how late they catch you:

1. `scripts/check-secrets.sh` — scans tracked files for API keys, Team IDs, hardcoded App
   Groups, and personal email addresses. Each finding prints what to do about it. The key
   patterns are matched by *shape* rather than by vendor — `sk-` followed by a long opaque
   string covers Anthropic, OpenAI, OpenRouter, DeepSeek, Moonshot and Alibaba alike, with a
   second pattern for Zhipu's `id.secret` form — so adding a provider to Settings does not
   quietly leave a new key shape unguarded. Short fixtures like `sk-ant-test` are below the
   length floor and don't trip it.
2. A **pre-commit hook**, installed by `./scripts/bootstrap.sh`, running that same script over
   what is staged. `git commit --no-verify` still bypasses it; it is a safety net, not a lock.
3. A **CI job**, so a leak fails the build even if the hook was never installed.

```sh
./scripts/check-secrets.sh          # everything tracked
./scripts/check-secrets.sh --staged # what you are about to commit
```

The one thing none of this can reach is **history**. A value that was committed and then removed
is still in the repository, and `git log -p` will find it — the fix for that is a history rewrite
(`git filter-repo`) and a force push, not a follow-up commit.

---

## GitHub Actions secrets

**The default CI needs no secrets at all.** It runs the package tests on Linux and builds the
app for the iOS Simulator with `CODE_SIGNING_ALLOWED=NO`, neither of which needs credentials.
Forks and pull requests work with no setup.

Optional, only if you want the extra capability:

| Secret | Enables | Notes |
|---|---|---|
| `BUNDLE_ID_PREFIX`, `DEVELOPMENT_TEAM` | Generating the project with your own identifiers, for a job that builds or signs for a device. | Both are read by the "Generate project" step. Absent — the normal case, and always on forks — the placeholders in `project.yml` are used instead. |
| `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY` | TestFlight / App Store distribution. | Not used by the current workflow. Only add these if you add a release job. |

Do not add secrets you don't need. **There is no API key secret, for any provider, and nothing
here needs one.** Tally reads keys from the device Keychain at runtime, so baking one in would
leak it to anyone who has the app — and CI proves the wire formats against recorded fixtures
rather than against a live endpoint, which is faster, free, and works on forks.

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

- **279 tests** — 263 in the package on Linux, 13 app unit tests and 3 UI tests on an iOS
  simulator. Both LLM wire formats are covered by recorded fixtures, so no key and no network
  are needed to verify what Tally actually sends
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

---

## License

Copyright (C) 2026 seabiscuitfiddle.

[GNU General Public License v3.0](LICENSE). In short: use it, study it, change it, share it —
but anything you distribute that is built from this code has to carry the same freedoms, source
included.

The full text is in [`LICENSE`](LICENSE). Per-file copyright headers have deliberately not been
added; the license file covers the work, and headers on every source file would bury the
explanatory comments that are the point of this codebase.

Three things carry their own terms and are **not** covered by it:

- **Archivo**, the typeface the design uses, is under the SIL Open Font License and is not
  redistributed here — you download it yourself (see [Fonts](#2-fonts)).
- **`Sources/LLMWire/`** is **MIT** licensed, not GPL — see [`Sources/LLMWire/LICENSE`](Sources/LLMWire/LICENSE).
  It is a self-contained, dependency-free library that knows nothing about Tally, kept in a form
  that can be lifted into its own repository with a `git mv`. The rest of this repository remains
  GPL-3.0.
- **GRDB.swift**, the only third-party dependency, is MIT-licensed. Its terms are in
  `.build/checkouts/GRDB.swift/LICENSE` after a build, and in its repository.
