# Agent Instructions for AudioLens

## Project Context
This is a **Flutter mobile app** for AI-powered audio guides. The app:
- Runs **on-device** in real-world conditions (museums, outdoor visits)
- Often operates **without direct logcat access**
- Must remain **responsive** during long operations (AI analysis, TTS, GPS)
- Relies on **in-app logs screen** for field debugging

**Key technologies**: Flutter, Dart, Gemini Nano/API, native Android TTS (`flutter_tts`), SQLite, EXIF/GPS, Wikipedia API.

---

## Git Workflow

`main` is protected (2026-08-15): no direct pushes, even for admins. All
changes go through a branch + PR. Both `Test` (flutter analyze + flutter
test) and `Build Android APK` must pass before merging.

Both `Build Android APK` and `Test` (2026-08-20 onward) skip their actual
work — reporting `skipped`, not `pass` — when a push/PR touches only
`.md` files, or only files under `benchmark/`
(including its own `.github/workflows/benchmark.yml`) — none of that has
any bearing on the app itself. This is intentional (avoids the ~5-6 min
Android build and the Flutter analyze/test run for changes that don't
touch the app) and still satisfies the required check; it does NOT use
`paths-ignore` on the trigger (that would leave the check permanently
"Expected" and block merging), it's a job-level skip via a fast
preceding `changes` job in each workflow. `workflow_dispatch` (manual
publish) always runs the full build regardless.

Within a build that does run, the "Build Android APK" job (2026-08-22
onward) only builds the artifact each trigger can actually use — a `pull_request`
never gets published, so it only builds the APK (a release-build/signing
sanity check, and useful for direct-sideload QA); a plain `push` to
`main` only builds the AAB (what `publish-play-store.yml` actually
consumes); `workflow_dispatch` builds both, since it publishes
immediately after. `assembleRelease`/`bundleRelease` are separate
Gradle invocations sharing the same build graph, so this roughly halves
native build time on the two most frequent triggers instead of building
both artifacts on every run for no benefit.

Backlog/task tracking moved from a `TODO.md` file to
[GitHub issues](https://github.com/Nohzoh/AudioLens/issues) (2026-08-22).
Every change merged to `main` must reference an issue (2026-09-08) — no
exceptions for small or direct-ask changes; if the work started from a
conversational request with no pre-existing tracking issue, file one
first (before/during the work, not after merge) rather than landing
without a reference. The only changes exempt from this are `ship`'s own
`chore/publish-v*` PRs, which are never numbered release items
themselves. Reference the issue in the PR body/commit (`Closes #<n>`) —
GitHub closes it automatically on merge — and add an entry to
CHANGELOG.md under "Done" (with what was actually verified) in the
**same PR** as the code, as a follow-up commit once the PR number is
known so the changelog entry can reference it. This halves PR/CI-run count
versus a separate docs-only PR per task (2026-08-16).

Issues (title and body) are written in English (2026-09-08), regardless
of what language the surrounding conversation happens to be in — same
as commit messages, which are already English-only.

```
git checkout -b <branch-name>
# ... commit the code change(s) ...
git push -u origin <branch-name>
gh pr create --title "..." --body "...\n\nCloses #<n>"
# update CHANGELOG.md now, referencing the PR number, commit + push to
# the same branch; wait for both checks to go green, then:
gh pr merge <number> --merge --delete-branch
```

### Commit Messages

Conventional Commits (2026-08-16 onward — not retroactive, existing
history stays as-is): `<type>[optional scope]: <description>`.

Types used in this project: `feat`, `fix`, `docs`, `refactor`, `test`,
`ci`, `build`, `chore`, `style`, `perf`. Scope is optional (e.g.
`feat(tts): ...`). Keep the summary line under ~72 chars; put the "why"
in the body, as usual.

```
feat: run analysis in the background and notify when audio is ready
fix(location): stop leaking the GPS listener on cancel
docs: translate TODO.md and CHANGELOG.md to English
```

PR titles aren't required to follow this format (this repo uses
`--merge`, not squash, so the PR title never becomes a commit message),
but doing so anyway is fine for consistency.

### Version Numbering (2026-08-19 onward)

`pubspec.yaml`'s `version: X.Y.Z+build` — the two halves are independent
and never touched for the same reason:

- **`+build`** (the Android `versionCode`) is **fully automatic**, set at
  build time via `--build-number=${{ github.run_number }}` in both CI
  workflows. Never hand-edit it — it only has to strictly increase for
  Play Console to accept an upload, and the run number already
  guarantees that.
