"""Re-run fact extraction on the gold evidence turns of wrong LoCoMo QAs with an off-the-shelf model.

For every wrong QA in wrong_qa_retrieval.jsonl, the gold evidence dialogue turns (dataset `evidence`,
not retrieved memories) are grouped by session and sent to the model with exactly the extractor
prompt used in Memory-R2 training/test:
  system = prompt.math.multi_turn_mamrp.MEMORY_REASONER_PROMPT
  user   = vLLMRollout.generate_fact_prompts(...)  (first sub-turn form, no "Previous session" prefix)
Decoding is greedy, matching the test-time rollout (val_kwargs.temperature=0).

Outputs (in --out_dir):
  <name>.jsonl  one record per wrong QA with raw model outputs and parsed facts
  <name>.md     per QA: question, gold, pred, evidence text, extracted facts
"""
import argparse
import json
import os
import sys
from collections import defaultdict

REPO_SRC = "/gpfs/radev/project/q_chen/wf287/memory_r2/src"
sys.path[:0] = [REPO_SRC, os.path.join(REPO_SRC, "src", "verl")]

from prompt.math.multi_turn_mamrp import MEMORY_REASONER_PROMPT  # noqa: E402
from verl.rema_trainer.memory.utils.parse_response import extract_llm_json_from_response  # noqa: E402


def dia_key(dia_id):
    sess, turn = dia_id.strip().lstrip("D").split(":")
    return int(sess), int(turn)


def load_turn_index(locomo_path):
    """(conv_id, dia_id) -> raw LoCoMo turn dict (keeps img_url / blip_caption)."""
    index = {}
    for conv in json.load(open(locomo_path)):
        conversation = conv["conversation"]
        for key, turns in conversation.items():
            if not key.startswith("session_") or key.endswith("date_time") or not isinstance(turns, list):
                continue
            for t in turns:
                index[(conv["sample_id"], t["dia_id"])] = t
    return index


def build_requests(rows, turn_index):
    """One extraction request per (QA, session); evidence turns sorted by dia_id."""
    requests = []
    for row in rows:
        by_session = defaultdict(list)
        for ev in row["evidence"]:
            turn = turn_index.get((row["conv_id"], ev["dia_id"]))
            if turn is None:  # dataset evidence id that does not exist in the conversation (e.g. "D")
                continue
            by_session[dia_key(ev["dia_id"])[0]].append(turn)
        row["_sessions"] = []
        for sess in sorted(by_session):
            turns = sorted(by_session[sess], key=lambda t: dia_key(t["dia_id"]))
            row["_sessions"].append(sess)
            requests.append((row, sess, turns))
    return requests


def fact_user_prompt(turns):
    # Same template + turn formatting as training (vllm_rollout_spmd.py: generate_fact_prompts).
    from verl.workers.rollout.vllm_rollout.vllm_rollout_spmd import vLLMRollout
    return vLLMRollout.generate_fact_prompts(None, [turns])[0]


def parse_facts(text):
    parsed = extract_llm_json_from_response(text)
    if not parsed.get("_parse_success", False):
        return None
    facts = parsed.get("facts", [])
    return facts if isinstance(facts, list) else None


def build_conv_memory_index(rows):
    """(conv_id, dia_id) -> {(content, session_time): entry}, union of retrieved memories over all
    wrong QAs of the same conversation (same eval run, so the same final memory bank)."""
    index = defaultdict(dict)
    for row in rows:
        for mems in row["retrieved_memories"].values():
            for m in mems:
                for d in m.get("dia_ids", []):
                    index[(row["conv_id"], d)].setdefault((m["content"], m["session_time"]), m)
    return index


