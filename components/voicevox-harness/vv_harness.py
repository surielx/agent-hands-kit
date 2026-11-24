# VOICEVOX harness: synthesize Japanese speech via the VOICEVOX engine API,
# with a readable accent/pitch plan, guard-rule prosody fixes, and an
# F0-based verification report on the produced WAV.
# Engine: http://127.0.0.1:50021 (started automatically if not running).
import argparse, json, math, os, re, subprocess, sys, time
import urllib.request, urllib.parse

import numpy as np
import soundfile as sf

BASE = "http://127.0.0.1:50021"
ENGINE_EXE = os.path.expandvars(r"%LOCALAPPDATA%\Programs\VOICEVOX\run.exe")

# ---------- engine ----------
def http_get(path, timeout=15):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return r.read()

def http_post(path, params=None, body=None, timeout=60):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data, headers = None, {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def ensure_engine():
    try:
        http_get("/version", timeout=3)
        return "already-running"
    except Exception:
        pass
    if not os.path.exists(ENGINE_EXE):
        raise RuntimeError(f"engine exe not found: {ENGINE_EXE}")
    subprocess.Popen([ENGINE_EXE, "--host", "127.0.0.1", "--port", "50021"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     creationflags=0x08000000)  # CREATE_NO_WINDOW
    for _ in range(60):
        try:
            http_get("/version", timeout=3)
            return "started"
        except Exception:
            time.sleep(0.5)
    raise RuntimeError("engine did not become ready in 30s")

# ---------- query handling ----------
def split_sentences(text, mode="all"):
    pat = r"(?<=[。！])" if mode == "period" else r"(?<=[。！？])"
    parts = re.split(pat, text.strip())
    return [p for p in (s.strip() for s in parts) if p]

def voiced(mora):
    return mora.get("pitch", 0.0) > 0.0

def plan_lines(query):
    lines = []
    for i, ph in enumerate(query["accent_phrases"]):
        kana = "".join(m["text"] for m in ph["moras"])
        pitches = [round(m["pitch"], 2) for m in ph["moras"]]
        lines.append(f"  phrase{i}: {kana} accent={ph['accent']} pitch={pitches}"
                     + (" pause" if ph.get("pause_mora") else ""))
    return lines

def apply_rules(query, sentence):
    """Guard rules: only fire on clear prosody defects. Returns list of fix notes."""
    notes = []
    phrases = query["accent_phrases"]
    if not phrases:
        return notes
    is_question = sentence.rstrip().endswith(("？", "?"))
    last = phrases[-1]
    last_voiced = [m for m in last["moras"] if voiced(m)]
    if not last_voiced:
        return notes
    if is_question:
        # Gentle nudge only (opt-in via --rules). A/B verdict 2026-11-25:
        # raising the final mora to the phrase peak sounded unnatural;
        # the engine's native falling target is realized naturally.
        peak = max(m["pitch"] for m in last["moras"] if voiced(m))
        fin = last_voiced[-1]
        if fin["pitch"] < peak - 0.05:
            old = fin["pitch"]
            fin["pitch"] = min(peak - 0.08, old + 0.06)
            notes.append(f"question-rise(soft): last phrase final mora pitch {old:.2f} -> {fin['pitch']:.2f} (peak {peak:.2f})")
    else:
        peak = max(m["pitch"] for m in last["moras"] if voiced(m))
        fin = last_voiced[-1]
        if fin["pitch"] > peak - 0.03 and len(last_voiced) >= 2:
            old = fin["pitch"]
            fin["pitch"] = peak - 0.12
            notes.append(f"final-fall: last phrase final mora pitch {old:.2f} -> {fin['pitch']:.2f} (peak {peak:.2f})")
    return notes

def mora_timeline(query):
    """Return list of (start, end, text) per mora using query lengths."""
    t = query.get("prePhonemeLength", 0.1)
    out = []
    speed = query.get("speedScale", 1.0) or 1.0
    for ph in query["accent_phrases"]:
        for m in ph["moras"]:
            dur = ((m.get("consonant_length") or 0.0) + (m.get("vowel_length") or 0.0)) / speed
            out.append((t, t + dur, m["text"]))
            t += dur
        if ph.get("pause_mora"):
            pm = ph["pause_mora"]
            dur = ((pm.get("consonant_length") or 0.0) + (pm.get("vowel_length") or 0.0)) / speed
            t += dur
    return out, t + query.get("postPhonemeLength", 0.1)

# ---------- F0 verification ----------
def f0_track(wav, sr, fmin=50.0, fmax=600.0):
    frame = int(sr * 0.03)
    hop = int(sr * 0.01)
    times, f0s = [], []
    minlag, maxlag = int(sr / fmax), int(sr / fmin)
    for start in range(0, max(1, len(wav) - frame), hop):
        seg = wav[start:start + frame].astype(np.float64)
        seg = seg - seg.mean()
        if np.sqrt((seg ** 2).mean()) < 0.01:
            times.append(start / sr); f0s.append(0.0); continue
        ac = np.correlate(seg, seg, "full")[len(seg) - 1:]
        if ac[0] <= 0:
            times.append(start / sr); f0s.append(0.0); continue
        hi = min(maxlag, len(ac) - 1)
        lag = int(np.argmax(ac[minlag:hi])) + minlag
        peak = ac[lag] / ac[0]
        f0s.append(sr / lag if peak > 0.55 and lag < len(ac) else 0.0)
        times.append(start / sr)
    return np.array(times), np.array(f0s)

def verify(wav, sr, queries):
    """Per-phrase first/last voiced-mora median F0 (Hz) and trend flags."""
    times, f0s = f0_track(wav, sr)
    report, offset = [], 0.0
    for qi, q in enumerate(queries):
        timeline, total = mora_timeline(q)
        idx = 0
        for pi, ph in enumerate(q["accent_phrases"]):
            moras = ph["moras"]
            vals = []
            for m in moras:
                s, e, _ = timeline[idx]; idx += 1
                sel = f0s[(times >= offset + s) & (times < offset + e)]
                sel = sel[sel > 0]
                vals.append(float(np.median(sel)) if len(sel) else 0.0)
            voiced_vals = [v for v in vals if v > 0]
            if len(voiced_vals) >= 2:
                first, lastv = voiced_vals[0], voiced_vals[-1]
                trend = "-> flat"
                if lastv > first * 1.08: trend = "-> RISE"
                elif lastv < first * 0.92: trend = "-> fall"
                report.append(f"  sent{qi} phrase{pi}: first={first:.0f}Hz last={lastv:.0f}Hz {trend}")
            if ph.get("pause_mora"):
                idx += 0  # pause mora not in timeline list
        offset += total + 0.35  # inter-sentence silence added at concat
    return report

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default=None)
    ap.add_argument("--text-file", default=None, help="UTF-8 file containing the text (avoids shell encoding issues)")
    ap.add_argument("--speaker", type=int, default=10, help="VOICEVOX style id (default 10 = Amahare Hau, normal)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--rules", action="store_true",
                    help="apply guard-rule prosody edits (default OFF: native engine prosody won the user's A/B check)")
    ap.add_argument("--split-mode", choices=["all", "period"], default="all",
                    help="all: split at 。！？ / period: split only at 。！ (editor-style)")
    ap.add_argument("--speed", type=float, default=1.0)
    args = ap.parse_args()

    if args.text_file:
        with open(args.text_file, encoding="utf-8") as f:
            args.text = f.read().strip()
    if not args.text:
        print("VV_FAILED no text given")
        sys.exit(1)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    state = ensure_engine()
    print(f"ENGINE {state}", flush=True)

    sentences = split_sentences(args.text, args.split_mode)
    queries, wavs = [], []
    sr_out = 24000
    for s in sentences:
        q = json.loads(http_post("/audio_query", params={"text": s, "speaker": args.speaker}).decode("utf-8"))
        q["speedScale"] = args.speed
        print(f"SENTENCE: {s}")
        for line in plan_lines(q):
            print(line)
        if args.rules:
            for note in apply_rules(q, s):
                print(f"  FIX {note}")
        wav_bytes = http_post("/synthesis", params={"speaker": args.speaker}, body=q)
        path_tmp = args.out + ".part.wav"
        with open(path_tmp, "wb") as f:
            f.write(wav_bytes)
        data, sr_out = sf.read(path_tmp)
        os.remove(path_tmp)
        queries.append(q)
        wavs.append(data.astype(np.float32))
        print(f"  synth ok dur={len(data)/sr_out:.2f}s", flush=True)

    silence = np.zeros(int(sr_out * 0.35), dtype=np.float32)
    joined = []
    for i, w in enumerate(wavs):
        if i:
            joined.append(silence)
        joined.append(w)
    full = np.concatenate(joined) if joined else np.zeros(1, dtype=np.float32)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    sf.write(args.out, full, sr_out)
    print(f"WROTE {args.out} dur={len(full)/sr_out:.2f}s sr={sr_out}")

    print("VERIFY (measured F0 of output):")
    for line in verify(full, sr_out, queries):
        print(line)
    print(f"VV_OK {args.out}")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"VV_FAILED {e}")
        sys.exit(1)
