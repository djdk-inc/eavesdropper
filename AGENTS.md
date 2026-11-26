# AGENTS.md

How Eavesdropper is built, where its pieces come from, and what "shippable" means. Read this before changing anything.

## What it is

A macOS menu bar app that notices Zoom and Google Meet calls, records both sides on this Mac, transcribes them on-device, labels speakers by voice, and titles each meeting from its Google Calendar invite. It never joins calls.

## Isolation model (the core invariant)

Two processes with one-way data flow:

| Process | Holds | Network | Enforced by |
|---|---|---|---|
| `Eavesdropper.app` (recorder) | Audio, transcripts, speaker labels, UI | **None** | App Sandbox (`Eavesdropper.entitlements`, no `network.client`/`network.server`) |
| `Eavesdropper Calendar.app` (helper, in `Contents/Helpers`) | Invite metadata only | Yes: `gcloud` + the private iCal URL | Code review; it never receives meeting data |

- The helper writes `~/Library/Application Support/Eavesdropper Calendar/calendar.json`. The recorder may only **read** that folder.
- Meeting data lives in the recorder's container: `~/Library/Containers/com.djdk.eavesdropper/Data/Recordings/Eavesdropper/<meeting>/` (`meeting.json`, `mic.m4a`, `call.m4a`). macOS keeps other apps out of containers.
- These stay true with every change:
  - The recorder target (`Sources/Eavesdropper`) has no network access. Its only networking code is `--network-selftest`, which must fail.
  - Any network need goes in `Sources/EavesdropperCalendar` and carries metadata only.
  - `verify.sh` passes: the recorder is sandboxed, has no network entitlement, and can't reach the network by hostname or raw IP.

## Layout

| Path | What |
|---|---|
| `Sources/EavesdropperCore` | Pure logic, no system access: call detection, iCal parsing and invite matching, meeting model and store, speaker labelling, calendar snapshot |
| `Sources/Eavesdropper` | The recorder: Core Audio capture, transcription, diarization, menu bar and window |
| `Sources/EavesdropperCalendar` | The networked calendar helper |
| `Sources/DetectorChecks` | Offline checks for Core (`swift run DetectorChecks`) |
| `Vendor/FluidAudio` | Trimmed copy of FluidAudio's offline diarizer (see `NOTICE` for what changed) |
| `Models/speaker-diarization` | Core ML diarization model, bundled into the app |
| `Eavesdropper.entitlements` | The recorder's sandbox contract |
| `VERSION`, `.swift-toolchain` | Release version; pinned compiler |

## Development process

- **Local first.** The build-and-debug loop runs on fixtures with no network and no cost. Core logic gets a check in `DetectorChecks` before it ships.
- **Branches and worktrees.** Work happens on a branch in its own git worktree, never in the main checkout. Finished work goes to `main` through a squash-merged PR, merged as soon as it's verified (no need to ask).
- **No new dependencies.** `Package.swift` has no external packages, and nothing is fetched at build time or run time. Outside code is vendored with its license and a NOTICE of changes; models live in `Models/` with provenance.
- **Crash safety.** Audio is recorded as uncompressed CAF, which stays readable after a hard kill; `.m4a` doesn't. It's compressed to `.m4a` after transcription. SIGTERM, SIGINT and Quit save the meeting as `transcribing`, and launch recovers every `recording`/`transcribing` meeting (`recoverUnfinished`). Background work changes meetings only through `MeetingStore.update`, one field at a time, never by saving a stale copy.
- **Don't rebuild over a running app.** Replacing the bundle under a running process invalidates its signature, and macOS then hands it silent audio. `./build.sh install` quits the app before replacing it.
- **Stable signing.** Every build is signed with the local "DJDK Local Code Signing" certificate (`./build.sh` creates and trusts it on first run; override with `CODESIGN_IDENTITY`). macOS keys privacy grants on `identifier "com.djdk.eavesdropper" and certificate leaf`, so grants survive rebuilds. Never sign ad-hoc (`--sign -`) and never change the bundle identifiers: either resets every grant. `build-app.sh` falls back to ad-hoc with a warning only when the certificate is missing. Releases and `verify-reproducible.sh` sign ad-hoc on purpose (`CODESIGN_IDENTITY=-`): a certificate signature embeds its signing time, so only ad-hoc builds are byte-identical.

## How to operate

Same three commands as every djdk-inc Mac app (Campfire, Zen):

```bash
./build.sh test             # logic checks (DetectorChecks)
./build.sh                  # hermetic release build → dist/Eavesdropper.app (network denied during the build)
./build.sh install          # test + build + verify.sh, quit the running app, replace /Applications/Eavesdropper.app, launch
```

