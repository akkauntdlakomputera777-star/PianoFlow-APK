# PianoFlow — starter prototype

PianoFlow is a Flutter starter app for Android and iOS with:
- dark UI;
- falling-note visualizer for an included short practice phrase;
- on-screen piano keyboard;
- microphone capture and a basic monophonic pitch estimator;
- USB MIDI and Bluetooth-MIDI device discovery/connection for Android and iOS;
- MIDI Note On input routed into the Smart Follow matcher.
- a simple Smart Follow demonstration.

## Requirements
- Flutter stable (Dart 3.3+)
- Android Studio / Xcode for device builds

## Run
```bash
flutter pub get
flutter run
```

## MIDI support

The app uses `flutter_midi_command` and its optional BLE transport for USB and compatible Bluetooth-MIDI keyboards on Android/iOS. Connect a USB-MIDI keyboard using a phone-compatible adapter (and powered hub if needed), or pair a BLE-MIDI keyboard through the in-app MIDI picker. Not every keyboard supports Bluetooth MIDI; ordinary Bluetooth audio is not MIDI.

The current MIDI implementation handles incoming Note On messages for note matching. Note Off/hold-duration matching, sustain pedal handling, multi-note score tracking and robust reconnect UX are future work. The plugin's current 1.4.x release requires Flutter 3.44+ / Dart 3.12+.

## Microphone permissions

### Android
Add this inside `android/app/src/main/AndroidManifest.xml`, above `<application>`:
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

### iOS
Add these keys inside the top-level `<dict>` in `ios/Runner/Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>PianoFlow uses the microphone to listen to your piano playing.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>PianoFlow uses Bluetooth to connect to compatible MIDI keyboards.</string>
```

## Current limitations
This is an early runnable prototype, not a finished music transcription product. MIDI discovery and incoming note events are wired in, but device testing on physical Android/iOS hardware is still required.
The microphone detector estimates one dominant pitch at a time. A real piano chord contains
multiple simultaneous notes, and room acoustics, sustain, harmonics and background noise can
cause incorrect estimates. The included Smart Follow currently demonstrates note-by-note
matching against a short built-in phrase. It is not yet a full polyphonic score follower.

## Next development milestones
1. Add MIDI file import and playback (reliable note/timing source).
2. Add MusicXML sheet music rendering.
3. Add polyphonic audio-to-MIDI transcription for uploaded WAV/MP3.
4. Improve live score following with onset detection, tempo tolerance and note-duration tracking.
5. Add a curated public-domain classical library and cloud/user library.
6. Add tests, onboarding, persistence and store-ready packaging.

## Copyright note
Use public-domain scores/recordings or content the user has permission to upload.


## New in v0.3: MIDI import and audio analysis starter
- MIDI file picker for `.mid` / `.midi`.
- Standard MIDI File parser for formats 0 and 1, PPQN timing, tempo events, note-on/off, note duration and velocity.
- Imported MIDI notes feed the falling-note renderer and Smart Follow demo.
- MP3/WAV/M4A/FLAC file selection UI.
- Experimental FastAPI + librosa audio pitch-candidate service in `audio_backend/`.

The audio service is a research starter, not finished transcription. It emits spectral pitch candidates
and can confuse harmonics with notes. Full automatic transcription of arbitrary polyphonic songs
needs a dedicated trained model and correction workflow. Audio file selection in the Flutter UI is
not yet wired to this server endpoint.


## New in v0.4: Falling Notes player improvements
- Piano-roll layout spans a wider MIDI range (C3–C6).
- Separate visual colors for lower-register/left-hand notes and upper-register/right-hand notes.
- Play/pause/resume and return-to-start controls.
- Playback speed control from 0.5× to 1.5×.
- Frame-driven playback clock is now started automatically.

This still needs a Flutter build and hardware/device QA. The visual split uses pitch register as a heuristic;
true left/right hand assignment requires track/voice metadata or a user-editable hand assignment.
