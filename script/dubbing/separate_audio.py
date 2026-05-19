"""Separate vocals from background audio using Demucs"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_path")
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    audio_path = Path(args.audio_path)
    output_dir = Path(args.output_dir)

    result = subprocess.run(
        ["python3", "-m", "demucs", "--two-stems", "vocals", "-o", str(output_dir), str(audio_path)],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(1)

    demucs_dir = output_dir / "htdemucs" / audio_path.stem
    shutil.move(str(demucs_dir / "vocals.wav"), str(output_dir / "vocals.wav"))
    shutil.move(str(demucs_dir / "no_vocals.wav"), str(output_dir / "background.wav"))


if __name__ == "__main__":
    main()
