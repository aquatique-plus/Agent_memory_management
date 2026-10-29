#!/bin/bash
# Answer-agent vLLM server: serves ahmedehabb/Memory-R2-answer-agent (SFT+RL Qwen2.5-7B) for test eval.
# Runs vLLM straight from the memory_r2 conda env (no apptainer image needed); 1 GPU is enough.
# Upstream's newer-vLLM-only flags (--max-cudagraph-capture-size, --stream-interval) are left out for vLLM 0.8.5.
#
# Normally launched by scripts/eval_locomo.sbatch on one of the job's GPUs (via CUDA_VISIBLE_DEVICES).
#
# The eval client finds this server via the rendezvous file and must request the same model name:
#   RENDEZVOUS_DIR=$REPO/vllm_servers_answer_agent OPENAI_JUDGE_MODEL=ahmedehabb/Memory-R2-answer-agent
# (both are the defaults in scripts/vllm_client_test_eval.sh)

REPO=/nfs/roberts/project/pi_qc88/wf287/memory_r2/src
CONDA_ENV=${CONDA_ENV:-/nfs/roberts/project/pi_qc88/wf287/conda-envs/memory_r2}  # eval_locomo.sbatch points this at a node-local copy

set -a
source "$REPO/.env" 2>/dev/null || true
set +a

ANSWER_AGENT_MODEL="${ANSWER_AGENT_MODEL:-ahmedehabb/Memory-R2-answer-agent}"
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-1}
# Client (judge_llm.py) caps prompts at ANSWER_AGENT_MAX_PROMPT_TOKENS=12288 and responses at
# ANSWER_AGENT_MAX_TOKENS=1024, so 12288 + 1024 would do; 32768 matches upstream's paper server.
VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN:-32768}
# Upstream passes no --dtype, i.e. vLLM "auto" (vLLM 0.8.5 serves this fp32 checkpoint as fp16;
# the model was trained in bf16: ANSWER_AGENT_DTYPE=bfloat16 to match training).
ANSWER_AGENT_DTYPE=${ANSWER_AGENT_DTYPE:-auto}
# KV-cache budget, as in upstream's paper-eval server (vllm_server_qwen_n11_sft_cont_step50_BV_paper_qadump.sh).
ANSWER_AGENT_GPU_MEM_UTIL=${ANSWER_AGENT_GPU_MEM_UTIL:-0.40}

RENDEZVOUS_DIR=${RENDEZVOUS_DIR:-$REPO/vllm_servers_answer_agent}
SERVER_IDX=${SERVER_IDX:-0}
VLLM_PORT=${VLLM_PORT:-$((8100 + SERVER_IDX))}

export HF_HOME=${HF_HOME:-/nfs/roberts/scratch/pi_qc88/wf287/hf_cache}
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN via env or sourced .env file}"
unset ROCR_VISIBLE_DEVICES

LOG_DIR=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2/logs/vllm_server_answer_agent
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
    --dtype "$ANSWER_AGENT_DTYPE" \
    --gpu-memory-utilization "$ANSWER_AGENT_GPU_MEM_UTIL" \
    --max-num-seqs 512 \
    --max-num-batched-tokens 8192 \
    --enable-chunked-prefill \
    --no-enable-prefix-caching \
    2>&1 | tee "$LOG_DIR/server_${SERVER_IDX}.log"

rm -f "$RENDEZVOUS_DIR/server_${SERVER_IDX}.txt"
