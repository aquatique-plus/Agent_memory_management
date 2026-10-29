#!/bin/bash
#SBATCH --job-name=memr2_eval
#SBATCH --partition=gpu_h200
#SBATCH --qos=normal
#SBATCH --gres=gpu:h200:3
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=400G
#SBATCH --time=03:00:00
#SBATCH --output=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#
# LoCoMo test eval (paper setup), all in one 3xH200 job:
#   GPU 0     -> answer agent  (ahmedehabb/Memory-R2-answer-agent, vLLM server)
#   GPU 1, 2  -> memory manager (ahmedehabb/Memory-R2, verl test_only run)
# Settings follow upstream Memory-R2 (memory manager: scripts/vllm_clients/vllm_client_test_eval.sh with
# verl rollout defaults: bf16, gpu_memory_utilization 0.5, max_response_length 4096, no FSDP offload;
# answer agent: scripts/vllm_servers/vllm_server_qwen_n11_sft_cont_step50_BV_paper_qadump.sh: vLLM auto dtype,
# gpu_memory_utilization 0.40, no max_tokens / prompt truncation). Only difference: upstream gives the
# memory manager 4 GPUs, here it gets 2.
# Then scores the QA dump with F1/BLEU only (no LLM judge).
#
# Submit:
#   sbatch scripts/eval_locomo.sbatch
# Overrides (env, e.g. `sbatch --export=ALL,RUN_TAG=foo scripts/eval_locomo.sbatch`):
#   MODEL_PATH_OVERRIDE  memory manager (default ahmedehabb/Memory-R2)
#   ANSWER_AGENT_MODEL   answer agent   (default ahmedehabb/Memory-R2-answer-agent)
#   ANSWER_AGENT_DTYPE   answer-agent vLLM dtype (default auto, as upstream)
#   MODEL_DTYPE          memory-manager vLLM rollout dtype (default: verl's bfloat16, as upstream)
#   MAX_OUTPUT_TOKENS    cap generated tokens per call for both models (default: upstream, i.e. memory
#                        manager 4096 and no answer-agent cap)
#   ANSWER_AGENT_HF_OFFLINE=1  serve the answer agent from the local HF cache only (pre-download it first)
#   RUN_TAG              label for logs / dump dir (default memr2_paper)
#   LLM_JUDGE=1          also score the dump with the LLM judge (LLM_JUDGE_* in src/.env)
#   REMA_DUMP_MEMOPS     log every memory-bank op to qa_dumps/<run>/memory_ops/ (default 1; 0 disables)
#   LLM_JUDGE_PROVIDER   azure (own key, default) | openai (reuse embedding OPENAI_API_KEY)
#   ROLLOUT_GPU_MEM_UTIL vLLM rollout gpu_memory_utilization (default 0.5, upstream)
#   MM_PARAM_OFFLOAD=1   keep the FSDP actor/ref on CPU (frees ~25GB/GPU for KV cache if 0.5 OOMs)
#   EXTRA_HYDRA_OVERRIDES  extra hydra overrides, applied after the memory defaults below

set -uo pipefail

SCRIPTS=/nfs/roberts/project/pi_qc88/wf287/memory_r2/scripts
REPO=/nfs/roberts/project/pi_qc88/wf287/memory_r2/src
SCRATCH=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2
SHARED_CONDA_ENV=/nfs/roberts/project/pi_qc88/wf287/conda-envs/memory_r2
ENV_PACK=$SCRATCH/envpack/memory_r2.tar.zst   # tar of $SHARED_CONDA_ENV; rebuild after changing the env
mkdir -p "$SCRATCH/logs"

# ---------------------------------------------------------------------------
# Split the 3 allocated GPUs: first -> answer agent, other two -> memory manager
# ---------------------------------------------------------------------------
IFS=',' read -ra GPUS <<< "${CUDA_VISIBLE_DEVICES:?CUDA_VISIBLE_DEVICES not set (run under sbatch with --gres=gpu:h200:3)}"
if [ "${#GPUS[@]}" -ne 3 ]; then
    echo "[eval] ERROR: expected 3 GPUs, got CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    exit 1
fi
AA_GPU=${GPUS[0]}
MM_GPUS="${GPUS[1]},${GPUS[2]}"
echo "[eval] node=$(hostname) job=$SLURM_JOB_ID answer-agent GPU=$AA_GPU memory-manager GPUs=$MM_GPUS"

