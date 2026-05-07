import argparse
import json
import sys
import numpy as np
import librosa
from resemblyzer import VoiceEncoder, preprocess_wav
from sklearn.cluster import AgglomerativeClustering 
from inaSpeechSegmenter import Segmenter

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_path")
    parser.add_argument("--segments")
    parser.add_argument("--output-dir")

    args = parser.parse_args()

    segments = json.loads(args.segments)
    audio_path = args.audio_path

    y, sr = librosa.load(audio_path, sr=16000)

    # Load resemblyzer neural network to convert audio into voice vectors
    encoder = VoiceEncoder() 

    embeddings = []
    for seg in segments:
        start_sample = int(seg["start"] * sr)
        end_sample = int(seg["end"] * sr)
        chunk = y[start_sample:end_sample]

        if len(chunk) < int(sr * 0.5):
            embeddings.append(np.zeros(256))
            continue
        
        wav_chunk = preprocess_wav(chunk, source_sr=sr)
        embed = encoder.embed_utterance(wav_chunk)
        embeddings.append(embed)

    valid_indices = [i for i, e in enumerate(embeddings) if np.any(e != 0)]
    valid_embeddings = [embeddings[i] for i in valid_indices]

    labels = np.zeros(len(segments), dtype=int)

    if len(valid_embeddings) >= 2:
        clustering = AgglomerativeClustering(
            n_clusters=None,
            distance_threshold=0.25,
            metric="cosine",
            linkage="average"
        )
        valid_labels = clustering.fit_predict(np.array(valid_embeddings))
        for idx, vi in enumerate(valid_indices):
            labels[vi] = valid_labels[idx]

    for i, seg in enumerate(segments):
        seg["speaker"] = f"SPEAKER_{labels[i]}"

    gender_segmenter = Segmenter()
    gender_regions = gender_segmenter(audio_path)

    speaker_gender_votes = {}
    for seg in segments:
        speaker = seg["speaker"]
        speaker_gender_votes.setdefault(speaker, {"man": 0.0, "woman": 0.0})

        for label, start, end in gender_regions:
            if label not in ("male", "female"):
                continue
            overlap = min(seg["end"], end) - max(seg["start"], start)
            if overlap > 0:
                gender = "woman" if label == "female" else "man"
                speaker_gender_votes[speaker][gender] += overlap

    speaker_gender = {
        speaker: max(votes, key=votes.get)
        for speaker, votes in speaker_gender_votes.items()
    }

    for seg in segments:
        seg["gender"] = speaker_gender.get(seg["speaker"], "man")

    print(json.dumps(segments))


if __name__ == "__main__":
    main()
