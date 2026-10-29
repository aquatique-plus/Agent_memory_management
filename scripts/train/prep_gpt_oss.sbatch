#!/bin/bash
#SBATCH --job-name=prep_gpt_oss
#SBATCH --partition=day
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# One-time setup for the gpt-oss-120b answer agent used by train_memory.sbatch:
#   1) pull the vLLM OpenAI-server image as a .sif (the memory_r2 conda env has vLLM 0.8.5,
#      which predates gpt-oss support)
#   2) download the tiktoken vocab gpt-oss's harmony tokenizer needs
#   3) pre-download the HF weights (~65GB) so the training job doesn't stall on it
#
# Submit:  sbatch scripts/train/prep_gpt_oss.sbatch
#
# Image: v0.11.0 is the last vllm-openai release built on CUDA 12.8; the GPU nodes run
# driver 570 (CUDA <= 12.8), so newer cu129/cu130 images are not guaranteed to work.

set -euo pipefail

SCRATCH=/gpfs/radev/home/wf287/scratch/memory_r2
VLLM_IMAGE_TAG=${VLLM_IMAGE_TAG:-v0.11.0}
SIF_PATH=${SIF_PATH:-$SCRATCH/images/vllm-openai_${VLLM_IMAGE_TAG}.sif}
TIKTOKEN_DIR=$SCRATCH/tiktoken_encodings
export HF_HOME=/gpfs/radev/home/wf287/scratch/hf_cache
CONDA_ENV=/gpfs/radev/home/wf287/project/conda_envs/memory_r2

set -a; source /gpfs/radev/project/q_chen/wf287/memory_r2/src/.env 2>/dev/null || true; set +a
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN via env or sourced .env file}"

mkdir -p "$(dirname "$SIF_PATH")" "$TIKTOKEN_DIR" "$HF_HOME"

# 1) Image. Layer extraction is a small-file storm, so keep apptainer's cache/tmp on local disk.
if [ ! -f "$SIF_PATH" ]; then
    export APPTAINER_CACHEDIR=/tmp/$USER/apptainer_cache_$SLURM_JOB_ID
    export APPTAINER_TMPDIR=/tmp/$USER/apptainer_tmp_$SLURM_JOB_ID
    mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
    trap 'rm -rf "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"' EXIT
    echo "[prep] pulling docker://vllm/vllm-openai:$VLLM_IMAGE_TAG -> $SIF_PATH"
    apptainer pull "$SIF_PATH.partial" "docker://vllm/vllm-openai:$VLLM_IMAGE_TAG"
    mv "$SIF_PATH.partial" "$SIF_PATH"
else
    echo "[prep] image already present: $SIF_PATH"
fi
apptainer exec "$SIF_PATH" python3 -c "import vllm; print('[prep] vllm in image:', vllm.__version__)"

# 2) tiktoken vocab
for enc in o200k_base cl100k_base; do
    if [ ! -s "$TIKTOKEN_DIR/${enc}.tiktoken" ]; then
        echo "[prep] downloading tiktoken vocab: $enc"
        wget -q -O "$TIKTOKEN_DIR/${enc}.tiktoken" \
            "https://openaipublic.blob.core.windows.net/encodings/${enc}.tiktoken"
    fi
done

# 3) Weights. vLLM only loads the top-level HF safetensors; skip original/ and metal/ (~130GB).
"$CONDA_ENV/bin/hf" download openai/gpt-oss-120b --exclude "original/*" "metal/*"

echo "[prep] done"