def memr2_evidence_memories(row, conv_index):
    """dia_id -> (status, [(entry, similarity in this QA or None)]) from the Memory-R2 wrong-QA dump.

    Entries come from the conversation-level union, so an entry retrieved only for another QA
    still shows up (similarity None). Evidence in the bank that no wrong QA ever retrieved has no
    content in the dump and is listed by status only.
    """
    here = {}
    for mems in row["retrieved_memories"].values():
        for m in mems:
            here.setdefault((m["content"], m["session_time"]), m["similarity"])
    out = {}
    for ev in row["evidence"]:
        d = ev["dia_id"]
        entries = [(m, here.get(k)) for k, m in conv_index.get((row["conv_id"], d), {}).items()]
        entries.sort(key=lambda e: e[1] is None)
        if any(sim is not None for _, sim in entries):
            status = "retrieved"
        elif entries:
            status = "in bank, retrieved only for other QAs"
        elif d in row.get("evidence_in_bank", []):
            status = "in bank, content unknown (never retrieved)"
        else:
            status = "not in bank"
        out[d] = (status, entries)
    return out


def write_markdown(rows, path, model):
    n_fail = sum(1 for r in rows for s in r["extraction"] if s["facts"] is None)
    n_empty = sum(1 for r in rows if all(not s["facts"] for s in r["extraction"]))
    conv_index = build_conv_memory_index(rows)
    memr2 = [memr2_evidence_memories(r, conv_index) for r in rows]
    status_count = defaultdict(int)
    for m in memr2:
        for status, _ in m.values():
            status_count[status] += 1
    with open(path, "w") as f:
        f.write(f"# Fact extraction on gold evidence — {model}\n\n")
        f.write(
            "Gold evidence turns of each wrong QA are fed directly to the model with the Memory-R2 extractor "
            "prompt (system `MEMORY_REASONER_PROMPT` + `generate_fact_prompts` user template), one call per "
            "session, greedy decoding.\n\n"
        )
        f.write(
            "Memory-R2 side comes from `wrong_qa_retrieval.jsonl`: for each evidence turn, every memory entry "
            "whose `dia_ids` include it, collected from the retrievals of all wrong QAs of the same conversation. "
            "`[sim]` = retrieved for this QA (similarity); `[other QA]` = in the bank but only retrieved for "
            "another QA. Evidence in the bank that no wrong QA retrieved has no content in the dump.\n\n"
        )
        f.write(f"- wrong QAs: {len(rows)}\n- QAs with no fact extracted at all: {n_empty}\n"
                f"- extraction calls with unparsable JSON: {n_fail}\n"
                f"- Memory-R2 evidence turns: " + ", ".join(f"{k}: {v}" for k, v in sorted(status_count.items())) + "\n\n")
        for i, (r, mem) in enumerate(zip(rows, memr2), 1):
            f.write(f"## {i}. [{r['conv_id']} #{r['qa_idx']}] ({r['category']}) {r['question']}\n\n")
            f.write(f"- gold: {r['gold_answer']}\n- pred: {r['predicted_answer']}\n\n")
            f.write("**Evidence 原文**\n\n")
            for ev in r["evidence"]:
                f.write(f"- `{ev['dia_id']}` ({ev.get('session_time', '?')}) {ev.get('speaker', '?')}: {ev['text']}\n")
            f.write(f"\n**{model.split('/')[-1]} extracted facts**\n\n")
            if not r["extraction"]:
                f.write("- (no valid evidence turn to extract from)\n")
            multi = len(r["extraction"]) > 1
            for s in r["extraction"]:
                if multi:
                    f.write(f"- session {s['session']} ({', '.join(s['dia_ids'])}):\n")
                ind = "    - " if multi else "- "
                if s["facts"] is None:
                    f.write(f"{ind}JSON parse failed, raw output:\n\n```\n{s['raw'].strip()}\n```\n")
                elif not s["facts"]:
                    f.write(f"{ind}(no facts)\n")
                else:
                    for fact in s["facts"]:
                        if isinstance(fact, dict):
                            f.write(f"{ind}`{fact.get('dia_id', '?')}` {fact.get('fact', json.dumps(fact, ensure_ascii=False))}\n")
                        else:
                            f.write(f"{ind}{fact}\n")
            f.write("\n**Memory-R2 memory (evidence-linked)**\n\n")
            for d, (status, entries) in mem.items():
                if not entries:
                    f.write(f"- `{d}` ({status})\n")
                for m, sim in entries:
                    tag = sim if sim is not None else "other QA"
                    f.write(f"- `{d}` [{tag}] ({m['session_time']}) {m['content']}\n")
            f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wrong_qa", default="/gpfs/radev/home/wf287/project/memory_r2/analysis/wrong_qa/wrong_qa_retrieval.jsonl")
    ap.add_argument("--locomo", default=os.path.join(REPO_SRC, "data/locomo/locomo10.json"))
    ap.add_argument("--model", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--out_dir", default="/gpfs/radev/home/wf287/project/memory_r2/analysis/wrong_qa")
    ap.add_argument("--name", default="wrong_qa_qwen2.5-7b_fact_extraction")
    ap.add_argument("--max_tokens", type=int, default=4096)
    ap.add_argument("--limit", type=int, default=0, help="only the first N wrong QAs (debug)")
    ap.add_argument("--render_only", action="store_true",
                    help="skip generation; rebuild the .md from the existing <name>.jsonl")
    args = ap.parse_args()

    rows = [json.loads(l) for l in open(args.wrong_qa)]
    if args.limit:
        rows = rows[: args.limit]
    md_path = os.path.join(args.out_dir, args.name + ".md")
    jsonl_path = os.path.join(args.out_dir, args.name + ".jsonl")

    if args.render_only:
        saved = {(s["conv_id"], s["qa_idx"]): s for s in map(json.loads, open(jsonl_path))}
        for r in rows:
            r["extraction"] = saved[(r["conv_id"], r["qa_idx"])]["extraction"]
        write_markdown(rows, md_path, args.model)
        print(f"[qwen_fact_extraction] wrote {md_path}")
        return

    from vllm import LLM, SamplingParams
    requests = build_requests(rows, load_turn_index(args.locomo))

    llm = LLM(model=args.model, dtype="bfloat16", max_model_len=32768, seed=0)
    tokenizer = llm.get_tokenizer()

    # Identical prompts (QAs sharing the same evidence) are generated once.
    prompt_of = []
    unique = {}
    for _, _, turns in requests:
        chat = [{"role": "system", "content": MEMORY_REASONER_PROMPT},
                {"role": "user", "content": fact_user_prompt(turns)}]
        text = tokenizer.apply_chat_template(chat, add_generation_prompt=True, tokenize=False)
        unique.setdefault(text, len(unique))
        prompt_of.append(text)
    sampling = SamplingParams(temperature=0, top_p=1.0, top_k=-1, max_tokens=args.max_tokens)
    outputs = llm.generate(list(unique), sampling)
    raw_by_prompt = {p: o.outputs[0].text for p, o in zip(unique, outputs)}
    print(f"[qwen_fact_extraction] {len(rows)} QAs, {len(requests)} session calls, {len(unique)} unique prompts")

    for r in rows:
        r["extraction"] = []
    for (row, sess, turns), text in zip(requests, prompt_of):
        raw = raw_by_prompt[text]
        row["extraction"].append({
            "session": sess,
            "dia_ids": [t["dia_id"] for t in turns],
            "raw": raw,
            "facts": parse_facts(raw),
        })

    os.makedirs(args.out_dir, exist_ok=True)
    with open(jsonl_path, "w") as f:
        for r in rows:
            rec = {k: r[k] for k in ("conv_id", "qa_idx", "category", "question", "gold_answer",
                                     "predicted_answer", "f1", "evidence", "extraction")}
            rec["model"] = args.model
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    write_markdown(rows, md_path, args.model)
    print(f"[qwen_fact_extraction] wrote {jsonl_path}\n[qwen_fact_extraction] wrote {md_path}")


if __name__ == "__main__":
    main()
