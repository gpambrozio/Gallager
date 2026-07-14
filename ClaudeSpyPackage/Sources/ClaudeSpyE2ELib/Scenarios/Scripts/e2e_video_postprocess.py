#!/usr/bin/env python3
"""Post-process a raw E2E scenario screen recording into the published artifact.

Pipeline (issue #621):
  1. Detect static spans with ffmpeg freezedetect (noise tolerance absorbs
     cursor blink / antialiasing shimmer).
  2. Burn labels FIRST, on the 1x timeline: an ASS step-caption ribbon built
     from timeline.json plus a drawtext timecode of real elapsed time since
     test start — so both stay truthful after retiming.
  3. Retime: speed up static spans (default 8x, with a visible ">> 8x"
     indicator) or remove them (--mode remove keeps the first 0.25s of each).
  4. Write video.mp4 + video.json (published duration and per-step seek
     offsets remapped through the edit list) next to the raw take, deleting
     the raw take unless --keep-raw.

Requires ffmpeg + ffprobe with the freezedetect, ass, and drawtext filters.
Homebrew's slim `ffmpeg` formula dropped drawtext (libfreetype) and ass
(libass), so install `ffmpeg-full` (keg-only; put `$(brew --prefix
ffmpeg-full)/bin` on PATH). Python stdlib only. Unit tests:
scripts/tests/test_e2e_video_postprocess.py.
"""
import argparse
import json
import os
import re
import subprocess
import sys

FREEZE_START_RE = re.compile(r"freeze_start:\s*([0-9.]+)")
FREEZE_END_RE = re.compile(r"freeze_end:\s*([0-9.]+)")
FONT = "fontfile=/System/Library/Fonts/Menlo.ttc"


# ---------------------------------------------------------------- pure logic

def parse_freezedetect(stderr_text, duration):
    """Return [(start, end)] freeze spans parsed from ffmpeg's freezedetect
    stderr. An unclosed final span (video ends while frozen) extends to
    `duration`."""
    spans, start = [], None
    for line in stderr_text.splitlines():
        m = FREEZE_START_RE.search(line)
        if m:
            start = float(m.group(1))
            continue
        m = FREEZE_END_RE.search(line)
        if m and start is not None:
            spans.append((start, float(m.group(1))))
            start = None
    if start is not None and duration - start > 0.01:
        spans.append((start, duration))
    return spans


def build_edit_list(freezes, duration, mode="speedup", speedup=8.0,
                    keep_removed_head=0.25):
    """Return the retained edit list [(start, end, speed)] covering the take.

    speed == 1.0 plays in real time; > 1.0 is a sped-up span. In remove mode
    only the first `keep_removed_head` seconds of each frozen span are kept
    (at 1x) so the settled state stays visible; raw time not covered by any
    tuple is dropped entirely."""
    segments, cursor = [], 0.0
    for fs, fe in sorted(freezes):
        fs, fe = max(fs, 0.0), min(fe, duration)
        if fe <= cursor:
            continue
        fs = max(fs, cursor)
        if fs - cursor > 0.01:
            segments.append((cursor, fs, 1.0))
        if mode == "remove":
            head_end = min(fs + keep_removed_head, fe)
            if head_end - fs > 0.01:
                segments.append((fs, head_end, 1.0))
        else:
            segments.append((fs, fe, speedup))
        cursor = fe
    if duration - cursor > 0.01:
        segments.append((cursor, duration, 1.0))
    if not segments:
        # Degenerate take (entirely frozen + removed) — keep something playable.
        segments = [(0.0, min(duration, keep_removed_head), 1.0)]
    return segments


def remap_time(t, segments):
    """Map a raw-take timestamp to the published (retimed) timeline. A
    timestamp inside a dropped region maps to the cut point."""
    acc = 0.0
    for a, b, speed in segments:
        if t >= b:
            acc += (b - a) / speed
        elif t > a:
            return acc + (t - a) / speed
        else:
            break
    return acc


def published_duration(segments):
    return sum((b - a) / speed for a, b, speed in segments)


def ass_time(t):
    t = max(t, 0.0)
    hours = int(t // 3600)
    minutes = int(t % 3600 // 60)
    seconds = t % 60
    return f"{hours}:{minutes:02d}:{seconds:05.2f}"


def ass_escape(text):
    """Strip ASS control characters ({ } start override blocks) and newlines."""
    return (text.replace("\\", "")
            .replace("{", "(").replace("}", ")")
            .replace("\n", " "))


def build_ass(timeline, width, height, max_desc=90):
    """Build an ASS subtitle document with one bottom-ribbon Dialogue per step."""
    steps = timeline["steps"]
    total = len(steps)
    duration = timeline.get("duration") or 0.0
    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        f"PlayResX: {width}",
        f"PlayResY: {height}",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
        "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        "Style: Step,Menlo,22,&H00FFFFFF,&H000000FF,&H00000000,&H90000000,"
        "0,0,0,0,100,100,0,0,3,6,0,2,20,20,16,1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
        "Effect, Text",
    ]
    for i, step in enumerate(steps):
        start = step["start"]
        end = step.get("end")
        if end is None:
            end = steps[i + 1]["start"] if i + 1 < len(steps) else duration
        desc = ass_escape(step["description"])[:max_desc]
        marker = "[FAILED] " if step.get("status") == "failed" else ""
        text = f"{marker}Step {step['stepNumber']}/{total} — {desc}"
        lines.append(
            f"Dialogue: 0,{ass_time(start)},{ass_time(end)},Step,,0,0,0,,{text}"
        )
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------- ffmpeg

def run_checked(cmd, cwd):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"FAILED ({result.returncode}): {' '.join(cmd)}\n"
                 f"{result.stderr[-4000:]}")
    return result


