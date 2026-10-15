#!/bin/bash
#SBATCH --job-name=aa_collect_traces
#SBATCH --partition=day
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=06:00:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Answer-agent GRPO, step 1/3 (paper recipe, sft/run_full.sh): run the full fact -> memory -> QA
# pipeline with gpt-4o on the training convs conv-43 + conv-47 and save every final-session QA trace.
# Chat calls go to the Azure v1 endpoint in src/.env (LLM_JUDGE_API_KEY + LLM_JUDGE_AZURE_ENDPOINT);
# memory embeddings (text-embedding-3-small) still use OPENAI_API_KEY — the Azure resource has no
# embedding deployment.
#
# Then build the GRPO parquet (step 2/3):
#   python src/sft/prepare_rlhf_from_traces.py --inputs <traces.jsonl> --min-trace-f1 0.15 \
#       --train-out src/data/sft_rlhf/f1_gt_015/train.parquet --val-out src/data/sft_rlhf/f1_gt_015/val.parquet
#
# Submit:
#   sbatch scripts/aa_collect_traces.sbatch

set -euo pipefail

REPO=/gpfs/radev/project/q_chen/wf287/memory_r2/src
PY=/gpfs/radev/home/wf287/project/conda_envs/memory_r2/bin/python
OUT=$REPO/data/sft/answer_traces_gpt-4o_azure_${SLURM_JOB_ID}.jsonl

set -a; source "$REPO/.env"; set +a

cd "$REPO"
"$PY" -u sft/collect_answer_traces.py \
    --provider azure \
    --model    gpt-4o \
    --conv_ids conv-43 conv-47 \
    --output   "$OUT" \
    --verbose

echo "[collect] traces: $OUT ($(wc -l < "$OUT") rows)"
