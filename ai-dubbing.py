"""
AI Video Dubbing Pipeline

1. Extract audio from video
2. Separate vocals from background using Demucs
3. Transcribe vocals with Whisper API
4. Diarize speakers + detect gender
5. Identify chapters with GPT
6. Translate to target language with GPT
7. Generate dubbed audio (TTS + background)
8. Create dubbed video (original video + dubbed audio)
9. Create HLS streaming package
"""

import io
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import librosa
import numpy as np
from dotenv import load_dotenv
from elevenlabs import ElevenLabs, VoiceSettings
from inaSpeechSegmenter import Segmenter
from openai import OpenAI
from pydub import AudioSegment
from pydub.silence import detect_leading_silence
from resemblyzer import VoiceEncoder, preprocess_wav
from sklearn.cluster import AgglomerativeClustering

load_dotenv()


# =============================================================================
# Constants
# =============================================================================

WHISPER_MODEL = "whisper-1"
GPT_MODEL = "gpt-5-mini"

VOICES = {
    "peninsular": {
        "man": [
            "851ejYcv2BoNPjrkw93G",
            "eEyWolF7iBpMA65GbtAm",
            "SKjgN71N3MeGl4r2JbRt",
        ],
        "woman": [
            "AxFLn9byyiDbMn5fmyqu",
            "Oe0GElYvnDDV5qP1vbE2",
            "gD1IexrzCvsXPHUuT0s3",
        ],
    },
    "latin-american": {
        "man": [
            "YExhVa4bZONzeingloMX",
            "t3eeeqhBjrUqcrPvDqUn",
            "4XUsiqPDK4UACIM2BILe",
        ],
        "woman": [
            "cIBxLwfshLYhRB9lCXEg",
            "nTkjq09AuYgsNR8E4sDe",
            "nbcvT3C2tyOd2OsRAtUf",
        ],
    },
}

SAMPLE_RATE = 16000
SPEAKER_DISTANCE_THRESHOLD = 0.25
MAX_SPEED = 1.35
MIN_SPEED = 0.85
MAX_RETRANSLATE_ATTEMPTS = 2
CROSSFADE_MS = 30
DUCK_DB = -8

NOISE_INDICATORS = [
    "[music]", "[applause]", "[laughter]", "(music)",
    "♪", "🎵", "[silence]", "[noise]", "[inaudible]",
]

HALLUCINATION_PATTERNS = [
    r"(.{10,}?)\1{2,}",
    r"^(thank you|thanks)[\s.!]*$",
    r"^(subscribe|like and subscribe).*$",
    r"^(please subscribe).*$",
    r"^\W+$",
]
MIN_AVG_LOGPROB = -1.0
MAX_COMPRESSION_RATIO = 2.4
MAX_NO_SPEECH_PROB = 0.6


# =============================================================================
# Clients
# =============================================================================

openai_client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
elevenlabs_client = ElevenLabs(api_key=os.environ["ELEVENLABS_API_KEY"])


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str = "SPEAKER_0"
    gender: str = "unknown"
    translated_text: str = ""


@dataclass
class Chapter:
    start: float
    title: str
    title_es: str = ""


# =============================================================================
# Helpers
# =============================================================================

def sanitize_for_tts(text: str) -> str:
    """Replace dashes and special punctuation with TTS-friendly alternatives."""
    text = re.sub(r'\s*[—–]\s*', ', ', text)
    text = re.sub(r'[\u2011]', ' ', text)
    text = re.sub(r',\s*,', ',', text)
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()


