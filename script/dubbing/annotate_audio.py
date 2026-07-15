import argparse
import contextlib
import json
import os

import numpy as np
import librosa
from inaSpeechSegmenter import Segmenter


@contextlib.contextmanager
def redirect_stdout_to_stderr():
    """
    inaSpeechSegmenter prints init messages to stdout; Ruby parses the stdout as JSON
    so route those to stderr instead
    """
    original_stdout_fd = os.dup(1)
    try:
        os.dup2(2, 1)
        yield
    finally:
        os.dup2(original_stdout_fd, 1)
        os.close(original_stdout_fd)


SAMPLE_RATE = 16000
FEMALE_PITCH_HZ = 165


def voiced_pitch(chunk, sr):
    """One pyin pass per segment; the result feeds both gender (median) and
    prosody (variance) so pitch isn't tracked twice."""
    if len(chunk) < int(sr * 0.1):
        return np.array([])
    f0, _, _ = librosa.pyin(chunk, fmin=50, fmax=500, sr=sr)
    return f0[~np.isnan(f0)] if f0 is not None else np.array([])


def analyze_prosody(chunk, f0_valid):
    """
    Energy + pitch trend of an audio segment -> TTS style (excited/soft/expressive/neutral)
    """
    if len(chunk) < int(SAMPLE_RATE * 0.1):
        return "neutral"

    rms = librosa.feature.rms(y=chunk)[0]
    rms_db = librosa.amplitude_to_db(np.array([float(np.mean(rms))]), ref=1.0)[0]

    if rms_db > -15:
        energy = "high"
    elif rms_db < -30:
        energy = "low"
    else:
        energy = "normal"

    pitch_varied = len(f0_valid) > 2 and float(np.std(f0_valid)) > 30

    if energy == "high" and pitch_varied:
        return "excited"
    if energy == "low":
        return "soft"
    if pitch_varied:
        return "expressive"
    return "neutral"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_path")
    parser.add_argument("--segments-file", required=True)
    parser.add_argument("--output-dir")
    args = parser.parse_args()

    with open(args.segments_file) as f:
        segments = json.load(f)

    y, sr = librosa.load(args.audio_path, sr=SAMPLE_RATE)

    # chunks are views into y; f0 is reused below for both gender and prosody
    seg_audio = []
    for seg in segments:
        chunk = y[int(seg["start"] * sr):int(seg["end"] * sr)]
        seg_audio.append((chunk, voiced_pitch(chunk, sr)))

    speaker_pitches = {}
    for seg, (chunk, f0_valid) in zip(segments, seg_audio):
        # gender medians only from segments long enough to be reliable
        if len(chunk) >= int(sr * 0.5) and len(f0_valid) > 0:
            speaker_pitches.setdefault(seg["speaker"], []).append(float(np.median(f0_valid)))

    pitch_gender = {
        speaker: ("woman" if float(np.mean(pitches)) > FEMALE_PITCH_HZ else "man")
        for speaker, pitches in speaker_pitches.items()
    }

    with redirect_stdout_to_stderr():
        gender_regions = Segmenter()(args.audio_path)

    speaker_gender_votes = {}
    for seg in segments:
        seg_votes = {}
        for label, start, end in gender_regions:
            if label not in ("male", "female"):
                continue
            overlap = min(seg["end"], end) - max(seg["start"], start)
            if overlap > 0:
                gender = "woman" if label == "female" else "man"
                seg_votes[gender] = seg_votes.get(gender, 0) + overlap
        if not seg_votes:
            continue
        detected = max(seg_votes, key=seg_votes.get)
        duration = seg["end"] - seg["start"]
        speaker_gender_votes.setdefault(seg["speaker"], {})
        speaker_gender_votes[seg["speaker"]][detected] = speaker_gender_votes[seg["speaker"]].get(detected, 0) + duration

    speaker_gender = {}
    for speaker in {s["speaker"] for s in segments}:
        if pitch_gender.get(speaker) == "woman":
            speaker_gender[speaker] = "woman"
        else:
            votes = speaker_gender_votes.get(speaker, {})
            speaker_gender[speaker] = max(votes, key=votes.get) if votes else "man"

    for seg, (chunk, f0_valid) in zip(segments, seg_audio):
        seg["gender"] = speaker_gender[seg["speaker"]]
        seg["prosody"] = analyze_prosody(chunk, f0_valid)

    print(json.dumps(segments))


if __name__ == "__main__":
    main()
