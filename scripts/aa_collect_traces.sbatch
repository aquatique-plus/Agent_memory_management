#!/bin/bash
#SBATCH --job-name=aa_collect_traces
#SBATCH --partition=devel
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=06:00:00
#SBATCH --output=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#
# Answer-agent GRPO, step 1/3 (paper recipe, sft/run_full.sh): run the full fact -> memory -> QA
# pipeline with gpt-4o on the training convs conv-43 + conv-47 and save every final-session QA trace.
# Chat calls go to the Azure v1 endpoint in src/.env (LLM_JUDGE_API_KEY + LLM_JUDGE_AZURE_ENDPOINT);
# memory embeddings (text-embedding-3-small) still use OPENAI_API_KEY — the Azure resource has no
# embedding deployment.
#
# Step 2/3 (building the GRPO parquet with --min-trace-f1 0.15) runs at the end of this job.
#
# Submit:
#   sbatch scripts/aa_collect_traces.sbatch

set -euo pipefail

REPO=/nfs/roberts/project/pi_qc88/wf287/memory_r2/src
PY=/nfs/roberts/project/pi_qc88/wf287/conda-envs/memory_r2/bin/python
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

"$PY" sft/prepare_rlhf_from_traces.py --inputs "$OUT" --min-trace-f1 0.15 \
    --train-out data/sft_rlhf/f1_gt_015/train.parquet --val-out data/sft_rlhf/f1_gt_015/val.parquet
echo "[collect] GRPO parquet: $REPO/data/sft_rlhf/f1_gt_015/{train,val}.parquet"
