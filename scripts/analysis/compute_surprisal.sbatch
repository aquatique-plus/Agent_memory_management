#!/bin/bash
#SBATCH --job-name=locomo_surprisal
#SBATCH --partition=gpu_devel
#SBATCH --gres=gpu:h200:1
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=4 --mem=64G
#SBATCH --time=00:30:00
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#
# Per-dialogue-turn surprisal of every LoCoMo session under a frozen Qwen2.5-7B (one forward per
# session) and surprisal-based segmentation: src/data/locomo/compute_surprisal.py.
# Writes src/data/locomo/surprisal/{surprisal,segments}.json (OUT_DIR overrides, e.g. one dir per model).
# Submit: sbatch scripts/analysis/compute_surprisal.sbatch
# Overrides (env): MODEL, OUT_DIR, SEG_ARGS (extra args for the segments stage, e.g. "--max_segments 6").
# Re-segment only (no GPU): python src/data/locomo/compute_surprisal.py --stage segments [...]

set -euo pipefail
ROOT=/home/wf287/project_pi_qc88/wf287/memory_r2
SCRATCH=/home/wf287/scratch_pi_qc88/wf287/memory_r2
ENV_PACK=$SCRATCH/envpack/memory_r2.tar.zst
MODEL=${MODEL:-Qwen/Qwen2.5-7B-Instruct}

export NODE_LOCAL_DIR=/tmp/$USER/surprisal_$SLURM_JOB_ID
mkdir -p "$NODE_LOCAL_DIR"
trap 'rm -rf "$NODE_LOCAL_DIR"' EXIT
if [ -f "$ENV_PACK" ]; then
    zstd -q -dc "$ENV_PACK" | tar -xf - -C "$NODE_LOCAL_DIR"
    CONDA_ENV=$NODE_LOCAL_DIR/memory_r2
else
    CONDA_ENV=/home/wf287/project_pi_qc88/wf287/conda-envs/memory_r2
fi
# deepspeed (imported by transformers) needs nvcc / CUDA_HOME from the env, as in train_memory_run.sh
export PATH="$CONDA_ENV/bin:$PATH" CUDA_HOME=$CONDA_ENV
export XDG_CACHE_HOME=$NODE_LOCAL_DIR/xdg_cache
export HF_HOME=/home/wf287/scratch_pi_qc88/wf287/hf_cache
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false

# Pass the local snapshot dir: the hub-name lookup failed offline in job 33680652.
MODEL_DIR=$(ls -d $HF_HOME/hub/models--${MODEL//\//--}/snapshots/*/ | head -1)
echo "[surprisal] node=$(hostname) job=$SLURM_JOB_ID model=$MODEL"
"$CONDA_ENV/bin/python" "$ROOT/src/data/locomo/compute_surprisal.py" --stage all --model "$MODEL_DIR" ${OUT_DIR:+--out_dir "$OUT_DIR"} ${SEG_ARGS:-}