- **`X.Y.Z`** (the human-readable version name) follows these rules:
  - **Z (patch)**: bump on every publish to *any* Play Store track
    (internal, closed, open, production) — mechanical, no judgment
    call, one bump per `workflow_dispatch` "Publish to Play Store" run.
  - **Y (minor)**: bump instead of Z when that release ships a genuine
    new user-facing feature (not just a fix/polish) — the one judgment
    call, made when writing that release's CHANGELOG.md entry. Resets
    Z to 0.
  - **X (major)**: reserved for `1.0.0` = the first production
    (public) release, and afterward for major redesigns or breaking
    changes. Resets Y and Z to 0.

### Remote Config Signing (2026-08-20 onward)

`config.json` is fetched at every app startup from
`raw.githubusercontent.com` and applied *immediately* to every installed
build — unlike a code change, it bypasses the whole release pipeline
(CI, Play Store review, staged rollout). It's therefore signed
(Ed25519) so that write access to the repo or CI alone is not enough to
push a config change the app will accept.

**The private signing key never touches CI, GitHub secrets, or this
repo — it lives offline (Keeper) and only ever gets used locally.**
This is the entire point: even a fully compromised CI run can edit
`config.json`'s content but cannot produce a valid signature for it.

**Whenever `config.json` changes**, after editing it:
```bash
dart run scripts/sign_config.dart   # prompts for the private key (Keeper)
git add config.json config.json.sig # always commit both together
```
`RemoteConfigService.load()` fetches both `config.json` and
`config.json.sig`, verifies the signature against the public key
embedded in `lib/services/remote_config_service.dart`, and falls back
to the built-in defaults (same as a network failure) if verification
fails for any reason — it never applies an unsigned or tampered body.

Key rotation (only if the private key is ever suspected compromised):
`dart run scripts/generate_config_signing_key.dart`, save the new
private key to Keeper, update the public key constant in
`remote_config_service.dart`, re-sign `config.json`, ship a new app
version (old installs keep trusting the old public key until they
update).

### Publishing to Play Store — two paths (2026-08-22 onward)

- **`build-android.yml`'s `workflow_dispatch`** — full fresh build (~8-10
  min) then publish, always against `main`'s current tip. Use this when
  no recent build exists yet, or you need to publish a commit that was
  never built on `main`.
- **`publish-play-store.yml`'s `workflow_dispatch`** — the fast path:
  reuses the AAB/mapping artifacts from an already-completed
  `build-android.yml` run (defaults to the latest successful one on
  `main`; pass a specific `run_id` to target another) instead of
  rebuilding. Every push to `main` already produces a tested AAB
  artifact (30-day retention), so this is the normal choice once one
  exists — it skips the rebuild entirely. **Important**: it checks out
  the repo at *that build's* commit to read `distribution/whatsnew/*`
  and the package name — not whatever `main` is at dispatch time — so
  the release notes below must already be committed and merged *before*
  the build you're about to publish ran, not just before you click
  "Run workflow." If they're not, either use `build-android.yml`'s path
  instead (always fresh) or push the whatsnew update first and wait for
  the next `main` build.

### Play Store Release Notes (2026-08-20 onward)

Before publishing (either path above), update
`distribution/whatsnew/whatsnew-fr-FR` and `whatsnew-en-US` with a
short, tester-facing summary of what changed since the last publish —
plain language, not the technical CHANGELOG.md wording. Google enforces
a 500-character limit per file; CI passes this directory to
`r0adkll/upload-google-play` via `whatsNewDirectory`, which shows it to
testers as "What's new in this version." If left unchanged, testers
just see the previous release's notes again, so treat updating these
files as part of the release checklist, not optional.

**Owned by the coding agent, not the user**: whichever agent is about
to trigger a Play Store publish updates both files itself first —
summarizing the CHANGELOG.md entries added since the previous publish
in plain, tester-facing language — rather than asking the user to
write them. Only check in with the user if a change is too ambiguous
to summarize confidently on its own.

### Play Store Listing Icon (2026-08-21 onward, background revised 2026-08-26)