def probe(raw, cwd):
    out = run_checked(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height:format=duration",
         "-of", "json", raw],
        cwd,
    ).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    return float(data["format"]["duration"]), int(stream["width"]), int(stream["height"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, help="Path to recording-raw.mov")
    parser.add_argument("--timeline", required=True, help="Path to timeline.json")
    parser.add_argument("--mode", choices=["speedup", "remove"], default="speedup")
    parser.add_argument("--speedup", type=float, default=8.0)
    parser.add_argument("--freeze-min", type=float, default=0.5,
                        help="Minimum static-span length to compress (seconds)")
    parser.add_argument("--freeze-noise", default="-60dB",
                        help="freezedetect noise tolerance (cursor blink/AA)")
    parser.add_argument("--keep-raw", action="store_true",
                        help="Keep recording-raw.mov after a successful encode")
    args = parser.parse_args()

    work_dir = os.path.dirname(os.path.abspath(args.raw))
    raw = os.path.basename(args.raw)
    with open(args.timeline) as f:
        timeline = json.load(f)

    duration, width, height = probe(raw, work_dir)

    # 1. Static-span detection.
    freeze_result = run_checked(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", raw,
         "-vf", f"freezedetect=n={args.freeze_noise}:d={args.freeze_min}",
         "-map", "0:v", "-f", "null", "-"],
        work_dir,
    )
    freezes = parse_freezedetect(freeze_result.stderr, duration)
    segments = build_edit_list(freezes, duration, mode=args.mode,
                               speedup=args.speedup)

    # 2. Burn labels on the 1x timeline (before any retiming, so the timecode
    #    keeps showing true wall-clock time inside compressed spans).
    with open(os.path.join(work_dir, "steps.ass"), "w") as f:
        f.write(build_ass(timeline, width, height))
    offset = -(timeline.get("testStartOffset") or 0.0)
    timecode = (f"drawtext={FONT}:fontsize=20:fontcolor=white:box=1:"
                "boxcolor=black@0.55:boxborderw=6:x=w-tw-14:y=12:"
                f"text='%{{pts\\:hms\\:{offset:.3f}}}'")
    run_checked(
        ["ffmpeg", "-y", "-hide_banner", "-i", raw,
         "-vf", f"ass=steps.ass,{timecode}",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "labeled.mov"],
        work_dir,
    )

    # 3. Retime through the edit list (trim/setpts per segment, concat).
    chains, labels = [], []
    for i, (a, b, speed) in enumerate(segments):
        chain = (f"[0:v]trim=start={a:.3f}:end={b:.3f},"
                 f"setpts=(PTS-STARTPTS)/{speed:g},fps=15")
        if speed > 1:
            chain += (f",drawtext={FONT}:fontsize=28:fontcolor=white:box=1:"
                      "boxcolor=black@0.55:boxborderw=6:x=14:y=12:"
                      f"text='>> {speed:g}x'")
        chains.append(chain + f"[v{i}]")
        labels.append(f"[v{i}]")
    graph = (";".join(chains) + ";" + "".join(labels)
             + f"concat=n={len(segments)}:v=1:a=0[out]")
    with open(os.path.join(work_dir, "retime-graph.txt"), "w") as f:
        f.write(graph)
    run_checked(
        ["ffmpeg", "-y", "-hide_banner", "-i", "labeled.mov",
         "-filter_complex_script", "retime-graph.txt", "-map", "[out]",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", "video.mp4"],
        work_dir,
    )

    # 4. Published metadata — seek chapters remapped through the edit list.
    video_json = {
        "mode": args.mode,
        "durationSeconds": round(published_duration(segments), 3),
        "rawDurationSeconds": round(duration, 3),
        "sizeBytes": os.path.getsize(os.path.join(work_dir, "video.mp4")),
        "steps": [
            {
                "stepNumber": s["stepNumber"],
                "description": s["description"],
                "status": s.get("status", "passed"),
                "start": round(remap_time(s["start"], segments), 3),
            }
            for s in timeline["steps"]
        ],
    }
    with open(os.path.join(work_dir, "video.json"), "w") as f:
        json.dump(video_json, f, indent=2)

    # 5. Cleanup.
    for name in ("steps.ass", "retime-graph.txt", "labeled.mov"):
        try:
            os.remove(os.path.join(work_dir, name))
        except FileNotFoundError:
            pass
    if not args.keep_raw:
        os.remove(os.path.join(work_dir, raw))

    print(f"video.mp4: {video_json['sizeBytes']} bytes, "
          f"{video_json['durationSeconds']}s published / "
          f"{video_json['rawDurationSeconds']}s raw, "
          f"{len(freezes)} static span(s), "
          f"raw {'kept' if args.keep_raw else 'deleted'}")


if __name__ == "__main__":
    main()
