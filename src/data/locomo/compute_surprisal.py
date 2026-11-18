"""Per-turn surprisal of LoCoMo dialogue turns and surprisal-based segmentation of each session.

Step 1 (--stage surprisal, needs a GPU): every session is rendered as plain text
    "Conversation on <session_time>\n<speaker>: <text>\n..."  (image captions appended as in
    format_turns_for_prompt) and run through a frozen causal LM in one teacher-forced forward.
    A dialogue turn's surprisal is the sum of -log p(token | everything before it in the session),
    in nats, over that turn's own tokens. Output: <out_dir>/surprisal.json.

Step 2 (--stage segments, CPU): tau = mean surprisal of a rollout turn under the current fixed split
    (ceil(n_turns / max_num_turns) dialogue turns per rollout turn, as in vllm_rollout_spmd.py),
    averaged over the train conversations. Each session is then cut greedily: accumulate turn
    surprisal and close a segment after the turn where the sum reaches tau. A tail below
    min_tail_frac * tau joins the previous segment; segments beyond max_segments are merged into the
    last one. Output: <out_dir>/segments.json with tau, stats and [start, end) bounds per session.

data_preprocess.py --segments_file <out_dir>/segments.json then stores the bounds per chunk
(column segment_bounds_json).
"""
import argparse
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_preprocess import TRAIN_IDS, flatten_conversation  # noqa: E402

INPUT_JSON = Path(__file__).resolve().parent / "locomo10.json"


def session_key(sample_id, session_id):
    return f"{sample_id}|{session_id}"


