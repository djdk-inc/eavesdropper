# Eavesdropper

<img src="assets/icon.png" width="96" alt="Eavesdropper spy icon">

Menu bar app that notices when you're in a Zoom or Google Meet call, records it from your Mac, and saves a transcript titled after the calendar invite. It never joins calls; it only listens on this Mac. Audio and transcription stay on the Mac.

![The Transcripts window: meeting details, on-device summary, and speaker-labelled transcript](assets/transcripts-window.png)

## What it does

- **Detects calls**: every second it checks which apps macOS says are using the mic or speakers.
  - Zoom app: Zoom is using audio (it only does so in a meeting).
  - Meet or Zoom in a browser (Chrome, Arc, Edge, Brave, Safari): the browser is using audio and has a meeting tab open (`meet.google.com/abc-defg-hij`, `zoom.us/wc/<id>`).
  - Starts after ~4 s, ends ~3 s after audio stops.
- **Records**: your mic and the meeting app's sound (not music or notifications), written as uncompressed `mic.caf` / `call.caf`, which survive a crash or forced quit. They're compressed to `mic.m4a` / `call.m4a` after transcription.
- **Never loses a call**: quitting, updating or logging out mid-call saves the meeting, and the next launch finishes any interrupted recording or transcription.
- **Transcribes** on-device after the call (Apple SpeechTranscriber). Your mic is labeled `You`; the call's audio is split by voice into `Speaker 1`, `Speaker 2`, … (on-device speaker diarization). The diarizer code and model live in this repo (`Vendor/FluidAudio`, `Models/`), so nothing is fetched at build time or run time.
- **Titles** the meeting after its Google Calendar invite, matched by Meet code or Zoom meeting ID, falling back to an event happening now. Copies time, organizer, attendees, location, description and link. If the calendar can't be read, the title is the start time.
- **Start Listening** (menu bar spy → Start Listening, or ⌘L in the menu) records your mic and everything the Mac plays, from any app, until you click **Stop Listening**. It's then transcribed, speaker-labelled and saved like a detected call ("Manual recording – <time>"). Call detection pauses while it runs.
- **Summarize** button writes meeting notes (summary, decisions, action items with owners, open questions) with macOS's built-in on-device language model (Apple Foundation Models). It runs only when you click it, entirely on the Mac: about 7 s for a short meeting, about a minute for a long one, which is condensed in parts first. Needs Apple Intelligence turned on.
- **Copy Transcript** button puts the whole transcript on the clipboard as `[mm:ss] Speaker: text` lines.
- **Shows** everything in the Transcripts window (menu bar spy icon → Show Transcripts; a dot by its hat means a call is being recorded).

## How summaries stay on the Mac

Summaries use the language model built into macOS 26 (Apple Intelligence's on-device model, `SystemLanguageModel` in Apple's Foundation Models framework). Its weights are already on your Mac; Eavesdropper bundles nothing.

1. Clicking **Summarize** checks that the model is available, which needs Apple Intelligence turned on.
2. The transcript is split into ~6,000-character parts, because the model reads about 4,096 tokens at a time.
3. Each part is condensed into bullets, then a final request turns the bullets into notes: summary, decisions, action items with owners, open questions.
4. Empty sections are dropped, and the notes are saved with the meeting.

The model runs on the Mac's Apple Silicon in a macOS system process. Eavesdropper never uses the cloud variant (`PrivateCloudComputeLanguageModel`), and the recorder itself can't open a network connection (see below). To see it for yourself, turn Wi-Fi off and click Summarize.

## Privacy and isolation

- **The recorder can't use the network.** `Eavesdropper.app` runs in the macOS App Sandbox with no network entitlement, so audio and transcripts can't leave the Mac. `./verify.sh` checks both the entitlements and a live connection attempt.
- **Only calendar metadata uses the network.** A separate helper, `Eavesdropper Calendar.app` (inside the app bundle), fetches your Google Calendar through the private iCal address (`GOOGLE_CALENDAR_ICS_URL` in Secret Manager, read with your `gcloud` login). It hands the recorder invite metadata through a read-only file, and never receives meeting data.
- **Meetings stay in the app's container**: `~/Library/Containers/com.djdk.eavesdropper/Data/Recordings/Eavesdropper/<start> <app>/`, holding `meeting.json`, `mic.m4a` and `call.m4a`.

## Build and run

Needs macOS 26+ and the Xcode Command Line Tools (Swift version pinned in `.swift-toolchain`).

```bash
./build-app.sh        # hermetic: no network during the build; version stamped from VERSION + git
./verify.sh           # logic + isolation checks
open Eavesdropper.app
```

Each new build counts as a new app to macOS, which then asks for Microphone, System Audio Recording, and control of your browser (to read tab URLs). Allow all three. Quit the running app before rebuilding.

Releases: `./release.sh` (see [AGENTS.md](AGENTS.md)). Every release is reproducible: `./verify-reproducible.sh` rebuilds twice and checks the results are byte-identical.

## Known limits

- In a Meet or browser-Zoom call, sound from other tabs in that browser is recorded too (one audio process per browser).
- Meet's pre-join screen uses the mic, so recording starts there.
- Without headphones your mic also picks up the others, so their words can show up under `You`.
- Speaker labels are by voice, not name. Similar voices can be merged into one speaker; in a 3-voice test, a male voice was always right but two similar female voices became one speaker.
- If diarization fails, the call's lines stay labeled `Others`.
- Notes come from a small on-device model: good for gist and action items, and it can still misattribute an owner.
- Firefox isn't supported (its tabs can't be read).

## Credits

- Speaker diarization code: trimmed from [FluidAudio](https://github.com/FluidInference/FluidAudio) v0.18.4 by Fluid Inference, Apache-2.0. See `Vendor/FluidAudio/NOTICE`.
- Speaker diarization model (`Models/speaker-diarization`): Core ML conversion by Fluid Inference of [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1), licensed CC-BY-4.0.
