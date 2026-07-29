import argparse
import json

import numpy as np
import librosa
import torch
from transformers import (
    Wav2Vec2FeatureExtractor,
    Wav2Vec2ForSequenceClassification,
    logging as hf_logging,
)

# The Ruby caller parses this script's stdout as JSON, so silence any transformers
# logging that would otherwise leak onto stdout and corrupt it.
hf_logging.set_verbosity_error()


SAMPLE_RATE = 16000
FEMALE_PITCH_HZ = 165
MIN_CHUNK_SEC = 0.5  # shorter segments aren't reliably classifiable
GENDER_BATCH_SIZE = 32
MAX_PAD_RATIO = 1.5  # split a batch past this longest/shortest ratio
MAX_CLASSIFY_SEC = 8.0  # a couple of seconds of speech is enough for gender

# Fine-tuned wav2vec2 classifier; labels are {0: "female", 1: "male"}.
# Weights are baked into the Docker image at build time (see Dockerfile).
GENDER_MODEL_ID = "prithivMLmods/Common-Voice-Gender-Detection"


def load_gender_model():
    """Load the classifier onto the GPU when one is available, else CPU."""
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    extractor = Wav2Vec2FeatureExtractor.from_pretrained(GENDER_MODEL_ID)
    model = Wav2Vec2ForSequenceClassification.from_pretrained(GENDER_MODEL_ID)
    model.to(device)
    model.eval()
    return extractor, model, device


def classify_gender_batch(chunks, sr, extractor, model, device):
    """Classify segments in batches -> 'woman'/'man', or None if too short."""
    min_len = int(sr * MIN_CHUNK_SEC)
    max_len = int(sr * MAX_CLASSIFY_SEC)
    # Keep original positions so results map back after length-sorted batching.
    indexed = [
        (i, c[:max_len]) for i, c in enumerate(chunks) if len(c) >= min_len
    ]
    results = [None] * len(chunks)
    if not indexed:
        return results

    # Sort by length to keep clips of similar length batched together.
    indexed.sort(key=lambda ic: len(ic[1]))

    for batch in _padding_safe_batches(indexed):
        wavs = [c.astype(np.float32) for _, c in batch]
        # This is a group-norm wav2vec2, pretrained without an attention mask, so
        # it must get plain zero padding and NO mask.
        inputs = extractor(
            wavs, sampling_rate=sr, return_tensors="pt",
            padding=True, return_attention_mask=False,
        ).to(device)
        with torch.no_grad():
            logits = model(**inputs).logits
        label_ids = torch.argmax(logits, dim=-1).tolist()
        for (orig_i, _), label_id in zip(batch, label_ids):
            label = model.config.id2label[label_id]
            results[orig_i] = "woman" if label == "female" else "man"

    return results


def _padding_safe_batches(indexed):
    """Batch length-sorted (index, chunk) pairs within MAX_PAD_RATIO.

    Unmasked padding is real input to the model, so mixing a 0.5s clip with an 8s
    one would bury the short clip in zeros and could flip its label.
    """
    batch = []
    for item in indexed:
        if batch and (
            len(batch) >= GENDER_BATCH_SIZE
            or len(item[1]) > len(batch[0][1]) * MAX_PAD_RATIO
        ):
            yield batch
            batch = []
        batch.append(item)
    if batch:
        yield batch


def median_pitch(chunk, sr):
    if len(chunk) < int(sr * 0.5):
        return None
    f0 = librosa.yin(chunk.astype(float), fmin=50, fmax=500, sr=sr)
    voiced = f0[(f0 > 50) & (f0 < 500)]
    return float(np.median(voiced)) if len(voiced) > 0 else None


def analyze_prosody(y, sr, start, end):
    """
    Energy + pitch trend of an audio segment -> TTS style (excited/soft/expressive/neutral)
    """
    chunk = y[int(start * sr):int(end * sr)]
    if len(chunk) < int(sr * 0.1):
        return "neutral"

    rms = librosa.feature.rms(y=chunk)[0]
    rms_db = librosa.amplitude_to_db(np.array([float(np.mean(rms))]), ref=1.0)[0]

    f0, _, _ = librosa.pyin(chunk, fmin=50, fmax=500, sr=sr)
    f0_valid = f0[~np.isnan(f0)] if f0 is not None else np.array([])

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
    args = parser.parse_args()

    with open(args.segments_file) as f:
        segments = json.load(f)

    y, sr = librosa.load(args.audio_path, sr=SAMPLE_RATE)

    # Per-speaker median pitch, used only to break ties in the classifier votes
    speaker_pitches = {}
    for seg in segments:
        chunk = y[int(seg["start"] * sr):int(seg["end"] * sr)]
        pitch = median_pitch(chunk, sr)
        if pitch is not None:
            speaker_pitches.setdefault(seg["speaker"], []).append(pitch)

    pitch_gender = {
        speaker: ("woman" if float(np.mean(pitches)) > FEMALE_PITCH_HZ else "man")
        for speaker, pitches in speaker_pitches.items()
    }

    # wav2vec2 gender classification, one vote per segment weighted by duration.
    extractor, model, device = load_gender_model()
    chunks = [y[int(seg["start"] * sr):int(seg["end"] * sr)] for seg in segments]
    genders = classify_gender_batch(chunks, sr, extractor, model, device)

    speaker_gender_votes = {}
    for seg, gender in zip(segments, genders):
        if gender is None:
            continue
        duration = seg["end"] - seg["start"]
        speaker_gender_votes.setdefault(seg["speaker"], {})
        speaker_gender_votes[seg["speaker"]][gender] = (
            speaker_gender_votes[seg["speaker"]].get(gender, 0) + duration
        )

    speaker_gender = {}
    for speaker in {s["speaker"] for s in segments}:
        votes = speaker_gender_votes.get(speaker, {})
        if not votes:
            # No classifiable audio -> fall back to pitch, else default to "man".
            speaker_gender[speaker] = pitch_gender.get(speaker, "man")
        elif votes.get("woman", 0) == votes.get("man", 0):
            # Classifier is split -> let pitch decide the tie.
            speaker_gender[speaker] = pitch_gender.get(speaker, "man")
        else:
            speaker_gender[speaker] = max(votes, key=votes.get)

    for seg in segments:
        seg["gender"] = speaker_gender[seg["speaker"]]
        seg["prosody"] = analyze_prosody(y, sr, seg["start"], seg["end"])

    print(json.dumps(segments))


if __name__ == "__main__":
    main()
