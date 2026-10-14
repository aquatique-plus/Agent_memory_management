#!/bin/bash
# Answer-agent vLLM server: serves ahmedehabb/Memory-R2-answer-agent (SFT+RL Qwen2.5-7B) for test eval.
# Runs vLLM straight from the memory_r2 conda env (no apptainer image needed); 1 GPU is enough.
#
# Normally launched by scripts/eval_locomo.sbatch on one of the job's GPUs (via CUDA_VISIBLE_DEVICES).
#
# The eval client finds this server via the rendezvous file and must request the same model name:
#   RENDEZVOUS_DIR=$REPO/vllm_servers_answer_agent OPENAI_JUDGE_MODEL=ahmedehabb/Memory-R2-answer-agent
# (both are the defaults in scripts/vllm_client_test_eval.sh)

REPO=/gpfs/radev/project/q_chen/wf287/memory_r2/src
CONDA_ENV=${CONDA_ENV:-/gpfs/radev/home/wf287/project/conda_envs/memory_r2}  # eval_locomo.sbatch points this at a node-local copy

set -a
source "$REPO/.env" 2>/dev/null || true
set +a

ANSWER_AGENT_MODEL="${ANSWER_AGENT_MODEL:-ahmedehabb/Memory-R2-answer-agent}"
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-1}
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-32768}

RENDEZVOUS_DIR=${RENDEZVOUS_DIR:-$REPO/vllm_servers_answer_agent}
SERVER_IDX=${SERVER_IDX:-0}
VLLM_PORT=${VLLM_PORT:-$((8100 + SERVER_IDX))}

export HF_HOME=${HF_HOME:-/gpfs/radev/home/wf287/scratch/hf_cache}
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN via env or sourced .env file}"
unset ROCR_VISIBLE_DEVICES

LOG_DIR=/gpfs/radev/home/wf287/scratch/memory_r2/logs/vllm_server_answer_agent
mkdir -p "$RENDEZVOUS_DIR" "$LOG_DIR" "$HF_HOME"

export PATH="$CONDA_ENV/bin:$PATH"

echo "$(hostname):${VLLM_PORT}" > "$RENDEZVOUS_DIR/server_${SERVER_IDX}.txt"
echo "[answer-agent $SERVER_IDX] Rendezvous written: $(hostname):${VLLM_PORT} -> $RENDEZVOUS_DIR"
echo "[answer-agent $SERVER_IDX] Starting vLLM server for $ANSWER_AGENT_MODEL ..."

python -m vllm.entrypoints.openai.api_server \
    --model "$ANSWER_AGENT_MODEL" \
    --served-model-name "$ANSWER_AGENT_MODEL" \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --tensor-parallel-size "$VLLM_TENSOR_PARALLEL" \
    --max-model-len "$VLLM_MAX_MODEL_LEN" \
    --gpu-memory-utilization 0.85 \
    --max-num-seqs 512 \
    2>&1 | tee "$LOG_DIR/server_${SERVER_IDX}.log"

rm -f "$RENDEZVOUS_DIR/server_${SERVER_IDX}.txt"
