"""Repeatable offline CPU benchmark. No audio/text enters the report or network.

Run each candidate in a fresh process to measure its own peak RSS. This is a
resource benchmark, NOT an accuracy evaluation without a human reference.
"""
from __future__ import annotations

import argparse
import json
import platform
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,required=True)
    parser.add_argument("--model",default="small")
    parser.add_argument("--offset",type=float,default=0)
    parser.add_argument("--duration",type=float,default=45)
    parser.add_argument("--threads",type=int,default=4)
    parser.add_argument("--beam",type=int,default=5)
    parser.add_argument("--vad",action="store_true")
    parser.add_argument("--diarize",action="store_true")
    args = parser.parse_args()
    if not 0 < args.duration <= 300 or args.offset < 0 or not 1 <= args.threads <= 16:
        parser.error("Use a 1–300 second local excerpt and 1–16 threads")
    from audio_preview import decode_slice
    from faster_whisper import WhisperModel
    from meeting_transcriber_v25_1 import decode_to_wav16k
    with tempfile.TemporaryDirectory(prefix="slavator-benchmark-") as folder:
        clip, wav = Path(folder)/"clip.wav",Path(folder)/"input.wav"
        decode_slice(args.input,clip,args.offset,args.offset+args.duration)
        duration = decode_to_wav16k(clip,wav)
        started = time.perf_counter()
        model = WhisperModel(args.model,device="cpu",compute_type="int8",
                             cpu_threads=args.threads,num_workers=1,local_files_only=True)
        loaded = time.perf_counter()
        segments,_ = model.transcribe(str(wav),language="ru",beam_size=args.beam,
            word_timestamps=True,condition_on_previous_text=False,vad_filter=args.vad)
        rows = list(segments)
        ended = time.perf_counter()
        speech = sum(max(0,r.end-r.start) for r in rows)
        report = dict(model=args.model,device="cpu",compute="int8",threads=args.threads,
            beam=args.beam,vad=args.vad,audio_seconds=round(duration,3),
            load_seconds=round(loaded-started,3),asr_seconds=round(ended-loaded,3),
            rtf=round((ended-loaded)/duration,3),segments=len(rows),
            words=sum(len(r.words or []) for r in rows),segment_coverage_seconds=round(speech,3),
            architecture=platform.machine(),system=platform.system(),accuracy="not_measured")
        # Release ASR before testing diarization; no two big models are needed.
        del model
        if args.diarize:
            import onnx_engine
            if onnx_engine.missing(onnx_engine.DIARIZATION_MODELS):
                raise RuntimeError("Diarization models must be provisioned offline first")
            t = time.perf_counter()
            turns = onnx_engine.diarize(wav,threshold=.62)
            report.update(diarization_seconds=round(time.perf_counter()-t,3),voices=len({r["speaker"] for r in turns}))
        try:
            import resource
            rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            report["peak_rss_mib"] = round(rss/(1024**2 if platform.system()=="Darwin" else 1024),1)
        except ImportError:
            report["peak_rss_mib"] = None
            report["memory_note"] = "Measure peak working set externally on Windows"
        print(json.dumps(report,ensure_ascii=False))


if __name__ == "__main__":
    main()
