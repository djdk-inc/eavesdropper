# Eavesdropper

<img src="assets/icon.png" width="96" alt="Eavesdropper spy icon">

Menu bar app that notices when you're in a Zoom or Google Meet call, records it from your Mac, and saves a transcript titled after the calendar invite. It never joins calls; it only listens on this Mac. Audio and transcription stay on the Mac.

## What it does

- **Detects calls**: every second it checks which apps macOS says are using the mic or speakers.
  - Zoom app: Zoom is using audio (it only does so in a meeting).
  - Meet or Zoom in a browser (Chrome, Arc, Edge, Brave, Safari): the browser is using audio and has a meeting tab open (`meet.google.com/abc-defg-hij`, `zoom.us/wc/<id>`).
  - Starts after ~4 s, ends ~3 s after audio stops.
- **Records**: `mic.m4a` (your mic) and `call.m4a` (only the meeting app's sound, not music or notifications).
- **Transcribes** on-device after the call (Apple SpeechTranscriber), lines labeled `You` / `Others`.
- **Titles** the meeting after its Google Calendar invite, matched by Meet code or Zoom meeting ID, falling back to an event happening now. Copies time, organizer, attendees, location, description and link. If the calendar can't be read, the title is the start time.
- **Copy Transcript** button puts the whole transcript on the clipboard as `[mm:ss] Speaker: text` lines.
- **Shows** everything in the Transcripts window (menu bar spy icon → Show Transcripts; a dot by its hat means a call is being recorded).

Meetings are saved in `~/Recordings/Eavesdropper/<start> <app>/` as `meeting.json` plus the two audio files.

Calendar: the app reads `GOOGLE_CALENDAR_ICS_URL` (Google's private iCal address) from Secret Manager in `djdk-inc` using your `gcloud` login. Nothing is stored on disk.

## Build and run

Needs macOS 26+ and the Xcode Command Line Tools.

```bash
./build-app.sh
open Eavesdropper.app
```

The first call triggers three macOS prompts: Microphone, System Audio Recording, and control of your browser (to read tab URLs). Allow all three.

## Checks

```bash
swift run --build-system native --scratch-path .build2 DetectorChecks   # detection, calendar parsing/matching, titles, storage
Eavesdropper.app/Contents/MacOS/Eavesdropper --probe                     # what the detector sees right now
Eavesdropper.app/Contents/MacOS/Eavesdropper --calendar <meeting URL>    # which invite a call at that URL would get
Eavesdropper.app/Contents/MacOS/Eavesdropper --transcribe <audio file>   # on-device transcript of a file
Eavesdropper.app/Contents/MacOS/Eavesdropper --record <pid> <sec> <dir>  # record one process + mic
```

## Known limits

- In a Meet or browser-Zoom call, sound from other tabs in that browser is recorded too (one audio process per browser).
- Meet's pre-join screen uses the mic, so recording starts there.
- Without headphones your mic also picks up the others, so their words can show up under `You`.
- Firefox isn't supported (its tabs can't be read).