Underneath, and for releases:

```bash
./build-app.sh              # the hermetic build itself (APP= sets the output; default dist/Eavesdropper.app)
./verify.sh                 # logic checks + isolation checks on the built app
./verify-reproducible.sh    # two clean builds must be byte-identical
./release.sh                # tag v$(cat VERSION) and publish a GitHub release (from a clean, synced main)
./live-test.py --rounds 3   # end-to-end on the installed /Applications/Eavesdropper.app
```

Diagnostic modes on the built binary (`Eavesdropper.app/Contents/MacOS/Eavesdropper`), all running inside the sandbox:

| Flag | Shows |
|---|---|
| `--version` | The stamped version, build number and commit |
| `--probe` | What call detection sees right now |
| `--calendar [meeting URL]` | Runs the helper and shows which invite would match |
| `--transcribe - [--speakers] < file.m4a` | The transcript of audio on stdin (the sandbox can't open arbitrary paths) |
| `--listen-for <seconds>` | What Start Listening does, headless: records all system audio plus the mic, then transcribes and saves |
| `--recover` | Finishes interrupted meetings (what launch does) and prints the outcome |
| `--summarize < meeting.json` | On-device notes for a saved meeting |
| `--render [meeting id] > page.png` | A PNG of a meeting's page as the window shows it (layout checks, README screenshot) |
| `--network-selftest` | Must report both targets blocked |
| `--control start\|stop` | Tells the running app to Start or Stop Listening, exactly as the menu item does (local distributed notification; web pages can't send one) |

## Resources

| Need | Where |
|---|---|
| Compiler | Xcode Command Line Tools, Swift version in `.swift-toolchain`. `build-app.sh` refuses others unless `ALLOW_TOOLCHAIN_MISMATCH=1`. SwiftPM's default build system fails under the CLT, so builds use `--build-system native` |
| Calendar feed | `GOOGLE_CALENDAR_ICS_URL` in GCP Secret Manager (project `djdk-inc`), read by the helper through the user's `gcloud` login. Never stored or committed |
| Diarization code | FluidAudio v0.18.4 (commit `e0c6103b`), Apache-2.0. To update: copy the same subset from a new upstream tag and re-apply the changes listed in `Vendor/FluidAudio/NOTICE` |
| Diarization model | `FluidInference/speaker-diarization-coreml` (Hugging Face), snapshot `1ed7a66`. Converted from `pyannote/speaker-diarization-community-1`, CC-BY-4.0. File hashes are in `Models/speaker-diarization/provenance.json` |
| Summaries | macOS's built-in on-device model (`FoundationModels`, `SystemLanguageModel.default`): nothing to bundle, no network, works in the sandbox. It reads about 4,096 tokens at once, so transcripts are condensed in ~6,000-character parts first (`transcriptChunks`). Requests run one at a time, since parallel requests measured no faster |
| Test speech | Kokoro-82M (Apache-2.0), a local neural TTS, for human-sounding test meetings; test-only, never bundled. Setup: `uv venv .venv --python 3.12 && uv pip install --python .venv/bin/python kokoro-onnx soundfile`, then `kokoro-v1.0.int8.onnx` (sha256 `6e742170…06cb`) and `voices-v1.0.bin` (sha256 `bca610b8…bf7d`) from github.com/thewh1teagle/kokoro-onnx release `model-files-v1.0` into `.models/kokoro/`. macOS `say` voices are too robotic to stand in for real meetings. Dialogues are in `test/dialogues.json` |
| Live end-to-end test | Open a Meet room tab in Chrome (Meet's pre-join screen counts as a call) and play the test conversation in another Chrome tab. The app should record, transcribe and label it. The mic also records the room |
| Live manual-recording test | `./live-test.py [--rounds N] [--seed N]` generates a fresh meeting per round (random dialogue and voices), drives the installed app through `--control`, plays it twice with a silent gap, and passes when the meeting is done, both recordings match its length, the call side is labeled and heard ≥80% of the words, and the two sides line up within 2 s. Run from Terminal or another app holding System Audio Recording, not from a process TCC attributes elsewhere |

## Shipping

A version is shippable when:

- `VERSION` is bumped (semver) and has no existing `v<VERSION>` tag.
- `./verify.sh` and `./verify-reproducible.sh` pass on the commit being released.
- A live call has been recorded end to end with the build: both sides captured, transcript and speaker labels present, and the calendar title matched (or the timestamp fallback).
- README and this file describe the shipped behaviour, including known limits.
- `./release.sh` has published the GitHub release: the zip, its SHA-256, and the tag on the released `main` commit.
