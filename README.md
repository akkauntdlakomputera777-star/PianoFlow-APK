# PianoFlow Audio-to-Notes API (experimental)

Run:
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\\Scripts\\activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000
```

POST an audio file to `/transcribe` as multipart field `file`.
This returns frame-wise pitch candidates from spectral peaks. It is an experimental aid,
not accurate finished polyphonic piano transcription: harmonics, chords, sustain and
other instruments can create false candidates. Production needs a trained multi-pitch
model, note onset/offset detection, source separation where needed, and a score editor.