def run_ffmpeg(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run an ffmpeg command with auto-overwrite enabled."""
    return subprocess.run(
        ["ffmpeg"] + args + ["-y"],
        check=check,
        capture_output=True
    )


def run_ffprobe(args: list[str]) -> str:
    """Run ffprobe and return stdout."""
    result = subprocess.run(
        ["ffprobe", "-v", "error"] + args,
        capture_output=True,
        text=True,
        check=True
    )
    return result.stdout.strip()


def build_atempo_chain(speed: float) -> list[str]:
    """Build chained atempo filters for ffmpeg (each must be in [0.5, 2.0])."""
    filters = []
    remaining = speed

    while remaining > 2.0:
        filters.append("atempo=2.0")
        remaining /= 2.0
    while remaining < 0.5:
        filters.append("atempo=0.5")
        remaining /= 0.5

    filters.append(f"atempo={remaining:.4f}")
    return filters


def adjust_speed(audio: AudioSegment, speed: float, output_dir: str) -> AudioSegment:
    """Adjust audio playback speed using ffmpeg atempo filter."""
    if abs(speed - 1.0) < 0.01:
        return audio

    temp_in = os.path.join(output_dir, "_speed_in.mp3")
    temp_out = os.path.join(output_dir, "_speed_out.mp3")

    audio.export(temp_in, format="mp3")
    filter_str = ",".join(build_atempo_chain(speed))
    run_ffmpeg(["-i", temp_in, "-filter:a", filter_str, temp_out])

    result = AudioSegment.from_mp3(temp_out)
    os.remove(temp_in)
    os.remove(temp_out)

    return result


def fmt_vtt_ts(seconds: float) -> str:
    """Convert seconds to WebVTT timestamp (HH:MM:SS.mmm)."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"


def fmt_srt_ts(seconds: float) -> str:
    """Convert seconds to SRT timestamp (HH:MM:SS,mmm)."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def save_vtt(segments: list[Segment], path: str, use_translated: bool = False):
    """Save segments as a WebVTT subtitle file."""
    with open(path, "w", encoding="utf-8") as f:
        f.write("WEBVTT\n\n")
        for i, seg in enumerate(segments, 1):
            text = seg.translated_text if use_translated else seg.text
            f.write(f"{i}\n")
            f.write(f"{fmt_vtt_ts(seg.start)} --> {fmt_vtt_ts(seg.end)}\n")
            f.write(f"<v {seg.speaker}>{text}\n\n")


def save_srt(segments: list[Segment], path: str, use_translated: bool = False):
    """Save segments as an SRT subtitle file."""
    with open(path, "w", encoding="utf-8") as f:
        for i, seg in enumerate(segments, 1):
            text = seg.translated_text if use_translated else seg.text
            f.write(f"{i}\n")
            f.write(f"{fmt_srt_ts(seg.start)} --> {fmt_srt_ts(seg.end)}\n")
            f.write(f"{text}\n\n")


def parse_gpt_json(raw: str) -> any:
    """Parse JSON from GPT responses, stripping markdown fences."""
    raw = re.sub(r"^```(?:json)?\s*", "", raw.strip())
    raw = re.sub(r"\s*```$", "", raw)
    return json.loads(raw)


def detect_silent_regions(audio_path: str, threshold_db: float = -40.0) -> list[tuple[float, float]]:
    """Find regions where vocal track is silent (music-only intro/outro)."""
    y, sr = librosa.load(audio_path, sr=SAMPLE_RATE)

    frame_length = int(0.5 * sr)
    hop_length = frame_length // 2

    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    rms_db = librosa.amplitude_to_db(rms, ref=np.max)

    silent_frames = rms_db < threshold_db

    regions = []
    in_silent = False
    start_time = 0.0

    for i, is_silent in enumerate(silent_frames):
        time = i * hop_length / sr

        if is_silent and not in_silent:
            start_time = time
            in_silent = True
        elif not is_silent and in_silent:
            if time - start_time > 0.5:
                regions.append((start_time, time))
            in_silent = False

    if in_silent:
        end_time = len(y) / sr
        if end_time - start_time > 0.5:
            regions.append((start_time, end_time))

    return regions


def crossfade_splice(audio_a: AudioSegment, audio_b: AudioSegment,
                     crossfade_ms: int = CROSSFADE_MS) -> AudioSegment:
    """Join two audio segments with a crossfade."""
    crossfade_ms = min(crossfade_ms, len(audio_a), len(audio_b))
    if crossfade_ms <= 0:
        return audio_a + audio_b
    return audio_a.append(audio_b, crossfade=crossfade_ms)


def is_hallucination(seg_data, text: str) -> tuple[bool, str]:
    """Check if a Whisper segment is likely a hallucination using patterns and confidence metrics."""
    for pattern in HALLUCINATION_PATTERNS:
        if re.search(pattern, text, re.IGNORECASE):
            return True, f"matches pattern: {pattern}"

    avg_logprob = getattr(seg_data, "avg_logprob", None)
    if avg_logprob is None and isinstance(seg_data, dict):
        avg_logprob = seg_data.get("avg_logprob")

    compression_ratio = getattr(seg_data, "compression_ratio", None)
    if compression_ratio is None and isinstance(seg_data, dict):
        compression_ratio = seg_data.get("compression_ratio")

    no_speech_prob = getattr(seg_data, "no_speech_prob", None)
    if no_speech_prob is None and isinstance(seg_data, dict):
        no_speech_prob = seg_data.get("no_speech_prob")

    if avg_logprob is not None and avg_logprob < MIN_AVG_LOGPROB:
        return True, f"low confidence (avg_logprob={avg_logprob:.2f})"

    if compression_ratio is not None and compression_ratio > MAX_COMPRESSION_RATIO:
        return True, f"high compression (ratio={compression_ratio:.2f})"

    if no_speech_prob is not None and no_speech_prob > MAX_NO_SPEECH_PROB:
        return True, f"high no-speech prob ({no_speech_prob:.2f})"

    return False, ""


def analyze_prosody(y: np.ndarray, sr: int, start: float, end: float) -> dict:
    """Analyze energy and pitch of an audio segment to determine TTS style (excited/soft/expressive/neutral)."""
    start_sample = int(start * sr)
    end_sample = int(end * sr)
    chunk = y[start_sample:end_sample]

    if len(chunk) < int(sr * 0.1):
        return {"energy": "normal", "pitch_trend": "stable", "style": "neutral"}

    rms = librosa.feature.rms(y=chunk)[0]
    mean_rms = float(np.mean(rms))
    rms_db = librosa.amplitude_to_db(np.array([mean_rms]), ref=1.0)[0]

    f0, _, _ = librosa.pyin(chunk, fmin=50, fmax=500, sr=sr)
    f0_valid = f0[~np.isnan(f0)] if f0 is not None else np.array([])

    if rms_db > -15:
        energy = "high"
    elif rms_db < -30:
        energy = "low"
    else:
        energy = "normal"

    if len(f0_valid) > 2:
        pitch_std = float(np.std(f0_valid))
        pitch_trend = "varied" if pitch_std > 30 else "stable"
    else:
        pitch_trend = "stable"

    if energy == "high" and pitch_trend == "varied":
        style = "excited"
    elif energy == "low":
        style = "soft"
    elif pitch_trend == "varied":
        style = "expressive"
    else:
        style = "neutral"

    return {"energy": energy, "pitch_trend": pitch_trend, "style": style}


def retranslate_shorter(text: str, original_text: str, duration: float,
                        target_lang: str = "English") -> str:
    """Re-request a shorter translation that fits within the available duration."""
    max_syllables = int(duration * 4)
    response = openai_client.chat.completions.create(
        model=GPT_MODEL,
        messages=[
            {
                "role": "system",
                "content": (
                    f"You are a dubbing translator. The previous {target_lang} translation "
                    f"is too long for the available time ({duration:.1f}s). "
                    f"Produce a SHORTER translation (max ~{max_syllables} syllables) "
                    f"that preserves the core meaning. Return ONLY the translated text."
                )
            },
            {"role": "user", "content": f"Original: {original_text}\nToo-long translation: {text}"}
        ]
    )
    return response.choices[0].message.content.strip()


# =============================================================================
# Step 1: Extract Audio
# =============================================================================

def extract_audio(video_path: str, output_dir: str) -> str:
    """Extract audio from video as PCM WAV (44.1kHz stereo)."""
    print("[1/8] Extracting audio from video")

    audio_path = os.path.join(output_dir, "audio.wav")
    run_ffmpeg([
        "-i", video_path,
        "-vn",
        "-acodec", "pcm_s16le",
        "-ar", "44100",
        "-ac", "2",
        audio_path
    ])

    return audio_path


# =============================================================================
# Step 2: Separate Vocals
# =============================================================================

def separate_audio(audio_path: str, output_dir: str) -> tuple[str, str]:
    """Use Demucs to separate vocals from background music/sounds."""
    print("[2/8] Separating vocals from background (Demucs)")

    subprocess.run(
        ["python", "-m", "demucs", "--two-stems", "vocals", "-o", output_dir, audio_path],
        check=True
    )

    audio_name = Path(audio_path).stem
    demucs_dir = os.path.join(output_dir, "htdemucs", audio_name)

    vocals_path = os.path.join(demucs_dir, "vocals.wav")
    background_path = os.path.join(demucs_dir, "no_vocals.wav")

    print(f"Vocals: {vocals_path}")
    print(f"Background: {background_path}")

    return vocals_path, background_path


# =============================================================================
# Step 3: Transcribe
# =============================================================================

def transcribe_audio(audio_path: str, output_dir: str) -> list[Segment]:
    """Transcribe audio with Whisper API, filter hallucinations, and merge into sentences via GPT."""
    print("[3/8] Transcribing with Whisper")

    mp3_path = os.path.join(output_dir, "vocals_compressed.mp3")
    run_ffmpeg(["-i", audio_path, "-ar", "16000", "-ac", "1", "-b:a", "64k", mp3_path])

    print(f"Compressed: {os.path.getsize(mp3_path) / 1024 / 1024:.1f}MB")

    with open(mp3_path, "rb") as f:
        response = openai_client.audio.transcriptions.create(
            model=WHISPER_MODEL,
            file=f,
            response_format="verbose_json",
            timestamp_granularities=["segment"]
        )

    segments = []
    for seg in response.segments:
        start = seg["start"] if isinstance(seg, dict) else seg.start
        end = seg["end"] if isinstance(seg, dict) else seg.end
        text = (seg["text"] if isinstance(seg, dict) else seg.text).strip()

        is_noise = any(ind in text.lower() for ind in NOISE_INDICATORS)
        if is_noise:
            print(f"      Skipping noise: '{text[:40]}'")
            continue

        hallucinated, reason = is_hallucination(seg, text)
        if hallucinated:
            print(f"      Skipping hallucination ({reason}): '{text[:40]}'")
            continue

        word_count = len(text.split())
        duration = end - start
        words_per_sec = word_count / max(duration, 0.01)

        if (word_count == 1 and duration > 5) or words_per_sec > 12:
            print(f"      Skipping suspicious timing: '{text[:40]}' ({duration:.1f}s, {word_count}w)")
            continue

        segments.append(Segment(start=start, end=end, text=text))

    print(f"      Found {len(segments)} raw segments")

    segments = merge_and_split_into_sentences(segments)
    print(f"      After sentence splitting: {len(segments)} segments")

    return segments


def merge_and_split_into_sentences(segments: list[Segment]) -> list[Segment]:
    """Use GPT to merge Whisper fragments into complete, natural sentences."""
    if not segments:
        return segments

    marked_text = ""
    for i, seg in enumerate(segments):
        marked_text += f"[{i}:{seg.start:.2f}] {seg.text} "

    response = openai_client.chat.completions.create(
        model=GPT_MODEL,
        messages=[
            {
                "role": "system",
                "content": (
                    "You are a transcript editor preparing text for dubbing translation.\n\n"
                    "The input is auto-transcribed speech chopped into fragments by a speech recognizer. "
                    "Many fragments are MID-SENTENCE and must be merged before translation.\n\n"
                    "Your job: reconstruct the COMPLETE, NATURAL SENTENCES the speaker actually said.\n\n"
                    "Rules:\n"
                    "- AGGRESSIVELY merge fragments. If a fragment doesn't end with . ? or ! it is NOT a complete sentence — merge it with the next fragment(s)\n"
                    "- Example: '[0:1.00] Welcome.' + '[1:2.20] In this course,' + '[2:5.76] we're going to dive into the power of' + '[3:8.66] decision intelligence.' → TWO sentences: 'Welcome.' and 'In this course, we're going to dive into the power of decision intelligence.'\n"
                    "- Every output MUST be a grammatically complete sentence that can stand alone\n"
                    "- NEVER output a fragment like 'how it blends different forms of AI with' — that's incomplete\n"
                    "- Use the timestamp marker [X:Y.YY] from the FIRST fragment of each merged sentence\n"
                    "- Don't split at abbreviations like 'Dr.', 'Mr.', 'U.S.', 'e.g.'\n"
                    "- Add proper end punctuation (. ? !) to every sentence\n"
                    "- NEVER use em-dashes or en-dashes. Use commas or periods instead. The text will be spoken aloud by TTS.\n"
                    "- For hyphenated technical terms (zero-shot, chain-of-thought), remove the hyphens (zero shot, chain of thought)\n"
                    "- Return JSON array: [{\"start_marker\": \"[0:1.23]\", \"text\": \"Complete sentence.\"}]\n"
                    "- Return ONLY valid JSON"
                )
            },
            {"role": "user", "content": marked_text}
        ]
    )

    data = parse_gpt_json(response.choices[0].message.content)

    new_segments = []
    marker_pattern = re.compile(r'\[(\d+):(\d+\.?\d*)\]')

    for i, item in enumerate(data):
        text = item["text"].strip()
        if not text:
            continue

        marker = item.get("start_marker", "")
        match = marker_pattern.search(marker)

        if match:
            start = float(match.group(2))
        elif new_segments:
            start = new_segments[-1].end
        else:
            start = segments[0].start

        if i + 1 < len(data):
            next_marker = data[i + 1].get("start_marker", "")
            next_match = marker_pattern.search(next_marker)
            if next_match:
                end = float(next_match.group(2))
            else:
                end = start + len(text) * 0.08
        else:
            end = segments[-1].end

        new_segments.append(Segment(start=start, end=max(end, start + 0.5), text=text))

    return new_segments if new_segments else segments


# =============================================================================
# Step 4: Diarize + Gender Detection
# =============================================================================

def detect_gender(audio_path: str) -> list[tuple[str, float, float]]:
    """Run inaSpeechSegmenter on an audio file to get gender-labeled time regions."""
    seg = Segmenter()
    return seg(audio_path)


def diarize_speakers(audio_path: str, segments: list[Segment],
                     num_speakers: int | None = None) -> list[Segment]:
    """Cluster segments by speaker using voice embeddings, then detect gender with inaSpeechSegmenter."""
    print("[4/8] Diarizing speakers")

    y, sr = librosa.load(audio_path, sr=SAMPLE_RATE)
    encoder = VoiceEncoder()

    embeddings = []
    for seg in segments:
        start_sample = int(seg.start * sr)
        end_sample = int(seg.end * sr)
        chunk = y[start_sample:end_sample]

        if len(chunk) < int(sr * 0.5):
            embeddings.append(np.zeros(256))
            continue

        wav_chunk = preprocess_wav(chunk, source_sr=sr)
        if len(wav_chunk) > 0:
            embed = encoder.embed_utterance(wav_chunk)
        else:
            embed = np.zeros(256)
        embeddings.append(embed)

    valid_indices = [i for i, e in enumerate(embeddings) if np.any(e != 0)]
    valid_embeddings = [embeddings[i] for i in valid_indices]

    labels = np.zeros(len(segments), dtype=int)

    if len(valid_embeddings) >= 2:
        embedding_arr = np.array(valid_embeddings)

        if num_speakers:
            clustering = AgglomerativeClustering(
                n_clusters=num_speakers, metric="cosine", linkage="average"
            )
        else:
            clustering = AgglomerativeClustering(
                n_clusters=None,
                distance_threshold=SPEAKER_DISTANCE_THRESHOLD,
                metric="cosine",
                linkage="average"
            )

        valid_labels = clustering.fit_predict(embedding_arr)
        for idx, vi in enumerate(valid_indices):
            labels[vi] = valid_labels[idx]

        for i in range(len(segments)):
            if i not in valid_indices:
                best = min(valid_indices, key=lambda vi: abs(segments[vi].start - segments[i].start))
                labels[i] = labels[best]
    elif len(valid_embeddings) == 1:
        labels[:] = 0

    for i, seg in enumerate(segments):
        seg.speaker = f"SPEAKER_{labels[i]}"

    for i in range(1, len(segments) - 1):
        if segments[i - 1].speaker == segments[i + 1].speaker != segments[i].speaker:
            if (segments[i].end - segments[i].start) < 2.0:
                segments[i].speaker = segments[i - 1].speaker

    # Split speakers that contain both male and female voices (pitch-based)
    print("      Checking for mixed-gender speaker clusters...")
    speaker_seg_pitches: dict[str, list[tuple[int, float]]] = {}
    for i, seg in enumerate(segments):
        start_sample = int(seg.start * sr)
        end_sample = int(seg.end * sr)
        chunk = y[start_sample:end_sample]
        if len(chunk) >= int(sr * 0.5):
            f0 = librosa.yin(chunk.astype(float), fmin=50, fmax=500, sr=sr)
            voiced = f0[(f0 > 50) & (f0 < 500)]
            if len(voiced) > 0:
                speaker_seg_pitches.setdefault(seg.speaker, []).append((i, float(np.median(voiced))))

    next_label = max(labels) + 1 if len(labels) > 0 else 1
    for speaker, pitch_list in speaker_seg_pitches.items():
        pitches = [p for _, p in pitch_list]
        has_male = any(p <= 155 for p in pitches)
        has_female = any(p >= 165 for p in pitches)
        if has_male and has_female:
            print(f"      Splitting {speaker}: found mixed pitches ({min(pitches):.0f}-{max(pitches):.0f} Hz)")
            for seg_idx, pitch in pitch_list:
                if pitch >= 165:
                    segments[seg_idx].speaker = f"SPEAKER_{next_label}"
            next_label += 1

    print("      Detecting gender with inaSpeechSegmenter...")
    gender_regions = detect_gender(audio_path)

    # Also compute pitch-based gender as a secondary signal
    speaker_pitches: dict[str, list[float]] = {}
    for seg in segments:
        start_sample = int(seg.start * sr)
        end_sample = int(seg.end * sr)
        chunk = y[start_sample:end_sample]
        if len(chunk) >= int(sr * 0.5):
            f0 = librosa.yin(chunk.astype(float), fmin=50, fmax=500, sr=sr)
            voiced = f0[(f0 > 50) & (f0 < 500)]
            if len(voiced) > 0:
                median_pitch = float(np.median(voiced))
                speaker_pitches.setdefault(seg.speaker, []).append(median_pitch)

    speaker_pitch_gender: dict[str, str] = {}
    for speaker, pitches in speaker_pitches.items():
        avg_pitch = np.mean(pitches)
        speaker_pitch_gender[speaker] = "woman" if avg_pitch > 165 else "man"
        print(f"      {speaker} avg pitch: {avg_pitch:.0f} Hz -> {speaker_pitch_gender[speaker]}")

    speaker_gender_votes: dict[str, dict[str, float]] = {}
    for seg in segments:
        # Use overlap-weighted voting instead of midpoint-only
        seg_votes: dict[str, float] = {}
        for label, start, end in gender_regions:
            if label not in ("female", "male"):
                continue
            overlap_start = max(seg.start, start)
            overlap_end = min(seg.end, end)
            overlap = overlap_end - overlap_start
            if overlap > 0:
                gender_label = "woman" if label == "female" else "man"
                seg_votes[gender_label] = seg_votes.get(gender_label, 0) + overlap
        detected = max(seg_votes, key=seg_votes.get) if seg_votes else "man"
        duration = seg.end - seg.start
        speaker_gender_votes.setdefault(seg.speaker, {})
        speaker_gender_votes[seg.speaker][detected] = speaker_gender_votes[seg.speaker].get(detected, 0) + duration

    speaker_gender = {}
    for speaker, votes in speaker_gender_votes.items():
        ina_gender = max(votes, key=votes.get)
        total = sum(votes.values())
        pct = votes[ina_gender] / total * 100 if total > 0 else 0
        pitch_gender = speaker_pitch_gender.get(speaker)
        # If pitch says woman, trust it — inaSpeechSegmenter often misclassifies female as male
        if pitch_gender == "woman":
            gender = "woman"
            print(f"      {speaker}: {gender} (pitch override, inaSpeechSegmenter said {ina_gender} {pct:.0f}%)")
        else:
            gender = ina_gender
            print(f"      {speaker}: {gender} ({pct:.0f}% of speech)")
        speaker_gender[speaker] = gender

    for speaker in set(seg.speaker for seg in segments):
        if speaker not in speaker_gender:
            speaker_gender[speaker] = "man"

    for seg in segments:
        seg.gender = speaker_gender[seg.speaker]

    print(f"      Found {len(speaker_gender)} speaker(s)")
    return segments


def assign_speaker_voices(segments: list[Segment], dialect: str = "latin-american") -> dict[str, str]:
    """Map each speaker to a distinct ElevenLabs voice ID based on their gender and dialect."""
    dialect_voices = VOICES.get(dialect, VOICES["latin-american"])

    speakers_by_gender: dict[str, list[str]] = {}
    for seg in segments:
        speakers_by_gender.setdefault(seg.gender, [])
        if seg.speaker not in speakers_by_gender[seg.gender]:
            speakers_by_gender[seg.gender].append(seg.speaker)

    voice_map: dict[str, str] = {}
    for gender, speakers in speakers_by_gender.items():
        voice_pool = dialect_voices.get(gender, dialect_voices["man"])
        for idx, speaker in enumerate(speakers):
            voice_map[speaker] = voice_pool[idx % len(voice_pool)]

    for speaker, voice_id in voice_map.items():
        print(f"      {speaker} -> voice {voice_id} ({dialect})")

    return voice_map


# =============================================================================
# Step 5: Identify Chapters
# =============================================================================

def identify_chapters(segments: list[Segment], target_lang: str = "English") -> list[Chapter]:
    """Use GPT to identify logical chapter breaks with bilingual titles."""
    print("[5/9] Identifying chapters")

    transcript = "\n".join(
        f"[{seg.start:.1f}s - {seg.end:.1f}s] ({seg.speaker}) {seg.text}"
        for seg in segments
    )

    response = openai_client.chat.completions.create(
        model=GPT_MODEL,
        messages=[
            {
                "role": "system",
                "content": (
                    f"You are a video editor. Given a transcript with timestamps, "
                    f"identify logical chapters/sections. Return a JSON array of "
                    f"objects with 'start' (seconds as float), 'title' (English), "
                    f"and 'title_es' ({target_lang} translation). "
                    f"Return ONLY valid JSON."
                )
            },
            {"role": "user", "content": transcript}
        ]
    )

    data = parse_gpt_json(response.choices[0].message.content)
    chapters = [
        Chapter(start=c["start"], title=c["title"], title_es=c.get("title_es", c["title"]))
        for c in data
    ]

    print(f"      Found {len(chapters)} chapters")
    return chapters


# =============================================================================
# Step 6: Translate
# =============================================================================

def translate_segments(segments: list[Segment], target_lang: str = "English") -> list[Segment]:
    """Translate segments with natural dubbing-style phrasing optimized for TTS delivery."""
    print(f"[6/9] Translating to {target_lang}")

    full_text = ""
    for i, seg in enumerate(segments):
        duration = seg.end - seg.start
        word_count = len(seg.text.split())
        full_text += f"[{i}|{duration:.1f}s|{word_count}w] {seg.text}\n"

    response = openai_client.chat.completions.create(
        model=GPT_MODEL,
        messages=[
            {
                "role": "system",
                "content": (
                    f"You are a professional dubbing translator for film/TV. Translate this transcript to {target_lang}.\n\n"
                    "RULES:\n"
                    "1. Produce natural, spoken-style translations. NOT literal word-by-word.\n"
                    "2. Match the syllable count of the original as closely as possible for lip sync.\n"
                    "3. Each line has [index|duration|word_count]. The translation MUST be speakable within that duration at ~4 syllables/second.\n"
                    "4. Prefer contractions and colloquial phrasing over formal/written style.\n"
                    "5. Preserve the emotional tone and intent, but freely rephrase for natural flow.\n"
                    "6. If a line is too long for the duration, shorten creatively while keeping meaning.\n"
                    "7. NEVER skip a line or leave it empty.\n"
                    "8. NEVER use em-dashes, en-dashes, or hyphens as parenthetical separators. Use commas or split into separate sentences instead. The text will be read aloud by TTS, so it must flow naturally as speech.\n"
                    "9. For technical terms with hyphens (like 'zero-shot'), write them as spoken words (like 'zero shot').\n\n"
                    "Return translated lines in same format:\n"
                    "[0|2.5s] Translation here\n"
                    "[1|3.0s] Next translation\n"
                    "..."
                )
            },
            {"role": "user", "content": full_text}
        ]
    )

    result = response.choices[0].message.content.strip()
    translations = {}

    for line in result.split("\n"):
        line = line.strip()
        if not line:
            continue

        match = re.match(r'\[(\d+)\|[\d.]+s(?:\|\d+w)?\]\s*(.+)', line)
        if match:
            idx = int(match.group(1))
            text = match.group(2).strip()
            translations[idx] = text

    for i, seg in enumerate(segments):
        if i in translations:
            seg.translated_text = translations[i]
        else:
            seg.translated_text = seg.text

    print(f"      Translated {len(translations)}/{len(segments)} segments")
    return segments


def merge_segments_for_tts(segments: list[Segment], max_gap_s: float = 1.0,
                           max_merged_duration_s: float = 15.0) -> list[Segment]:
    """Merge adjacent same-speaker segments into full sentences for smoother TTS output."""
    if not segments:
        return segments

    merged = []
    current = None

    for seg in segments:
        if current is None:
            current = Segment(
                start=seg.start, end=seg.end, text=seg.text,
                speaker=seg.speaker, gender=seg.gender,
                translated_text=seg.translated_text
            )
            continue

        gap = seg.start - current.end
        merged_duration = seg.end - current.start
        same_speaker = seg.speaker == current.speaker
        ends_with_sentence = current.translated_text.rstrip()[-1:] in ".!?;:" if current.translated_text.strip() else False

        if (same_speaker and gap <= max_gap_s
                and merged_duration <= max_merged_duration_s
                and not ends_with_sentence):
            current.end = seg.end
            current.text = current.text + " " + seg.text
            current.translated_text = current.translated_text + " " + seg.translated_text
        else:
            merged.append(current)
            current = Segment(
                start=seg.start, end=seg.end, text=seg.text,
                speaker=seg.speaker, gender=seg.gender,
                translated_text=seg.translated_text
            )

    if current:
        merged.append(current)

    return merged


# =============================================================================
# Step 7: Generate Dubbed Audio
# =============================================================================

def generate_tts(text: str, voice_id: str, style: str = "neutral") -> AudioSegment:
    """Generate TTS audio via ElevenLabs with prosody-aware style settings."""
    style_params = {
        "excited":    {"stability": 0.3, "similarity_boost": 0.8, "style": 0.8},
        "soft":       {"stability": 0.7, "similarity_boost": 0.9, "style": 0.3},
        "expressive": {"stability": 0.4, "similarity_boost": 0.75, "style": 0.6},
        "neutral":    {"stability": 0.5, "similarity_boost": 0.75, "style": 0.0},
    }
    params = style_params.get(style, style_params["neutral"])

    audio_iter = elevenlabs_client.text_to_speech.convert(
        voice_id=voice_id,
        text=text,
        model_id="eleven_multilingual_v2",
        output_format="mp3_44100_128",
        voice_settings=VoiceSettings(
            stability=params["stability"],
            similarity_boost=params["similarity_boost"],
            style=params["style"],
        ),
    )
    audio_bytes = b"".join(audio_iter)
    audio = AudioSegment.from_mp3(io.BytesIO(audio_bytes))

    trailing_silence = detect_leading_silence(audio.reverse(), silence_threshold=-40)
    if trailing_silence > 50:
        audio = audio[: len(audio) - trailing_silence + 30]

    return audio


def generate_dubbed_audio(
    segments: list[Segment],
    output_dir: str,
    background_path: str,
    vocals_path: str,
    original_audio_path: str,
    target_lang: str = "English",
    dialect: str = "latin-american",
) -> str:
    """Mix TTS speech with ducked background audio, preserving music-only intro/outro sections."""
    print("[7/8] Generating dubbed audio")

    segments = merge_segments_for_tts(segments)
    print(f"      Merged into {len(segments)} TTS segments")

    voice_map = assign_speaker_voices(segments, dialect=dialect)

    background = AudioSegment.from_wav(background_path)
    original = AudioSegment.from_wav(original_audio_path)
    total_ms = len(background)

    vocals_y, vocals_sr = librosa.load(vocals_path, sr=SAMPLE_RATE)

    silent_regions = detect_silent_regions(vocals_path)
    if silent_regions:
        print(f"      Found {len(silent_regions)} music-only region(s)")

    tts_track = AudioSegment.silent(duration=total_ms)
    current_pos_ms = 0

    for i, seg in enumerate(segments):
        if not seg.translated_text.strip():
            continue

        print(f"      Segment {i+1}/{len(segments)}: {seg.speaker} ({seg.gender})")

        prosody = analyze_prosody(vocals_y, vocals_sr, seg.start, seg.end)
        voice_id = voice_map.get(seg.speaker, VOICES[dialect]["man"][0])
        tts_text = sanitize_for_tts(seg.translated_text)
        tts_audio = generate_tts(tts_text, voice_id, style=prosody["style"])

        seg_start_ms = int(seg.start * 1000)
        seg_end_ms = int(seg.end * 1000)

        next_start_ms = total_ms
        for j in range(i + 1, len(segments)):
            if segments[j].translated_text.strip():
                next_start_ms = int(segments[j].start * 1000)
                break

        original_gap_ms = next_start_ms - seg_end_ms
        actual_start_ms = max(current_pos_ms, seg_start_ms)
        available_ms = next_start_ms - actual_start_ms

        if available_ms <= 100:
            print(f"        Skipping (no room: {available_ms}ms)")
            continue

        if len(tts_audio) > available_ms:
            speed = len(tts_audio) / available_ms

            if speed <= MAX_SPEED:
                tts_audio = adjust_speed(tts_audio, speed, output_dir)
            else:
                for attempt in range(MAX_RETRANSLATE_ATTEMPTS):
                    shorter_text = retranslate_shorter(
                        seg.translated_text, seg.text,
                        available_ms / 1000.0, target_lang
                    )
                    tts_audio = generate_tts(shorter_text, voice_id, style=prosody["style"])
                    seg.translated_text = shorter_text

                    if len(tts_audio) <= available_ms:
                        break

                    new_speed = len(tts_audio) / available_ms
                    if new_speed <= MAX_SPEED:
                        tts_audio = adjust_speed(tts_audio, new_speed, output_dir)
                        break

                if len(tts_audio) > available_ms:
                    print(f"        WARNING: Trimming segment {i} from {len(tts_audio)}ms to {available_ms}ms")
                    tts_audio = tts_audio[:available_ms].fade_out(50)

        seg_duration_ms = seg_end_ms - seg_start_ms
        if len(tts_audio) < seg_duration_ms and seg_duration_ms > 0:
            speed = len(tts_audio) / seg_duration_ms
            if speed < MIN_SPEED:
                speed = MIN_SPEED
            tts_audio = adjust_speed(tts_audio, speed, output_dir)

        tts_audio = tts_audio.fade_in(15).fade_out(15)

        if actual_start_ms < total_ms:
            tts_track = tts_track.overlay(tts_audio, position=actual_start_ms)
            current_pos_ms = actual_start_ms + len(tts_audio) + original_gap_ms

    speech_ranges = []
    for seg in segments:
        if seg.translated_text.strip():
            speech_ranges.append((int(seg.start * 1000), int(seg.end * 1000)))

    def overlaps_speech(start_ms: int, end_ms: int) -> bool:
        return any(s < end_ms and e > start_ms for s, e in speech_ranges)

    ducked_bg = background
    for s_ms, e_ms in speech_ranges:
        s_ms = max(0, s_ms)
        e_ms = min(total_ms, e_ms)
        if e_ms <= s_ms:
            continue
        chunk = background[s_ms:e_ms] + DUCK_DB
        ducked_bg = ducked_bg[:s_ms] + chunk + ducked_bg[e_ms:]

    dubbed = ducked_bg.overlay(tts_track)

    for start, end in silent_regions:
        start_ms = int(start * 1000)
        end_ms = int(end * 1000)

        if overlaps_speech(start_ms, end_ms):
            continue

        original_chunk = original[start_ms:end_ms]

        if start_ms == 0:
            dubbed = crossfade_splice(original_chunk, dubbed[end_ms:])
        elif end_ms >= total_ms - 100:
            dubbed = crossfade_splice(dubbed[:start_ms], original_chunk)
        else:
            before = crossfade_splice(dubbed[:start_ms], original_chunk)
            dubbed = crossfade_splice(before, dubbed[end_ms:])

    if len(dubbed) > total_ms:
        dubbed = dubbed[:total_ms]
    elif len(dubbed) < total_ms:
        dubbed = dubbed + AudioSegment.silent(duration=total_ms - len(dubbed))

    audio_output = os.path.join(output_dir, "dub_es.mp3")
    dubbed.export(audio_output, format="mp3", bitrate="192k")
    print(f"      Saved: {audio_output}")

    return audio_output


# =============================================================================
# Step 8: Create Dubbed Video
# =============================================================================

def create_dubbed_video(video_path: str, dub_audio_path: str, output_dir: str) -> str:
    """Combine original video with dubbed audio into final MP4."""
    print("[8/9] Creating dubbed video")

    output_path = os.path.join(output_dir, "dubbed_es.mp4")

    run_ffmpeg([
        "-i", video_path,
        "-i", dub_audio_path,
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-map", "0:v:0",
        "-map", "1:a:0",
        output_path
    ])

    print(f"      Saved: {output_path}")
    return output_path


# =============================================================================
# Step 9: Create HLS Package
# =============================================================================

def create_hls(
    video_path: str,
    dub_path: str,
    vtt_en: str,
    vtt_es: str,
    chapters: list[Chapter],
    output_dir: str
) -> str:
    """Create HLS streaming package with multi-audio, subtitles, and chapters."""
    print("[9/9] Creating HLS package")

    hls_dir = os.path.join(output_dir, "hls")
    os.makedirs(hls_dir, exist_ok=True)

    duration = float(run_ffprobe([
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_path
    ]))

    print("      Creating video segments...")
    run_ffmpeg([
        "-i", video_path, "-an", "-c:v", "copy",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", os.path.join(hls_dir, "seg_v_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_v.mp4",
        "-hls_playlist_type", "vod",
        os.path.join(hls_dir, "playlist_v.m3u8")
    ])

    print("      Creating English audio track...")
    run_ffmpeg([
        "-i", video_path, "-vn", "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", os.path.join(hls_dir, "seg_a-eng_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-eng.mp4",
        "-hls_playlist_type", "vod",
        os.path.join(hls_dir, "playlist_a-eng.m3u8")
    ])

    print("      Creating Spanish audio track...")
    run_ffmpeg([
        "-i", dub_path, "-acodec", "aac", "-b:a", "128k", "-ac", "2",
        "-f", "hls", "-hls_time", "6",
        "-hls_segment_type", "fmp4",
        "-hls_segment_filename", os.path.join(hls_dir, "seg_a-spa_%03d.mp4"),
        "-hls_fmp4_init_filename", "init_a-spa.mp4",
        "-hls_playlist_type", "vod",
        os.path.join(hls_dir, "playlist_a-spa.m3u8")
    ])

    print("      Adding subtitles...")
    shutil.copy2(vtt_en, os.path.join(hls_dir, "subs_en.webvtt"))
    shutil.copy2(vtt_es, os.path.join(hls_dir, "subs_es.webvtt"))

    for lang in ["en", "es"]:
        with open(os.path.join(hls_dir, f"playlist_s-{lang}.m3u8"), "w") as f:
            f.write("#EXTM3U\n")
            f.write(f"#EXT-X-TARGETDURATION:{int(duration) + 1}\n")
            f.write("#EXT-X-VERSION:3\n")
            f.write("#EXT-X-PLAYLIST-TYPE:VOD\n")
            f.write(f"#EXTINF:{duration:.3f},\n")
            f.write(f"subs_{lang}.webvtt\n")
            f.write("#EXT-X-ENDLIST\n")

    print("      Adding chapters...")
    with open(os.path.join(hls_dir, "chapters_en.vtt"), "w") as f:
        f.write("WEBVTT\n\n")
        for i, ch in enumerate(chapters):
            end = chapters[i + 1].start if i + 1 < len(chapters) else duration
            f.write(f"Chapter {i + 1}\n")
            f.write(f"{fmt_vtt_ts(ch.start)} --> {fmt_vtt_ts(end)}\n")
            f.write(f"{ch.title}\n\n")

    with open(os.path.join(hls_dir, "chapters_es.vtt"), "w") as f:
        f.write("WEBVTT\n\n")
        for i, ch in enumerate(chapters):
            end = chapters[i + 1].start if i + 1 < len(chapters) else duration
            f.write(f"Chapter {i + 1}\n")
            f.write(f"{fmt_vtt_ts(ch.start)} --> {fmt_vtt_ts(end)}\n")
            f.write(f"{ch.title_es}\n\n")

    with open(os.path.join(output_dir, "chapters.json"), "w") as f:
        json.dump([asdict(c) for c in chapters], f, indent=2)

    print("      Creating master playlist...")
    master_path = os.path.join(hls_dir, "master.m3u8")
    with open(master_path, "w") as f:
        f.write("#EXTM3U\n\n")
        f.write('#EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-eng.m3u8",')
        f.write('GROUP-ID="audio",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES\n')
        f.write('#EXT-X-MEDIA:TYPE=AUDIO,URI="playlist_a-spa.m3u8",')
        f.write('GROUP-ID="audio",LANGUAGE="es",NAME="Español",AUTOSELECT=YES\n\n')
        f.write('#EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-en.m3u8",')
        f.write('GROUP-ID="subs",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES\n')
        f.write('#EXT-X-MEDIA:TYPE=SUBTITLES,URI="playlist_s-es.m3u8",')
        f.write('GROUP-ID="subs",LANGUAGE="es",NAME="Español",AUTOSELECT=YES\n\n')
        f.write('#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="audio",SUBTITLES="subs"\n')
        f.write("playlist_v.m3u8\n")

    print(f"      Created: {master_path}")
    return master_path


def generate_cos_json(
    title: str,
    chapters: list[Chapter],
    output_dir: str,
    base_url: str = "",
    duration: float = 0.0,
) -> str:
    """Generate COS video player JSON config."""
    print("      Generating COS video player JSON...")

    chapter_list = []
    for i, ch in enumerate(chapters):
        end = chapters[i + 1].start if i + 1 < len(chapters) else duration
        ch_id = re.sub(r"[^a-z0-9]+", "_", ch.title.lower()).strip("_")
        chapter_list.append({
            "id": ch_id,
            "start": ch.start,
            "end": round(end, 1),
            "title": ch.title,
            "title_es": ch.title_es,
        })

    cos_config = {
        "version": 2,
        "video": {
            "title": title,
            "chapters": chapter_list,
            "videos": [
                {
                    "url": f"{base_url}/hls/master.m3u8",
                    "quality": "original",
                    "downloadable": True,
                    "hd": True,
                }
            ],
            "subtitles": [
                {
                    "url": f"{base_url}/transcript_en.srt",
                    "label": "English",
                    "language": "EN",
                    "format": "srt",
                },
                {
                    "url": f"{base_url}/transcript_es.srt",
                    "label": "Spanish",
                    "language": "ES",
                    "format": "srt",
                },
            ],
        },
    }

    json_path = os.path.join(output_dir, "cos_player.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(cos_config, f, indent=2, ensure_ascii=False)

    print(f"      Saved: {json_path}")
    return json_path


# =============================================================================
# Main
# =============================================================================

def main():
    video_path = sys.argv[1] if len(sys.argv) > 1 else "example.mp4"
    num_speakers = int(sys.argv[2]) if len(sys.argv) > 2 else None

    if not os.path.exists(video_path):
        print(f"Error: '{video_path}' not found")
        sys.exit(1)

    video_name = Path(video_path).stem
    output_dir = os.path.join("output", video_name)
    os.makedirs(output_dir, exist_ok=True)

    print(f"Processing: {video_path}")
    print(f"Output: {output_dir}\n")

    audio_path = extract_audio(video_path, output_dir)
    vocals_path, background_path = separate_audio(audio_path, output_dir)
    segments = transcribe_audio(vocals_path, output_dir)
    segments = diarize_speakers(vocals_path, segments, num_speakers=num_speakers)

    vtt_en = os.path.join(output_dir, "transcript_en.vtt")
    save_vtt(segments, vtt_en)
    print(f"      Saved: {vtt_en}")

    srt_en = os.path.join(output_dir, "transcript_en.srt")
    save_srt(segments, srt_en)
    print(f"      Saved: {srt_en}")

    chapters = identify_chapters(segments)
    segments = translate_segments(segments, target_lang="Spanish")

    vtt_es = os.path.join(output_dir, "transcript_es.vtt")
    save_vtt(segments, vtt_es, use_translated=True)
    print(f"      Saved: {vtt_es}")

    srt_es = os.path.join(output_dir, "transcript_es.srt")
    save_srt(segments, srt_es, use_translated=True)
    print(f"      Saved: {srt_es}")

    dub_audio_path = generate_dubbed_audio(
        segments, output_dir, background_path, vocals_path, audio_path
    )

    create_dubbed_video(video_path, dub_audio_path, output_dir)
    create_hls(video_path, dub_audio_path, vtt_en, vtt_es, chapters, output_dir)

    duration = float(run_ffprobe([
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        video_path
    ]))
    video_title = video_name.replace("_", " ").title()
    generate_cos_json(video_title, chapters, output_dir, duration=duration)

    print(f"\nDone! Output: {output_dir}/")
    print("  - dubbed_es.mp4        <- Final dubbed video")
    print("  - dub_es.mp3")
    print("  - transcript_en.vtt / .srt")
    print("  - transcript_es.vtt / .srt")
    print("  - chapters.json")
    print("  - cos_player.json      <- COS video player config")
    print("  - hls/master.m3u8")


if __name__ == "__main__":
    main()