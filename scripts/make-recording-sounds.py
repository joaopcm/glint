#!/usr/bin/env python3
"""Writes the recording cues in App/Sounds: short struck-bar tones, standard library only.

Each note is a fundamental plus the bar's inharmonic overtone at 3.93x (a marimba's first overtone), both decaying
exponentially, with a 4 ms raised-cosine attack so the waveform never starts on a click. Start and stop are the same
fifth, up and down, so they read as a pair; pause and resume are a softer, smaller third; the tick is one dry high note.

Run: python3 scripts/make-recording-sounds.py
"""

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
OUT = Path(__file__).resolve().parent.parent / "App" / "Sounds"

E4, B3 = 329.63, 246.94
E5, G5, B5 = 659.25, 783.99, 987.77
E6 = 1318.51


def note(freq, decay, length, overtone=0.22):
    samples = []
    attack = int(RATE * 0.004)
    for i in range(int(RATE * length)):
        t = i / RATE
        body = math.sin(2 * math.pi * freq * t) * math.exp(-t / decay)
        ring = overtone * math.sin(2 * math.pi * freq * 3.93 * t) * math.exp(-t / (decay * 0.3))
        ramp = 0.5 - 0.5 * math.cos(math.pi * i / attack) if i < attack else 1
        samples.append((body + ring) * ramp)
    return samples


def mix(parts, length):
    out = [0.0] * int(RATE * length)
    for offset, samples in parts:
        start = int(RATE * offset)
        for i, value in enumerate(samples):
            if start + i < len(out):
                out[start + i] += value
    return out


def write(name, samples, peak_dbfs):
    fade = int(RATE * 0.01)
    for i in range(fade):
        samples[-1 - i] *= i / fade
    scale = 10 ** (peak_dbfs / 20) / max(abs(s) for s in samples)
    frames = b"".join(struct.pack("<h", round(s * scale * 32767)) for s in samples)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(frames)


OUT.mkdir(parents=True, exist_ok=True)
write("RecordingTick", note(E6, 0.025, 0.09, overtone=0.1), -16)
write("RecordingStart", mix([(0, note(E5, 0.12, 0.35)), (0.07, note(B5, 0.16, 0.4))], 0.47), -9)
write("RecordingStop", mix([(0, note(B5, 0.12, 0.35)), (0.07, note(E5, 0.18, 0.45))], 0.52), -9)
write("RecordingPause", mix([(0, note(B5, 0.06, 0.2)), (0.05, note(G5, 0.08, 0.25))], 0.3), -14)
write("RecordingResume", mix([(0, note(G5, 0.06, 0.2)), (0.05, note(B5, 0.08, 0.25))], 0.3), -14)
write("RecordingDiscard", mix([(0, note(E4, 0.08, 0.25, overtone=0.08)), (0.06, note(B3, 0.12, 0.35, overtone=0.08))], 0.41), -12)