`distribution/play-store/icon-512.png` is the source of truth for the
Play Console store listing icon — a flat, opaque 512×512 PNG (T110:
the original mipmap launcher icon has transparent corners around a
white body, and Play Console requires a flat, opaque upload). Its
background is plain white (#251) — matching `generate_app_icon.py`'s
actual launcher icon design, not the brand purple T110 originally
tried. Purple was a one-off invented specifically for this one asset
and matched nothing else the icon looks like elsewhere (home screen,
widget); that inconsistency turned out to be a worse problem than the
"flattens to white" issue it was meant to solve, confirmed against the
real app icon and a 3-way visual comparison before switching back.
This is **not** wired into any automated upload — Play Console's app
icon isn't part of what `r0adkll/upload-google-play` manages, so after
regenerating this file, upload it manually via Play Console → your app
→ Grow → Store presence → Main store listing → App icon.

---

## Global Guidelines for All Agents

### Code Quality
- Keep the **architecture modular**: separate concerns between screens, services, and persistence
- Prefer **small, focused changes** over large rewrites
- Maintain **backward compatibility** with existing history and logs
- Follow **existing patterns** before introducing new ones

### Debugging & Logging
- **Always use `AppLogger`** instead of `print`/`debugPrint`
- **Log categories** to use when relevant:
  - `INFO` — general flow
  - `ERROR` — failures
  - `TTS` — speech generation/playback
  - `AI` — analysis pipeline events
  - `GPS` — location events
  - `DB` — persistence/storage issues
  - `NAV` — screen/activity opened/closed (2026-08-26, #255) — logged from
    each relevant screen's own `initState`/`dispose`, not from a central
    router, so it stays accurate through any navigation path (push,
    pushReplacement, a notification tap) without needing to be threaded
    through every call site that navigates
- **Never log secrets**: API keys, tokens, or sensitive user data
  (coordinates, addresses...). Never log a caught exception's raw
  `toString()` directly — wrap it in `sanitizeError()`
  (`lib/utils/error_sanitizer.dart`) first, since a failed HTTP request's
  exception message can carry the request URL, and this project's API
  calls put the key in the URL's query string. CI runs
  `scripts/check_log_hygiene.py` as a cheap heuristic backstop for this
  (T126) — a genuine false positive can be suppressed with a
  `// log-hygiene-ok: <reason>` comment near the flagged call.
- **Keep logs** short, structured, and actionable
- Ask: *"Can this issue be diagnosed from the in-app logs screen?"*

### User Experience
- **Never fail silently** — surface errors clearly in the UI
- **Provide feedback** for long operations (progress indicators, cancel buttons)
- **Keep the UI responsive** — avoid blocking the main thread
- **Fallback gracefully** — if a feature fails, offer an alternative or clear error
- **Mobile-first mindset**: assume limited connectivity, offline use, no laptop for debugging

### Project-Specific Considerations
- **AI Pipeline** (Gemini Nano/API): changes must remain observable and debuggable
- **TTS** (native Android TTS/Gemini TTS): add logs for playback issues, latency, or failures
- **GPS/Location**: handle permission denials, timeouts, and EXIF fallback
- **Dependencies**: verify license compatibility (project uses open-source licenses)
- **Offline support**: prioritize local-first approaches with cloud fallback

---

## Agent-Specific Notes

### For Coding Agents (Vibe, Cursor, etc.)
- Read relevant files **before editing** (the file itself, its tests, callers)
- Match **existing code style** (indentation, naming, error handling)
- Prefer **minimal changes** — don’t refactor unrelated code
- **Test your changes** where possible
- Use **type-safe patterns** (Dart is strongly typed)

### For GitHub Copilot / Copilot Chat
- Follow the **debugging conventions** strictly (AppLogger usage)
- Remember: **no logcat access in production** — logs must be visible in-app
- Prioritize **field usability** over development convenience

### For Review Agents
- Check that **new features are observable** via logs or UI
- Verify **error paths** are handled and user-visible
- Ensure **offline scenarios** are considered
- Confirm **license compatibility** for new dependencies

---

## Quick Reference
| Area | Key Files | Log Category |
|------|-----------|--------------|
| AI Analysis | `lib/services/gemini_*`, `ai_service.dart` | `AI` |
| TTS | `lib/services/native_tts_service.dart`, `gemini_tts_service.dart` | `TTS` |
| GPS/Location | `lib/services/location_service.dart`, `exif_location_service.dart` | `GPS` |
| Logging | `lib/utils/app_logger.dart` | `INFO`/`ERROR` |
| Storage | `lib/services/history_service.dart` | `DB` |
