import argparse
import json
import os
import subprocess
import sys

import numpy as np
import librosa
from pydub import AudioSegment

SAMPLE_RATE = 16000
CROSSFADE_MS = 30
DUCK_DB = -8
MAX_SPEED = 1.35
MIN_SPEED = 0.85
FADE_MS = 15
MIN_SLOT_MS = 100
SLOT_PAD_MS = 500

def build_atempo_chain(speed):
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


def adjust_speed(audio, speed, output_dir, segment_index):
    if abs(speed - 1.0) < 0.01:
        return audio

    temp_in = os.path.join(output_dir, f"_speed_in_{segment_index}.mp3")
    temp_out = os.path.join(output_dir, f"_speed_out_{segment_index}.mp3")

    try:
        audio.export(temp_in, format="mp3")
        filter_str = ",".join(build_atempo_chain(speed))
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", temp_in, "-filter:a", filter_str, temp_out],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"ffmpeg atempo failed (speed={speed}, filter={filter_str}): {result.stderr}"
            )
        return AudioSegment.from_mp3(temp_out)
    finally:
        for path in (temp_in, temp_out):
            try:
                os.remove(path)
            except OSError:
                pass


def detect_silent_regions(audio_path, threshold_db=-40.0):
    """Find regions where vocals are silent (music-only intro/outro)."""
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


def crossfade_splice(audio_a, audio_b, crossfade_ms=CROSSFADE_MS):
    """Join two audio segments with a crossfade so the transition isn't audible."""
    crossfade_ms = min(crossfade_ms, len(audio_a), len(audio_b))
    if crossfade_ms <= 0:
        return audio_a + audio_b
    return audio_a.append(audio_b, crossfade=crossfade_ms)


def place_clip(tts_audio, slot_ms, seg_duration_ms, output_dir, segment_index):
    """Fit a TTS clip into the available slot. Speed up if too long, slow down (gently) if much shorter."""
    if len(tts_audio) > slot_ms:
        speed = len(tts_audio) / slot_ms
        if speed <= MAX_SPEED:
            tts_audio = adjust_speed(tts_audio, speed, output_dir, segment_index)
        else:
            tts_audio = adjust_speed(tts_audio, MAX_SPEED, output_dir, segment_index)
            if len(tts_audio) > slot_ms:
                tts_audio = tts_audio[:slot_ms].fade_out(50)
    elif seg_duration_ms > 0 and len(tts_audio) < seg_duration_ms:
        speed = len(tts_audio) / seg_duration_ms
        if speed < MIN_SPEED:
            speed = MIN_SPEED
        tts_audio = adjust_speed(tts_audio, speed, output_dir, segment_index)
    return tts_audio.fade_in(FADE_MS).fade_out(FADE_MS)


def overlaps_any(start_ms, end_ms, ranges):
    return any(s < end_ms and e > start_ms for s, e in ranges)


def splice_original_into(dubbed, original, start_ms, end_ms, total_ms):
    """Replace dubbed[start_ms:end_ms] with original[start_ms:end_ms] using crossfades."""
    original_chunk = original[start_ms:end_ms]
    if start_ms == 0:
        return crossfade_splice(original_chunk, dubbed[end_ms:])
    if end_ms >= total_ms - 100:
        return crossfade_splice(dubbed[:start_ms], original_chunk)
    before = crossfade_splice(dubbed[:start_ms], original_chunk)
    return crossfade_splice(before, dubbed[end_ms:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--segments-file", required=True)
    parser.add_argument("--tts-files-file", required=True)
    parser.add_argument("--background-path", required=True)
    parser.add_argument("--vocals-path", required=True)
    parser.add_argument("--original-audio-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    with open(args.segments_file) as f:
        segments = json.load(f)
    with open(args.tts_files_file) as f:
        tts_files = json.load(f)

    background = AudioSegment.from_wav(args.background_path)
    original = AudioSegment.from_wav(args.original_audio_path)
    total_ms = len(background)

    silent_regions = detect_silent_regions(args.vocals_path)
    for s, e in silent_regions:
        print(f"  silent region: {s:.1f}s - {e:.1f}s", file=sys.stderr)

    tts_map = {f["index"]: f["path"] for f in tts_files}

    indices_with_tts = sorted(i for i in tts_map.keys() if i < len(segments))
    slots = {}
    for pos, i in enumerate(indices_with_tts):
        slot_start = int(segments[i]["start"] * 1000)
        next_clip_start = (
            int(segments[indices_with_tts[pos + 1]]["start"] * 1000)
            if pos + 1 < len(indices_with_tts)
            else total_ms
        )
        seg_end_ms = int(segments[i]["end"] * 1000) + SLOT_PAD_MS
        slot_end = min(next_clip_start, seg_end_ms)
        slots[i] = (max(0, slot_start), min(total_ms, slot_end))

    tts_track = AudioSegment.silent(duration=total_ms)
    placed_ranges = []

    for i in indices_with_tts:
        slot_start, slot_end = slots[i]
        slot_ms = slot_end - slot_start
        if slot_ms < MIN_SLOT_MS:
            print(f"Skipping segment {i} (slot too small: {slot_ms}ms)", file=sys.stderr)
            continue

        tts_audio = AudioSegment.from_mp3(tts_map[i])
        seg_duration_ms = int((segments[i]["end"] - segments[i]["start"]) * 1000)
        tts_audio = place_clip(tts_audio, slot_ms, seg_duration_ms, args.output_dir, i)

        tts_track = tts_track.overlay(tts_audio, position=slot_start)
        placed_ranges.append((slot_start, slot_start + len(tts_audio)))

    ducked_bg = background
    for s_ms, e_ms in placed_ranges:
        s_ms = max(0, s_ms)
        e_ms = min(total_ms, e_ms)
        if e_ms <= s_ms:
            continue
        chunk = background[s_ms:e_ms] + DUCK_DB
        ducked_bg = ducked_bg[:s_ms] + chunk + ducked_bg[e_ms:]

    dubbed = ducked_bg.overlay(tts_track)

    for start, end in silent_regions:
        start_ms = max(0, int(start * 1000))
        end_ms = min(total_ms, int(end * 1000))
        if end_ms <= start_ms:
            continue
        if overlaps_any(start_ms, end_ms, placed_ranges):
            print(f"  skipping silent splice {start:.1f}s-{end:.1f}s (overlaps placed clip)", file=sys.stderr)
            continue
        print(f"  splicing original audio into {start:.1f}s-{end:.1f}s", file=sys.stderr)
        dubbed = splice_original_into(dubbed, original, start_ms, end_ms, total_ms)

    if len(dubbed) > total_ms:
        dubbed = dubbed[:total_ms]
    elif len(dubbed) < total_ms:
        dubbed = dubbed + AudioSegment.silent(duration=total_ms - len(dubbed))

    output_path = os.path.join(args.output_dir, "dubbed.mp3")
    dubbed.export(output_path, format="mp3", bitrate="192k")
    print(f"Wrote {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
