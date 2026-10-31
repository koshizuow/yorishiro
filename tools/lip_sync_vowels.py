#!/usr/bin/env python3
"""Synthetic vowels for the lip sync test: a glottal pulse train through formant resonators (a source-filter
voice), a, i, u, e, o with silence between, as a 16-bit mono WAV plus a JSON of where each part is.
Only numpy, no recordings, so the test needs no private data.
    python3 tools/lip_sync_vowels.py out.wav
"""
import json
import sys
import wave

import numpy as np

RATE = 44100
PITCH = 130.0
# first three formants (Hz) and bandwidths, an average adult voice
VOWELS = {
    "a": ((750, 1250, 2600), (90, 110, 160)),
    "i": ((300, 2300, 3000), (60, 120, 180)),
    "u": ((350, 1250, 2400), (70, 110, 160)),
    "e": ((480, 1900, 2600), (70, 110, 160)),
    "o": ((500, 850, 2500), (80, 100, 160)),
}
VOWEL_SECONDS = 1.2
GAP_SECONDS = 0.6


def resonator(x, freq, bw):
    """Two-pole resonance at freq with bandwidth bw."""
    r = np.exp(-np.pi * bw / RATE)
    c = 2 * r * np.cos(2 * np.pi * freq / RATE)
    y = np.zeros_like(x)
    y1 = y2 = 0.0
    for i, v in enumerate(x):
        y0 = v + c * y1 - r * r * y2
        y[i] = y0
        y2, y1 = y1, y0
    return y


def vowel(name, seconds):
    n = int(seconds * RATE)
    rng = np.random.default_rng(0)
    src = np.zeros(n)
    t = 0.0
    while t < n:
        src[int(t)] = 1.0
        t += RATE / (PITCH * (1 + 0.01 * rng.standard_normal()))
    # glottal pulses fall off about 12 dB per octave, the lips radiate +6: a one-pole low-pass on the
    # pulse train and a first difference
    src = resonator(src, 0.0, 300.0)
    src = np.diff(src, prepend=0.0)
    freqs, bws = VOWELS[name]
    y = src
    for f, b in zip(freqs, bws):
        y = resonator(y, f, b)
    y /= np.abs(y).max()
    fade = int(0.04 * RATE)
    y[:fade] *= np.linspace(0, 1, fade)
    y[-fade:] *= np.linspace(1, 0, fade)
    return y * 0.5


def main(out):
    parts, timeline, t = [], [], 0.0
    for name in VOWELS:
        parts.append(np.zeros(int(GAP_SECONDS * RATE)))
        timeline.append({"part": "silence", "start": t, "end": t + GAP_SECONDS})
        t += GAP_SECONDS
        parts.append(vowel(name, VOWEL_SECONDS))
        timeline.append({"part": name, "start": t, "end": t + VOWEL_SECONDS})
        t += VOWEL_SECONDS
    audio = np.concatenate(parts)
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((audio * 32767).astype("<i2").tobytes())
    with open(out.rsplit(".", 1)[0] + ".json", "w") as f:
        json.dump(timeline, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
