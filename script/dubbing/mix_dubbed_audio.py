import argparse
import json
import os
import subprocess
import sys

import numpy as np
import librosa
import soundfile as sf
from pydub import AudioSegment

SAMPLE_RATE = 16000
DUCK_DB = -8
MAX_SPEED = 1.35
MIN_SPEED = 0.85
FADE_MS = 15
MIN_SLOT_MS = 100
SLOT_PAD_MS = 500

SILENCE_THRESHOLD_DBFS = -40.0
SILENCE_MIN_DURATION_S = 0.5
DUCK_MERGE_GAP_MS = 250
MIN_OUTPUT_BYTES = 1024

FFMPEG_MIX_TIMEOUT_S = 1800
FFMPEG_SPEED_TIMEOUT_S = 120
FFPROBE_TIMEOUT_S = 30
ERROR_LOG_TAIL_BYTES = 8192


def _tail_file(path, n_bytes):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > n_bytes:
                f.seek(-n_bytes, os.SEEK_END)
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def run_subprocess_logged(cmd, log_path, timeout_s, error_prefix):
    """
    Run a subprocess with stderr (and stdout) streamed to a file on disk
    rather than buffered in memory. On failure, read the tail of the log
    so the exception carries useful context without holding the whole log.
    """
    with open(log_path, "wb") as logf:
        try:
            result = subprocess.run(
                cmd, stdout=logf, stderr=subprocess.STDOUT, timeout=timeout_s,
            )
        except subprocess.TimeoutExpired:
            tail = _tail_file(log_path, ERROR_LOG_TAIL_BYTES)
            raise RuntimeError(
                f"{error_prefix} timed out after {timeout_s}s. Log tail:\n{tail}"
            )
    if result.returncode != 0:
        tail = _tail_file(log_path, ERROR_LOG_TAIL_BYTES)
        raise RuntimeError(f"{error_prefix} failed (exit {result.returncode}). Log tail:\n{tail}")
    return result


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
    log_path = os.path.join(output_dir, f"_speed_log_{segment_index}.txt")

    try:
        audio.export(temp_in, format="mp3")
        filter_str = ",".join(build_atempo_chain(speed))
        run_subprocess_logged(
            ["ffmpeg", "-y", "-i", temp_in, "-filter:a", filter_str, temp_out],
            log_path=log_path,
            timeout_s=FFMPEG_SPEED_TIMEOUT_S,
            error_prefix=f"ffmpeg atempo (segment {segment_index}, speed={speed}, filter={filter_str})",
        )
        return AudioSegment.from_mp3(temp_out)
    finally:
        for path in (temp_in, temp_out, log_path):
            try:
                os.remove(path)
            except OSError:
                pass


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


def probe_audio_format(path):
    """Returns (sample_rate, channels, duration_ms) without loading the file"""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "stream=sample_rate,channels:format=duration",
             "-of", "json", path],
            capture_output=True, text=True, timeout=FFPROBE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"ffprobe timed out after {FFPROBE_TIMEOUT_S}s for {path}")
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed for {path}: {result.stderr}")
    info = json.loads(result.stdout)
    stream = info["streams"][0]
    sr = int(stream["sample_rate"])
    ch = int(stream["channels"])
    duration_ms = int(float(info["format"]["duration"]) * 1000)
    return sr, ch, duration_ms


def detect_silent_regions(audio_path):
    """
    Load the vocals at SAMPLE_RATE mono and find regions below the
    absolute dBFS threshold. Returns a list of (start_s, end_s) tuples.
    """
    y, _ = librosa.load(audio_path, sr=SAMPLE_RATE, mono=True)
    file_duration_s = len(y) / SAMPLE_RATE
    frame_length = int(0.5 * SAMPLE_RATE)
    hop_length = frame_length // 2

    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    rms_db = librosa.amplitude_to_db(rms, ref=1.0)

    regions = []
    in_silent = False
    start_time = 0.0
    for i, is_silent in enumerate((rms_db < SILENCE_THRESHOLD_DBFS).tolist()):
        time = i * hop_length / SAMPLE_RATE
        if is_silent and not in_silent:
            start_time = time
            in_silent = True
        elif not is_silent and in_silent:
            if time - start_time > SILENCE_MIN_DURATION_S:
                regions.append((start_time, time))
            in_silent = False
    if in_silent and file_duration_s - start_time > SILENCE_MIN_DURATION_S:
        regions.append((start_time, file_duration_s))
    return regions


def compute_slots(segments, indices_with_tts, total_ms):
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
    return slots


def merge_close_ranges(ranges, gap_ms):
    """Merge ranges whose gap is <= gap_ms so duck transitions don't produce micro-gaps"""
    if not ranges:
        return []
    sorted_ranges = sorted(ranges)
    merged = [list(sorted_ranges[0])]
    for s, e in sorted_ranges[1:]:
        if s - merged[-1][1] <= gap_ms:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return [tuple(r) for r in merged]


