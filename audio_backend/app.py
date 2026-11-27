from fastapi import FastAPI, UploadFile, File, HTTPException
import io
import numpy as np
import librosa

app = FastAPI(title="PianoFlow Audio-to-Notes API")

@app.get("/health")
def health():
    return {"status": "ok", "service": "pianoflow-audio"}

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Experimental polyphonic pitch proposal from audio.
    This is a first-pass pitch tracker, not production-grade piano transcription.
    """
    name = (file.filename or "").lower()
    if not name.endswith((".wav", ".mp3", ".m4a", ".flac", ".ogg")):
        raise HTTPException(415, "Upload WAV, MP3, M4A, FLAC or OGG")
    raw = await file.read()
    if len(raw) > 40 * 1024 * 1024:
        raise HTTPException(413, "File too large (40 MB limit)")
    try:
        y, sr = librosa.load(io.BytesIO(raw), sr=22050, mono=True)
    except Exception as exc:
        raise HTTPException(422, f"Could not decode audio: {exc}")
    if y.size == 0:
        raise HTTPException(422, "Audio is empty")

    # pYIN is monophonic; piptrack gives several spectral peaks per frame.
    # Return candidate pitches for review rather than claiming exact transcription.
    S = np.abs(librosa.stft(y, n_fft=4096, hop_length=512))
    pitches, magnitudes = librosa.piptrack(
        S=S, sr=sr, n_fft=4096, fmin=librosa.note_to_hz("C2"),
        fmax=librosa.note_to_hz("C7"), threshold=0.18
    )
    frames = []
    for frame_idx in range(pitches.shape[1]):
        mags = magnitudes[:, frame_idx]
        if mags.max(initial=0) <= 1e-6:
            continue
        peaks = np.argsort(mags)[-5:][::-1]
        candidates = []
        seen = set()
        for bin_idx in peaks:
            hz = float(pitches[bin_idx, frame_idx])
            if hz <= 0:
                continue
            midi = int(round(librosa.hz_to_midi(hz)))
            if midi not in seen:
                seen.add(midi)
                candidates.append({"midi": midi, "confidence": float(mags[bin_idx] / (mags.max() + 1e-9))})
        if candidates:
            frames.append({"time": float(librosa.frames_to_time(frame_idx, sr=sr, hop_length=512)),
                           "candidates": candidates})
    return {
        "filename": file.filename,
        "duration_seconds": float(len(y) / sr),
        "sample_rate": sr,
        "method": "spectral-pitch-candidates",
        "warning": "Experimental: harmonics may be mistaken for notes. Review/edit before practice.",
        "frames": frames
    }