export ANSWER_AGENT_MODEL=${ANSWER_AGENT_MODEL:-ahmedehabb/Memory-R2-answer-agent}
export MODEL_PATH_OVERRIDE=${MODEL_PATH_OVERRIDE:-ahmedehabb/Memory-R2}
export RUN_TAG=${RUN_TAG:-memr2_paper}
export RUN_TS=$(date +%Y%m%d_%H%M%S)
# judge_llm.py caches answers by prompt hash only, so keep one cache per answer-agent model;
# a shared cache would hand one model's answers to another.
export OPENAI_CACHE_DIR=$SCRATCH/workspace/openai_cache/${ANSWER_AGENT_MODEL//\//__}

# Per-job rendezvous dir + port so stale files / other jobs on the node never get picked up.
export RENDEZVOUS_DIR=$SCRATCH/rendezvous/answer_agent_$SLURM_JOB_ID
export VLLM_PORT=$((20000 + SLURM_JOB_ID % 10000))
mkdir -p "$RENDEZVOUS_DIR"

# ---------------------------------------------------------------------------
# 0) Node-local env + caches. Importing torch/vllm/verl from the 72k-file conda env on GPFS
#    (once per process: answer agent, ray workers, ...) is a small-file storm that can stall
#    GPFS metadata (job 2838170 hung in D state at vLLM import). Unpack one big tarball to
#    local NVMe instead and keep compile/temp caches local too.
# ---------------------------------------------------------------------------
export NODE_LOCAL_DIR=/tmp/$USER/memr2_eval_$SLURM_JOB_ID
mkdir -p "$NODE_LOCAL_DIR"
if [ -f "$ENV_PACK" ]; then
    t0=$(date +%s)
    if ! zstd -q -dc "$ENV_PACK" | tar -xf - -C "$NODE_LOCAL_DIR"; then
        echo "[eval] ERROR: failed to unpack $ENV_PACK into $NODE_LOCAL_DIR"
        rm -rf "$NODE_LOCAL_DIR"
        exit 1
    fi
    export CONDA_ENV=$NODE_LOCAL_DIR/memory_r2
    echo "[eval] unpacked conda env to $CONDA_ENV in $(( $(date +%s) - t0 ))s"
else
    export CONDA_ENV=$SHARED_CONDA_ENV
    echo "[eval] WARNING: $ENV_PACK missing, importing from shared env $CONDA_ENV"
fi
export VLLM_CACHE_ROOT=$NODE_LOCAL_DIR/vllm_cache
export TORCHINDUCTOR_CACHE_DIR=$NODE_LOCAL_DIR/inductor_cache
export XDG_CACHE_HOME=$NODE_LOCAL_DIR/xdg_cache
mkdir -p "$VLLM_CACHE_ROOT" "$TORCHINDUCTOR_CACHE_DIR" "$XDG_CACHE_HOME"
# Seed vLLM's torch.compile cache from the shared one (~170 files) to skip recompiling.
cp -r "$HOME/.cache/vllm/." "$VLLM_CACHE_ROOT/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1) Answer agent on GPU 0
# ---------------------------------------------------------------------------
CUDA_VISIBLE_DEVICES=$AA_GPU HF_HUB_OFFLINE=${ANSWER_AGENT_HF_OFFLINE:-0} bash "$SCRIPTS/vllm_server_answer_agent.sh" \
    > "$SCRATCH/logs/answer_agent_$SLURM_JOB_ID.log" 2>&1 &
AA_PID=$!
cleanup() {
    pkill -P "$AA_PID" 2>/dev/null   # vllm + tee first, before they get reparented
    kill "$AA_PID" 2>/dev/null
    rm -rf "$RENDEZVOUS_DIR" "$NODE_LOCAL_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2) Memory manager + test eval on GPUs 1,2
#    The client waits for the answer agent to become healthy (first run downloads ~15GB).
# ---------------------------------------------------------------------------
export OPENAI_JUDGE_MODEL=$ANSWER_AGENT_MODEL
export SERVER_WAIT_TIMEOUT=${SERVER_WAIT_TIMEOUT:-1800}
export N_GPUS=2
export REMA_DUMP_QA=1
export VAL_KWARGS_N=${VAL_KWARGS_N:-1}
export REMA_QA_DUMP_DIR=$SCRATCH/qa_dumps
export REMA_DUMP_MEMOPS=${REMA_DUMP_MEMOPS:-1}

# Output length: upstream defaults unless MAX_OUTPUT_TOKENS is set (then it caps both models).
if [ -n "${MAX_OUTPUT_TOKENS:-}" ]; then
    export MAX_RESPONSE_LENGTH_OVERRIDE=$MAX_OUTPUT_TOKENS
    export ANSWER_AGENT_MAX_TOKENS=$MAX_OUTPUT_TOKENS
else
    export ANSWER_AGENT_MAX_TOKENS=0   # 0 = no max_tokens, as upstream
fi
export ANSWER_AGENT_MAX_PROMPT_TOKENS=${ANSWER_AGENT_MAX_PROMPT_TOKENS:-0}   # 0 = no prompt truncation, as upstream

# Memory: upstream settings (rollout gpu_memory_utilization=0.5, actor/ref resident on GPU).
# On 80GB H100s the FSDP actor+ref shards (~30GB reserved/GPU) left vLLM no KV cache at 0.5
# (job 2833514); a 141GB H200 leaves ~25GB/GPU of KV cache. If it still OOMs, MM_PARAM_OFFLOAD=1
# keeps actor/ref on CPU (test-only never trains; they're only moved to GPU to sync weights into vLLM).
MEM_OVERRIDES="actor_rollout_ref.rollout.gpu_memory_utilization=${ROLLOUT_GPU_MEM_UTIL:-0.5}"
if [ -n "${MODEL_DTYPE:-}" ]; then
    MEM_OVERRIDES="$MEM_OVERRIDES actor_rollout_ref.rollout.dtype=$MODEL_DTYPE"
fi
if [ "${MM_PARAM_OFFLOAD:-0}" = "1" ]; then
    MEM_OVERRIDES="$MEM_OVERRIDES actor_rollout_ref.actor.fsdp_config.param_offload=True \
actor_rollout_ref.actor.fsdp_config.optimizer_offload=True \
actor_rollout_ref.ref.fsdp_config.param_offload=True"
fi
export EXTRA_HYDRA_OVERRIDES="$MEM_OVERRIDES ${EXTRA_HYDRA_OVERRIDES:-}"
echo "[eval] EXTRA_HYDRA_OVERRIDES=$EXTRA_HYDRA_OVERRIDES"

CUDA_VISIBLE_DEVICES=$MM_GPUS bash "$SCRIPTS/vllm_client_test_eval.sh"
EVAL_RC=$?
echo "[eval] test eval exited with rc=$EVAL_RC"

# ---------------------------------------------------------------------------
# 3) Score the dump (F1/BLEU; LLM judge only if LLM_JUDGE=1)
# ---------------------------------------------------------------------------
DUMP_ROOT=$REMA_QA_DUMP_DIR/${RUN_TAG}_${RUN_TS}/test/step_unknown
if [ -d "$DUMP_ROOT" ]; then
    JUDGE_FLAG=""
    if [ "${LLM_JUDGE:-0}" = "1" ]; then
        JUDGE_FLAG="--llm_judge"
        # Judge key/model come from LLM_JUDGE_* in .env, never from the embedding OPENAI_API_KEY.
        set -a; source "$REPO/.env" 2>/dev/null || true; set +a
    fi
    "$CONDA_ENV/bin/python" "$REPO/testing/pipeline_test_locomo_qa_dump/score_locomo_qa_dumps.py" \
        --dump_root "$DUMP_ROOT" \
        --output "$SCRATCH/results/${RUN_TAG}_${RUN_TS}.json" \
        $JUDGE_FLAG
else
    echo "[eval] WARNING: no QA dump at $DUMP_ROOT, skipping scoring"
fi

MEMOPS_DIR=$REMA_QA_DUMP_DIR/${RUN_TAG}_${RUN_TS}/memory_ops
if [ -d "$MEMOPS_DIR" ]; then
    echo "[eval] memory-op counts ($MEMOPS_DIR):"
    cat "$MEMOPS_DIR"/*.jsonl | "$CONDA_ENV/bin/python" -c '
import sys, json, collections
c = collections.Counter((d["op"], d["status"]) for d in map(json.loads, sys.stdin))
for (op, st), n in sorted(c.items()): print(f"  {op:12s} {st:8s} {n}")'
fi

exit "$EVAL_RC"
