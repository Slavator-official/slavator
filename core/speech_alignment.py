"""Assign word-timed text to voices without inventing distant speaker matches."""
from __future__ import annotations

from bisect import bisect_left, bisect_right
from dataclasses import replace
import math


def align_utterances(utterances, turns):
    ordered = sorted((t for t in turns if math.isfinite(t["start"] + t["end"])
                      and t["end"] > t["start"]), key=lambda t:t["start"])
    starts = [t["start"] for t in ordered]
    max_ends = []
    for turn in ordered:
        max_ends.append(max(turn["end"],max_ends[-1] if max_ends else -1))

    def voice(start,end):
        duration = max(end-start,0.001)
        left,right = bisect_right(max_ends,start),bisect_left(starts,end)
        spans = {}
        for turn in ordered[left:right]:
            spans.setdefault(turn["speaker"],[]).append((max(start,turn["start"]),min(end,turn["end"])))
        totals = {}
        for speaker, intervals in spans.items():
            # Duplicate overlapping turns must not count the same time twice.
            merged = []
            for a,b in sorted(intervals):
                if merged and a <= merged[-1][1]:
                    merged[-1] = (merged[-1][0],max(b,merged[-1][1]))
                else:
                    merged.append((a,b))
            totals[speaker] = sum(b-a for a,b in merged)
        ranks = sorted(totals.items(),key=lambda x:(-x[1],x[0]))
        if not ranks or ranks[0][1]/duration < .5:
            return ""
        if len(ranks)>1 and (ranks[0][1]-ranks[1][1])/duration < .10:
            return ""  # Overlap/tie is not evidence of a particular speaker.
        return ranks[0][0]

    result = []
    for number,item in enumerate(utterances):
        words = getattr(item,"words",[])
        usable = bool(words) and all(isinstance(w,dict) and isinstance(w.get("word"),str)
            and isinstance(w.get("start"),(int,float)) and isinstance(w.get("end"),(int,float))
            and math.isfinite(w["start"]+w["end"]) and w["end"]>=w["start"] for w in words)
        if not usable:
            speaker = voice(item.start,item.end)
            item.speaker_id = speaker or f"UNASSIGNED_{number}"
            if not speaker:
                item.speaker_name = "Голос не определён"
            result.append(item)
            continue
        groups = []
        for word in words:
            speaker = voice(word["start"],word["end"])
            if groups and groups[-1][0] == speaker:
                groups[-1][1].append(word)
            else:
                groups.append((speaker,[word]))
        for part,(speaker,chunk) in enumerate(groups):
            text = item.text if len(groups)==1 else "".join(w["word"] for w in chunk).strip()
            if not text:
                continue
            result.append(replace(item,start=chunk[0]["start"],end=chunk[-1]["end"],text=text,words=chunk,
                speaker_id=speaker or f"UNASSIGNED_{number}_{part}",speaker_name="" if speaker else "Голос не определён"))
    return result