def load_sessions(path=INPUT_JSON):
    """Ordered dict-like list of (sample_id, session_id, turns) in the order data_preprocess sees them."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    sessions = []
    for conv_idx, conv in enumerate(data):
        sample_id = conv.get("sample_id", f"conv-{conv_idx}")
        by_sess = defaultdict(list)
        for t in flatten_conversation(conv["conversation"]):
            by_sess[t["session_id"]].append(t)
        for sid in sorted(by_sess):
            sessions.append((sample_id, sid, by_sess[sid]))
    return sessions


def turn_text(turn):
    text = turn.get("text", "")
    if turn.get("blip_caption"):
        text = f"{text} [Sent an image showing {turn['blip_caption']}]"
    return f"{turn.get('speaker', 'Unknown')}: {text}\n"


def compute_surprisal(args):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(
        args.model, torch_dtype=torch.bfloat16, attn_implementation="sdpa"
    ).cuda().eval()

    sessions = load_sessions()
    out = {"model": args.model, "unit": "nats", "sessions": {}}
    n_fwd = n_tok = 0
    for sample_id, sid, turns in sessions:
        header = f"Conversation on {turns[0].get('session_time') or 'unknown date'}\n"
        ids = tok(header, add_special_tokens=False)["input_ids"]
        spans = []
        for t in turns:
            piece = tok(turn_text(t), add_special_tokens=False)["input_ids"]
            spans.append((len(ids), len(ids) + len(piece)))
            ids.extend(piece)
        x = torch.tensor([ids], device="cuda")
        with torch.no_grad():
            logits = model(x).logits[0].float()
        # token i is predicted from position i-1
        logp = torch.log_softmax(logits[:-1], dim=-1).gather(1, x[0, 1:, None])[:, 0]
        nll = (-logp).cpu().tolist()
        surp = [sum(nll[s - 1:e - 1]) for s, e in spans]
        out["sessions"][session_key(sample_id, sid)] = {
            "sample_id": sample_id,
            "session_id": sid,
            "dia_ids": [t.get("dia_id") for t in turns],
            "n_tokens": [e - s for s, e in spans],
            "surprisal": surp,
        }
        n_fwd += 1
        n_tok += len(ids)
    out["n_forward"] = n_fwd
    out["n_tokens_total"] = n_tok
    path = Path(args.out_dir) / "surprisal.json"
    path.write_text(json.dumps(out, indent=1))
    print(f"[surprisal] {n_fwd} forwards, {n_tok} tokens -> {path}")


def fixed_chunks(n, k):
    size = (n + k - 1) // k
    return [(s, min(s + size, n)) for s in range(0, n, size)]


def segment(surp, tau, min_tail_frac, max_segments):
    bounds, start, acc = [], 0, 0.0
    for i, s in enumerate(surp):
        acc += s
        if acc >= tau:
            bounds.append([start, i + 1])
            start, acc = i + 1, 0.0
    if start < len(surp):
        if bounds and acc < min_tail_frac * tau:
            bounds[-1][1] = len(surp)
        else:
            bounds.append([start, len(surp)])
    if max_segments and len(bounds) > max_segments:
        bounds = bounds[:max_segments - 1] + [[bounds[max_segments - 1][0], len(surp)]]
    return bounds


def describe(xs):
    return {"mean": statistics.mean(xs), "median": statistics.median(xs), "min": min(xs), "max": max(xs)}


def compute_segments(args):
    data = json.loads((Path(args.out_dir) / "surprisal.json").read_text())
    sess = data["sessions"]
    train_ids = set(args.train_ids or TRAIN_IDS)

    def chunk_sums(keys):
        sums = []
        for k in keys:
            s = sess[k]["surprisal"]
            sums += [sum(s[a:b]) for a, b in fixed_chunks(len(s), args.max_num_turns)]
        return sums

    train_keys = [k for k, v in sess.items() if v["sample_id"] in train_ids
                  and (args.max_sessions is None or v["session_id"] <= args.max_sessions)]
    tau = statistics.mean(chunk_sums(train_keys))
    tau_all = statistics.mean(chunk_sums(list(sess)))

    out = {"model": data["model"], "tau": tau, "tau_all_convs": tau_all,
           "max_num_turns_ref": args.max_num_turns, "min_tail_frac": args.min_tail_frac,
           "max_segments": args.max_segments, "train_ids": sorted(train_ids),
           "max_sessions": args.max_sessions, "segments": {}}
    for k, v in sess.items():
        out["segments"][k] = segment(v["surprisal"], tau, args.min_tail_frac, args.max_segments)

    def split_stats(keys):
        nseg = [len(out["segments"][k]) for k in keys]
        seg_len = [b - a for k in keys for a, b in out["segments"][k]]
        seg_surp = [sum(sess[k]["surprisal"][a:b]) for k in keys for a, b in out["segments"][k]]
        seg_tok = [sum(sess[k]["n_tokens"][a:b]) for k in keys for a, b in out["segments"][k]]
        fixed_tok = [sum(sess[k]["n_tokens"][a:b]) for k in keys
                     for a, b in fixed_chunks(len(sess[k]["surprisal"]), args.max_num_turns)]
        return {
            "n_sessions": len(keys),
            "segments_per_session": describe(nseg),
            "segments_hist": dict(sorted(Counter(nseg).items())),
            "dialogue_turns_per_segment": describe(seg_len),
            "surprisal_per_segment": describe(seg_surp),
            "tokens_per_segment": describe(seg_tok),
            "tokens_per_fixed_chunk": describe(fixed_tok),
            "total_segments_vs_fixed": [sum(nseg), sum(len(fixed_chunks(len(sess[k]["surprisal"]), args.max_num_turns)) for k in keys)],
        }

    out["stats"] = {"train": split_stats(train_keys), "all": split_stats(list(sess))}
    turn_surp = [s for v in sess.values() for s in v["surprisal"]]
    tok_rate = sum(turn_surp) / sum(n for v in sess.values() for n in v["n_tokens"])
    out["stats"]["per_dialogue_turn_surprisal"] = describe(turn_surp)
    out["stats"]["nats_per_token"] = tok_rate

    path = Path(args.out_dir) / "segments.json"
    path.write_text(json.dumps(out, indent=1))
    print(json.dumps({k: out[k] for k in ("tau", "tau_all_convs")}, indent=1))
    print(json.dumps(out["stats"], indent=1))
    print(f"[segments] -> {path}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--stage", choices=["surprisal", "segments", "all"], default="all")
    p.add_argument("--model", default="Qwen/Qwen2.5-7B-Instruct")
    p.add_argument("--out_dir", default=str(Path(__file__).resolve().parent / "surprisal"))
    p.add_argument("--max_num_turns", type=int, default=4, help="fixed split that defines tau")
    p.add_argument("--max_sessions", type=int, default=None, help="only train sessions <= this id define tau")
    p.add_argument("--train_ids", nargs="*", default=None)
    p.add_argument("--min_tail_frac", type=float, default=0.5)
    p.add_argument("--max_segments", type=int, default=8)
    args = p.parse_args()
    Path(args.out_dir).mkdir(parents=True, exist_ok=True)
    if args.stage in ("surprisal", "all"):
        compute_surprisal(args)
    if args.stage in ("segments", "all"):
        compute_segments(args)


if __name__ == "__main__":
    main()
