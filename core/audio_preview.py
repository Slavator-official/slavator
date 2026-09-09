"""Decode a local audio slice with the already bundled PyAV/FFmpeg libraries."""
from __future__ import annotations

import argparse
import math
import wave
from pathlib import Path


def decode_slice(source: Path, target: Path, start=0.0, end=None):
    import av

    if not source.is_file() or start < 0 or not math.isfinite(start):
        raise ValueError("Некорректный исходный файл или время")
    if end is not None and (not math.isfinite(end) or end <= start):
        raise ValueError("Конец фрагмента должен быть позже начала")
    rate = 24000
    written = 0
    with av.open(str(source), options={"protocol_whitelist":"file,pipe"}) as container:
        stream = next((s for s in container.streams if s.type == "audio"),None)
        if stream is None:
            raise ValueError("Нет звуковой дорожки")
        origin = float(stream.start_time * stream.time_base) if stream.start_time is not None else 0.0
        if start:
            container.seek(int((start+origin) / stream.time_base), stream=stream, backward=True)
        resampler = av.AudioResampler(format="s16",layout="mono",rate=rate)
        # Exclusive creation: a preview cannot overwrite an existing user file.
        with target.open("xb") as raw, wave.open(raw,"wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(rate)
            elapsed = 0.0
            def save(chunk):
                nonlocal written, elapsed
                timestamp = float(chunk.time)-origin if chunk.time is not None else elapsed
                elapsed = timestamp + chunk.samples/rate
                left = max(0,min(chunk.samples,round((start-timestamp)*rate)))
                right = chunk.samples if end is None else max(0,min(chunk.samples,round((end-timestamp)*rate)))
                if right > left:
                    output.writeframes(chunk.to_ndarray()[:,left:right].tobytes())
                    written += right-left
                return end is not None and elapsed >= end
            complete = False
            for frame in container.decode(stream):
                for chunk in resampler.resample(frame):
                    complete = save(chunk) or complete
                if complete:
                    break
            if not complete:
                for chunk in resampler.resample(None):
                    save(chunk)
    if not written:
        raise ValueError("В выбранном интервале нет звука")
    return written/rate


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--start",type=float,default=0)
    parser.add_argument("--end",type=float)
    args = parser.parse_args()
    decode_slice(args.input,args.output,args.start,args.end)