def subtract_overlaps(silent_regions_ms, placed_ranges_ms):
    return [
        (s, e) for s, e in silent_regions_ms
        if not overlaps_any(s, e, placed_ranges_ms)
    ]


def clip_to_int16_array(audio_segment, target_sr, target_channels):
    """Convert a pydub AudioSegment to an (N, channels) int16 numpy array at target_sr"""
    seg = audio_segment.set_frame_rate(target_sr).set_sample_width(2).set_channels(target_channels)
    samples = np.frombuffer(seg.raw_data, dtype=np.int16)
    if target_channels > 1:
        samples = samples.reshape(-1, target_channels)
    else:
        samples = samples.reshape(-1, 1)
    return samples


def assemble_tts_track(segments, slots, tts_map, indices_with_tts, total_ms,
                       sample_rate, channels, output_dir, out_path):
    """
    Stream-write the TTS track to disk. Each placed clip is loaded and prepared
    individually, then its samples are appended to the output WAV. Memory stays
    bounded by the largest single clip (~15s by upstream MAX_MERGED_DURATION_S).
    """
    total_frames = int(total_ms * sample_rate / 1000)
    silence_chunk = np.zeros((4096, channels), dtype=np.int16)

    def write_silence(out, frames):
        remaining = frames
        while remaining > 0:
            n = min(remaining, silence_chunk.shape[0])
            out.write(silence_chunk[:n])
            remaining -= n

    placed_ranges = []
    tmp_path = out_path + ".tmp"

    try:
        with sf.SoundFile(tmp_path, "w", samplerate=sample_rate,
                          channels=channels, subtype="PCM_16",
                          format="WAV") as out:
            cursor_frames = 0

            for pos, i in enumerate(indices_with_tts):
                slot_start_ms, slot_end_ms = slots[i]
                slot_ms = slot_end_ms - slot_start_ms
                if slot_ms < MIN_SLOT_MS:
                    print(f"Skipping segment {i} (slot too small: {slot_ms}ms)", file=sys.stderr)
                    continue

                start_frame = int(slot_start_ms * sample_rate / 1000)

                # If a previous clip's playback already extended past this slot's start,
                # skip this clip rather than mix on top of it
                if start_frame < cursor_frames:
                    print(
                        f"Skipping segment {i} (previous clip bleeds past slot start by "
                        f"{cursor_frames - start_frame} frames)",
                        file=sys.stderr,
                    )
                    continue

                tts_audio = AudioSegment.from_mp3(tts_map[i])
                seg_duration_ms = int((segments[i]["end"] - segments[i]["start"]) * 1000)
                tts_audio = place_clip(tts_audio, slot_ms, seg_duration_ms, output_dir, i)

                samples = clip_to_int16_array(tts_audio, sample_rate, channels)
                clip_frames = samples.shape[0]

                # Cap clip length at: end of file, AND start of next clip's slot
                hard_cap_frames = total_frames - start_frame
                if pos + 1 < len(indices_with_tts):
                    next_slot_start_ms = slots[indices_with_tts[pos + 1]][0]
                    next_start_frame = int(next_slot_start_ms * sample_rate / 1000)
                    hard_cap_frames = min(hard_cap_frames, next_start_frame - start_frame)
                hard_cap_frames = max(0, hard_cap_frames)
                if clip_frames > hard_cap_frames:
                    samples = samples[:hard_cap_frames]
                    clip_frames = hard_cap_frames

                if clip_frames == 0:
                    continue

                if start_frame > cursor_frames:
                    write_silence(out, start_frame - cursor_frames)
                    cursor_frames = start_frame

                out.write(samples)
                cursor_frames += clip_frames

                actual_end_ms = slot_start_ms + int(clip_frames * 1000 / sample_rate)
                placed_ranges.append((slot_start_ms, actual_end_ms))

            if cursor_frames < total_frames:
                write_silence(out, total_frames - cursor_frames)

        os.replace(tmp_path, out_path)
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise

    return placed_ranges


def write_silent_track(out_path, total_ms, sample_rate, channels):
    """Used when there are no TTS clips. amix still needs a silent track of the right length"""
    total_frames = int(total_ms * sample_rate / 1000)
    silence_chunk = np.zeros((4096, channels), dtype=np.int16)
    with sf.SoundFile(out_path, "w", samplerate=sample_rate,
                      channels=channels, subtype="PCM_16",
                      format="WAV") as out:
        remaining = total_frames
        while remaining > 0:
            n = min(remaining, silence_chunk.shape[0])
            out.write(silence_chunk[:n])
            remaining -= n


def fmt_range(start_ms, end_ms):
    return f"between(t,{start_ms / 1000:.3f},{end_ms / 1000:.3f})"


