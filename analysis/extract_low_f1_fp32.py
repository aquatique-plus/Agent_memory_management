#!/usr/bin/env python3
"""Pull the low-scoring QA pairs out of a LoCoMo test QA dump.

Default: the fp32 Memory-R2 run, keeping rows with F1 <= 0.2 and BLEU-1 <= 0.2.
Writes <out_prefix>.jsonl (all kept rows, lowest first) and <out_prefix>.md (readable, by category).

Usage:
  python analysis/extract_low_f1_fp32.py [--run RUN] [--thr 0.2] [--out_prefix analysis/low_f1_fp32]
"""

import argparse
import collections
import glob
import json
import os

DUMPS = "/gpfs/radev/home/wf287/scratch/memory_r2/qa_dumps"
# LoCoMo category ids as used by the Memory-R1 / mem0 evals.
CATEGORY = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="memr2_paper_fp32_len1024_20261014_135814")
    ap.add_argument("--thr", type=float, default=0.2)
    ap.add_argument("--out_prefix", default=os.path.join(os.path.dirname(__file__), "low_f1_fp32"))
    args = ap.parse_args()

    files = glob.glob(f"{DUMPS}/{args.run}/test/step_unknown/*.jsonl")
    rows = [json.loads(line) for f in files for line in open(f)]
    low = [r for r in rows if r["f1"] <= args.thr and r["bleu"] <= args.thr]
    low.sort(key=lambda r: (r["f1"], r["bleu"], r["category"], r["conv_id"], r["qa_idx"]))

    with open(args.out_prefix + ".jsonl", "w") as f:
        for r in low:
            r = dict(r, category_name=CATEGORY.get(r["category"], str(r["category"])))
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    by_cat_all = collections.Counter(r["category"] for r in rows)
    by_cat_low = collections.Counter(r["category"] for r in low)
    by_cat_zero = collections.Counter(r["category"] for r in low if r["f1"] == 0)
    with open(args.out_prefix + ".md", "w") as f:
        f.write(f"# Low F1 / BLEU-1 QA pairs: {args.run}\n\n")
        f.write(f"Kept F1 <= {args.thr} and BLEU-1 <= {args.thr}: {len(low)} / {len(rows)} "
                f"({sum(r['f1'] == 0 for r in low)} with F1 = 0).\n\n")
        f.write("| category | total | low | F1 = 0 |\n|---|---|---|---|\n")
        for c in sorted(by_cat_all):
            f.write(f"| {c} {CATEGORY.get(c, '')} | {by_cat_all[c]} | {by_cat_low[c]} | {by_cat_zero[c]} |\n")
        for c in sorted(by_cat_all):
            group = [r for r in low if r["category"] == c]
            f.write(f"\n## Category {c}: {CATEGORY.get(c, '')} ({len(group)})\n\n")
            f.write("| F1 | B1 | conv | question | gold | predicted |\n|---|---|---|---|---|---|\n")
            for r in group:
                cells = [f"{r['f1']:.2f}", f"{r['bleu']:.2f}", f"{r['conv_id']}#{r['qa_idx']}",
                         r["question"], str(r["gold_answer"]), r["predicted_answer"]]
                f.write("| " + " | ".join(str(x).replace("|", "\\|").replace("\n", " ") for x in cells) + " |\n")

    print(f"{len(low)} / {len(rows)} rows -> {args.out_prefix}.jsonl, {args.out_prefix}.md")


if __name__ == "__main__":
    main()
