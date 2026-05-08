import argparse
import json
import sys
from pathlib import Path 
from pydub import AudioSegment

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--segments", required=True)
    parser.add_argument("--tts-files", required=True)
    parser.add_argument("--background-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    segments = json.loads(args.segments)
    tts_files = json.loads(args.tts_files)
    background_path = args.background_path
    output_dir = Path(args.output_dir)

    background = AudioSegment.from_wav(background_path)
    total_ms = len(background)
    tts_track = AudioSegment.silent(duration=total_ms)

    tts_map = {f["index"]: f["path"] for f in tts_files}

    for i, seg in enumerate(segments):
        if i not in tts_map:
            continue

        clip = AudioSegment.from_mp3(tts_map[i])
        start_ms = int(seg["start"] * 1000)
        tts_track = tts_track.overlay(clip, position=start_ms)

    DUCK_DB = -8
    for seg in segments:
        s_ms = int(seg["start"] * 1000)
        e_ms = int(seg["end"] * 1000)
        chunk = background[s_ms:e_ms] + DUCK_DB
        background = background[:s_ms] + chunk + background[e_ms:]

    dubbed = background.overlay(tts_track)
    dubbed.export(str(output_dir / "dubbed.mp3"), format="mp3", bitrate="192k")

if __name__ == "__main__":
    main()
