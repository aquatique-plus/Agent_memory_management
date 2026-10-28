#!/bin/bash
#SBATCH --job-name=qwen_fact_extr
#SBATCH --partition=gpu
#SBATCH --qos=qos_nmi
#SBATCH --gres=gpu:h100:1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=00:45:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Fact extraction on the gold evidence turns of wrong LoCoMo QAs with official Qwen2.5-7B-Instruct,
# using the Memory-R2 extractor prompt. Writes <name>.{jsonl,md} into analysis/wrong_qa/.
#
# Submit:
#   sbatch scripts/analysis/qwen_fact_extraction.sbatch
# Overrides (env, e.g. `sbatch --export=ALL,MODEL=ahmedehabb/Memory-R2 ...`):
#   MODEL     extractor model           (default Qwen/Qwen2.5-7B-Instruct)
#   OUT_NAME  output basename           (default wrong_qa_qwen2.5-7b_fact_extraction)
#   LIMIT     only the first N wrong QAs (debug)
# Re-render the .md only (no GPU needed):
#   python analysis/src/qwen_fact_extraction.py --render_only

set -euo pipefail

ROOT=/gpfs/radev/home/wf287/project/memory_r2
SCRATCH=/gpfs/radev/home/wf287/scratch/memory_r2
GPFS_CONDA_ENV=/gpfs/radev/home/wf287/project/conda_envs/memory_r2
ENV_PACK=$SCRATCH/envpack/memory_r2.tar.zst
mkdir -p "$SCRATCH/logs"

MODEL=${MODEL:-Qwen/Qwen2.5-7B-Instruct}
OUT_NAME=${OUT_NAME:-wrong_qa_qwen2.5-7b_fact_extraction}

# Node-local env + caches to avoid a GPFS small-file storm on torch/vllm import (see eval_locomo.sbatch).
export NODE_LOCAL_DIR=/tmp/$USER/qwen_fact_extr_$SLURM_JOB_ID
mkdir -p "$NODE_LOCAL_DIR"
trap 'rm -rf "$NODE_LOCAL_DIR"' EXIT
if [ -f "$ENV_PACK" ]; then
    zstd -q -dc "$ENV_PACK" | tar -xf - -C "$NODE_LOCAL_DIR"
    CONDA_ENV=$NODE_LOCAL_DIR/memory_r2
else
    echo "[qwen_fact_extr] WARNING: $ENV_PACK missing, importing from GPFS env"
    CONDA_ENV=$GPFS_CONDA_ENV
fi
export VLLM_CACHE_ROOT=$NODE_LOCAL_DIR/vllm_cache
export TORCHINDUCTOR_CACHE_DIR=$NODE_LOCAL_DIR/inductor_cache
export XDG_CACHE_HOME=$NODE_LOCAL_DIR/xdg_cache
export HF_HOME=/gpfs/radev/home/wf287/scratch/hf_cache
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false

echo "[qwen_fact_extr] node=$(hostname) job=$SLURM_JOB_ID model=$MODEL"
"$CONDA_ENV/bin/python" "$ROOT/analysis/src/qwen_fact_extraction.py" \
    --model "$MODEL" \
    --name "$OUT_NAME" \
    --out_dir "$ROOT/analysis/wrong_qa" \
    ${LIMIT:+--limit "$LIMIT"}
