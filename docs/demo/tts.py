#!/usr/bin/env python3
"""Generates the demo narration with Gemini text-to-speech, one WAV per segment.

    docs/demo/tts.py [--only 03-assemble] [--out DIR]

Reads docs/demo/segments.json, needs GEMINI_API_KEY in the environment, writes
<out>/<id>.wav (24 kHz, 16-bit, mono) and prints each file's length so the segment
timings in the script can be checked. Uses the REST API directly: no SDK needed.
"""
import argparse
import base64
import json
import os
import pathlib
import re
import struct
import sys
import urllib.error
import urllib.request
import wave

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_OUT = pathlib.Path.home() / "Movies" / "Framewright Demo" / "narration"


def synthesize(model: str, key: str, voice: str, style: str, text: str) -> tuple[bytes, int]:
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
    body = {
        "contents": [{"parts": [{"text": f"{style}\n\n{text}"}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code}: {error.read().decode()[:600]}")
    try:
        part = payload["candidates"][0]["content"]["parts"][0]["inlineData"]
    except (KeyError, IndexError):
        sys.exit(f"no audio in the response: {json.dumps(payload)[:600]}")
    mime = part.get("mimeType", "")
    rate = int(re.search(r"rate=(\d+)", mime).group(1)) if "rate=" in mime else 24000
    if not mime.lower().startswith(("audio/l16", "audio/pcm")):
        sys.exit(f"unexpected audio type {mime}")
    return base64.b64decode(part["data"]), rate


def write_wav(path: pathlib.Path, pcm: bytes, rate: int) -> float:
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm)
    return len(pcm) / 2 / rate


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="a segment id to (re)generate")
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        sys.exit("GEMINI_API_KEY is not set")
    spec = json.loads((HERE / "segments.json").read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    total = 0.0
    for segment in spec["segments"]:
        if args.only and segment["id"] != args.only:
            continue
        pcm, rate = synthesize(spec["model"], key, spec["voice"], spec["style"], segment["narration"])
        path = args.out / f"{segment['id']}.wav"
        seconds = write_wav(path, pcm, rate)
        total += seconds
        fit = "ok" if seconds <= segment["seconds"] else f"LONGER than the {segment['seconds']} s slot"
        print(f"{segment['id']:<16} {seconds:5.1f} s  (slot {segment['seconds']:2d} s)  {fit}")
    print(f"total narration {total:.1f} s -> {args.out}")


if __name__ == "__main__":
    main()
