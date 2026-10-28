#!/bin/bash
# gpt-oss-120b answer-agent servers for training reward (paper setup). Runs in the vLLM
# apptainer image built by prep_gpt_oss.sbatch, since the memory_r2 env's vLLM 0.8.5 can't serve gpt-oss.
#
# Splits the visible GPUs into groups of VLLM_TENSOR_PARALLEL and starts one server per group
# on ports VLLM_BASE_PORT, VLLM_BASE_PORT+1, ... Normally launched by train_memory.sbatch on its
# server node; blocks until all servers exit.
#
# TP=2 by default: the ~65GB MXFP4 weights fit on one H100 at TP=1, but leave only a few GB of KV cache.

SCRATCH=/gpfs/radev/home/wf287/scratch/memory_r2
SIF_PATH=${SIF_PATH:-$SCRATCH/images/vllm-openai_v0.11.0.sif}
TIKTOKEN_DIR=$SCRATCH/tiktoken_encodings

VLLM_JUDGE_MODEL=${VLLM_JUDGE_MODEL:-openai/gpt-oss-120b}
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-2}
# judge_llm.py caps prompts at ANSWER_AGENT_MAX_PROMPT_TOKENS and responses at ANSWER_AGENT_MAX_TOKENS;
# train_memory.sbatch sets them to 12288 + 4096 to fit this.
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-16384}
VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-0.85}
VLLM_MAX_NUM_SEQS=${VLLM_MAX_NUM_SEQS:-512}
VLLM_BASE_PORT=${VLLM_BASE_PORT:?Set VLLM_BASE_PORT}
SERVER_LOG_DIR=${SERVER_LOG_DIR:?Set SERVER_LOG_DIR}

set -a; source /gpfs/radev/project/q_chen/wf287/memory_r2/src/.env 2>/dev/null || true; set +a
export HF_HOME=/gpfs/radev/home/wf287/scratch/hf_cache
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN via env or sourced .env file}"
unset ROCR_VISIBLE_DEVICES

if [ ! -f "$SIF_PATH" ]; then
    echo "[gpt-oss] ERROR: $SIF_PATH missing; run scripts/train/prep_gpt_oss.sbatch first"
    exit 1
fi

# Keep vLLM's compile caches on local disk (GPFS small-file I/O). GPT_OSS_CACHE_DIR keeps them
# across restarts (time-shared answer agent restarts the servers every step) and is not removed here.
if [ -n "${GPT_OSS_CACHE_DIR:-}" ]; then
    NODE_LOCAL_DIR=$GPT_OSS_CACHE_DIR
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
else
    NODE_LOCAL_DIR=/tmp/$USER/gpt_oss_${SLURM_JOB_ID:-local}
    trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$NODE_LOCAL_DIR"' EXIT
fi
mkdir -p "$NODE_LOCAL_DIR" "$SERVER_LOG_DIR"

IFS=',' read -ra GPUS <<< "${CUDA_VISIBLE_DEVICES:?CUDA_VISIBLE_DEVICES not set}"
NUM_SERVERS=$(( ${#GPUS[@]} / VLLM_TENSOR_PARALLEL ))
echo "[gpt-oss] node=$(hostname) GPUs=${CUDA_VISIBLE_DEVICES} -> $NUM_SERVERS server(s) x TP=$VLLM_TENSOR_PARALLEL"

for ((i = 0; i < NUM_SERVERS; i++)); do
    GROUP=$(IFS=','; echo "${GPUS[*]:$((i * VLLM_TENSOR_PARALLEL)):$VLLM_TENSOR_PARALLEL}")
    PORT=$((VLLM_BASE_PORT + i))
    echo "[gpt-oss $i] GPUs=$GROUP port=$PORT"
    APPTAINERENV_CUDA_VISIBLE_DEVICES=$GROUP apptainer run --nv \
        --env HF_TOKEN="$HF_TOKEN" \
        --env HF_HOME="$HF_HOME" \
        --env CC=gcc \
        --env CXX=g++ \
        --env TIKTOKEN_ENCODINGS_BASE="$TIKTOKEN_DIR" \
        --env VLLM_CACHE_ROOT="$NODE_LOCAL_DIR/vllm_cache_$i" \
        --env XDG_CACHE_HOME="$NODE_LOCAL_DIR/xdg_cache_$i" \
        --env VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=1 \
        --bind "$HF_HOME":"$HF_HOME" \
        --bind "$TIKTOKEN_DIR":"$TIKTOKEN_DIR" \
        --bind "$NODE_LOCAL_DIR":"$NODE_LOCAL_DIR" \
        "$SIF_PATH" \
        --model "$VLLM_JUDGE_MODEL" \
        --served-model-name "$VLLM_JUDGE_MODEL" \
        --host 0.0.0.0 \
        --port "$PORT" \
        --tensor-parallel-size "$VLLM_TENSOR_PARALLEL" \
        --max-model-len "$VLLM_MAX_MODEL_LEN" \
        --gpu-memory-utilization "$VLLM_GPU_MEM_UTIL" \
        --max-num-seqs "$VLLM_MAX_NUM_SEQS" \
        --no-enable-prefix-caching \
        --max-num-batched-tokens 8192 \
        >> "$SERVER_LOG_DIR/gpt_oss_server_$i.log" 2>&1 &
done

wait