def build_filtergraph(duck_ranges_ms, patch_ranges_ms):
    """
    Inputs: [0:a]=background, [1:a]=tts_track, [2:a]=original
    Output label: [out]
    """
    lines = []

    if duck_ranges_ms:
        duck_expr = "+".join(fmt_range(s, e) for s, e in duck_ranges_ms)
        lines.append(f"[0:a]volume=enable='{duck_expr}':volume={DUCK_DB}dB[ducked]")
        bg_label = "[ducked]"
    else:
        bg_label = "[0:a]"

    lines.append(
        f"{bg_label}[1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[mixed]"
    )

    if patch_ranges_ms:
        patch_expr = "+".join(fmt_range(s, e) for s, e in patch_ranges_ms)
        lines.append(
            f"[mixed]volume=enable='{patch_expr}':volume=0[mix_holed]"
        )
        lines.append(
            f"[2:a]volume=enable='{patch_expr}':volume=1:eval=frame,"
            f"volume=enable='not({patch_expr})':volume=0[orig_patches]"
        )
        lines.append(
            "[mix_holed][orig_patches]amix=inputs=2:duration=first:"
            "dropout_transition=0:normalize=0[out]"
        )
    else:
        lines.append("[mixed]anull[out]")

    return ";\n".join(lines)


def validate_inputs(args):
    for label, path in [
        ("background", args.background_path),
        ("vocals", args.vocals_path),
        ("original audio", args.original_audio_path),
        ("segments file", args.segments_file),
        ("tts files file", args.tts_files_file),
    ]:
        if not os.path.exists(path):
            raise FileNotFoundError(f"{label} not found: {path}")
    if not os.path.isdir(args.output_dir):
        raise FileNotFoundError(f"output dir not found: {args.output_dir}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--segments-file", required=True)
    parser.add_argument("--tts-files-file", required=True)
    parser.add_argument("--background-path", required=True)
    parser.add_argument("--vocals-path", required=True)
    parser.add_argument("--original-audio-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    validate_inputs(args)

    with open(args.segments_file) as f:
        segments = json.load(f)
    with open(args.tts_files_file) as f:
        tts_files = json.load(f)

    bg_sr, bg_ch, total_ms = probe_audio_format(args.background_path)

    silent_regions_s = detect_silent_regions(args.vocals_path)
    for s, e in silent_regions_s:
        print(f"  silent region: {s:.1f}s - {e:.1f}s", file=sys.stderr)

    tts_map = {f["index"]: f["path"] for f in tts_files}
    indices_with_tts = sorted(i for i in tts_map.keys() if i < len(segments))
    slots = compute_slots(segments, indices_with_tts, total_ms)

    tts_track_path = os.path.join(args.output_dir, "tts_track.wav")
    if indices_with_tts:
        placed_ranges_ms = assemble_tts_track(
            segments, slots, tts_map, indices_with_tts, total_ms,
            bg_sr, bg_ch, args.output_dir, tts_track_path,
        )
    else:
        write_silent_track(tts_track_path, total_ms, bg_sr, bg_ch)
        placed_ranges_ms = []

    duck_ranges_ms = merge_close_ranges(placed_ranges_ms, DUCK_MERGE_GAP_MS)

    silent_regions_ms = [
        (max(0, int(s * 1000)), min(total_ms, int(e * 1000)))
        for s, e in silent_regions_s
    ]
    silent_regions_ms = [(s, e) for s, e in silent_regions_ms if e > s]
    patch_ranges_ms = subtract_overlaps(silent_regions_ms, placed_ranges_ms)
    for s, e in patch_ranges_ms:
        print(f"  splicing original audio into {s / 1000:.1f}s-{e / 1000:.1f}s", file=sys.stderr)

    graph = build_filtergraph(duck_ranges_ms, patch_ranges_ms)
    graph_path = os.path.join(args.output_dir, "mix_filtergraph.txt")
    with open(graph_path, "w") as f:
        f.write(graph)

    output_path = os.path.join(args.output_dir, "dubbed.mp3")
    mix_log_path = os.path.join(args.output_dir, "ffmpeg_mix.log")
    run_subprocess_logged(
        [
            "ffmpeg", "-y",
            "-i", args.background_path,
            "-i", tts_track_path,
            "-i", args.original_audio_path,
            "-filter_complex_script", graph_path,
            "-map", "[out]",
            "-ar", str(bg_sr),
            "-ac", str(bg_ch),
            "-c:a", "libmp3lame",
            "-b:a", "192k",
            output_path,
        ],
        log_path=mix_log_path,
        timeout_s=FFMPEG_MIX_TIMEOUT_S,
        error_prefix="ffmpeg mix",
    )

    if not os.path.exists(output_path) or os.path.getsize(output_path) < MIN_OUTPUT_BYTES:
        size = os.path.getsize(output_path) if os.path.exists(output_path) else "missing"
        raise RuntimeError(
            f"ffmpeg reported success but output is missing or suspiciously small: "
            f"{output_path} ({size} bytes)"
        )

    summary = {
        "placed_clips": len(placed_ranges_ms),
        "duck_ranges": len(duck_ranges_ms),
        "silent_regions": len(silent_regions_s),
        "patch_ranges": len(patch_ranges_ms),
        "duration_ms": total_ms,
        "output_bytes": os.path.getsize(output_path),
    }
    print(json.dumps(summary), file=sys.stderr)
    print(f"Wrote {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
