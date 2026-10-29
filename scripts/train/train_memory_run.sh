#!/bin/bash
# Shared body of the memory-management training launchers (train_memory*.sbatch); sourced, not run.
# The launcher sets the resource layout first:
#   SERVER_NODE           host running the gpt-oss-120b answer agent
#   SERVER_SRUN_ARGS      srun options that place the server step on that node
#   SERVER_GPUS           GPUs on that node for gpt-oss; VLLM_TENSOR_PARALLEL per server
#   N_POLICY_GPUS         GPUs of the batch step used for policy training
#   POLICY_EXTRA_FLAGS    extra hydra overrides for the policy (may be empty)
#   ANSWER_AGENT_TIMESHARE=1 instead runs gpt-oss on the policy GPUs of the batch step, started before each
#   reward phase and stopped before each policy phase (rema_trainer/answer_agent_timeshare.py); then
#   SERVER_NODE / SERVER_SRUN_ARGS are unused and SERVER_GPUS must equal N_POLICY_GPUS.
# Training config follows src/scripts/examples/_curriculum_learning.sh; see train_memory.sbatch.

set -uo pipefail
ANSWER_AGENT_TIMESHARE=${ANSWER_AGENT_TIMESHARE:-0}
: "${SERVER_GPUS:?}" "${VLLM_TENSOR_PARALLEL:?}" "${N_POLICY_GPUS:?}"
if [ "$ANSWER_AGENT_TIMESHARE" != "1" ]; then
    : "${SERVER_NODE:?}" "${SERVER_SRUN_ARGS:?}"
fi
POLICY_EXTRA_FLAGS=${POLICY_EXTRA_FLAGS:-}
# Experiment-specific hydra overrides (training and final test) and a run-name suffix for them.
EXTRA_FLAGS=${EXTRA_FLAGS:-}
EXP_TAG=${EXP_TAG:-}
# Policy-loss ratio/clip granularity (token|turn) and aggregation (turn|trajectory|token|seq-sum-norm).
# Dr. GRPO: CLIP_MODE=token AGG_MODE=seq-sum-norm with +actor_rollout_ref.actor.loss_scale_factor in EXTRA_FLAGS.
CLIP_MODE=${CLIP_MODE:-turn}
AGG_MODE=${AGG_MODE:-turn}
# Set (e.g. 0.99) to generate the fact-extraction role with an EMA of the policy weights; the final
# test then loads the EMA saved with the best checkpoint.
EMA_MOMENTUM=${EMA_MOMENTUM:-}

TRAIN_SCRIPTS=/gpfs/radev/project/q_chen/wf287/memory_r2/scripts/train
REPO=/gpfs/radev/project/q_chen/wf287/memory_r2/src
SCRATCH=/gpfs/radev/home/wf287/scratch/memory_r2
WORKSPACE=$SCRATCH/workspace
GPFS_CONDA_ENV=/gpfs/radev/home/wf287/project/conda_envs/memory_r2
ENV_PACK=$SCRATCH/envpack/memory_r2.tar.zst   # tar of $GPFS_CONDA_ENV; rebuild after changing the env

set -a; source "$REPO/.env" 2>/dev/null || true; set +a

export JOB_ID=$SLURM_JOB_ID
export LOG_DIR=$SCRATCH/logs/$JOB_ID
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 1) gpt-oss-120b answer agent (launched as its own srun step on $SERVER_NODE,
#    or in timeshare mode by the trainer itself on the policy GPUs)
# ---------------------------------------------------------------------------
VLLM_JUDGE_MODEL=openai/gpt-oss-120b
export VLLM_TENSOR_PARALLEL
export VLLM_BASE_PORT=$((20000 + JOB_ID % 10000))
export SERVER_LOG_DIR=$LOG_DIR
NUM_SERVERS=$((SERVER_GPUS / VLLM_TENSOR_PARALLEL))
export NODE_LOCAL_DIR=/tmp/$USER/memr2_train_$JOB_ID

if [ "$ANSWER_AGENT_TIMESHARE" = "1" ]; then
    echo "[train] job=$JOB_ID policy GPUs=$N_POLICY_GPUS, answer agent time-shares them"
    if [ "$SERVER_GPUS" != "$N_POLICY_GPUS" ]; then
        echo "[train] ERROR: timeshare needs SERVER_GPUS ($SERVER_GPUS) == N_POLICY_GPUS ($N_POLICY_GPUS)"
        exit 1
    fi
    export ANSWER_AGENT_TIMESHARE
    export ANSWER_AGENT_LAUNCH_SCRIPT=$TRAIN_SCRIPTS/vllm_server_gpt_oss.sh
    export ANSWER_AGENT_GPUS=${CUDA_VISIBLE_DEVICES:?CUDA_VISIBLE_DEVICES not set}
    export ANSWER_AGENT_LOG=$LOG_DIR/gpt_oss_launcher.log
    export ANSWER_AGENT_STARTUP_TIMEOUT=${SERVER_WAIT_TIMEOUT:-3600}
    # Keeps vLLM's compile caches across the per-step server restarts.
    export GPT_OSS_CACHE_DIR=$NODE_LOCAL_DIR/gpt_oss_cache
    SERVER_PID=""
else
    echo "[train] job=$JOB_ID policy GPUs=$N_POLICY_GPUS answer-agent node=$SERVER_NODE"
    srun $SERVER_SRUN_ARGS \
        bash "$TRAIN_SCRIPTS/vllm_server_gpt_oss.sh" > "$LOG_DIR/gpt_oss_launcher.log" 2>&1 &
    SERVER_PID=$!
fi

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$NODE_LOCAL_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2) Node-local conda env + caches on the training node (GPFS small-file I/O, see eval_locomo.sbatch)
# ---------------------------------------------------------------------------
mkdir -p "$NODE_LOCAL_DIR"
if [ -f "$ENV_PACK" ]; then
    t0=$(date +%s)
    if ! zstd -q -dc "$ENV_PACK" | tar -xf - -C "$NODE_LOCAL_DIR"; then
        echo "[train] ERROR: failed to unpack $ENV_PACK into $NODE_LOCAL_DIR"
        exit 1
    fi
    CONDA_ENV=$NODE_LOCAL_DIR/memory_r2
    echo "[train] unpacked conda env to $CONDA_ENV in $(( $(date +%s) - t0 ))s"
else
    CONDA_ENV=$GPFS_CONDA_ENV
    echo "[train] WARNING: $ENV_PACK missing, importing from GPFS env $CONDA_ENV"
fi
export PATH="$CONDA_ENV/bin:$PATH"
export VLLM_CACHE_ROOT=$NODE_LOCAL_DIR/vllm_cache
export TORCHINDUCTOR_CACHE_DIR=$NODE_LOCAL_DIR/inductor_cache
export XDG_CACHE_HOME=$NODE_LOCAL_DIR/xdg_cache
cp -r "$HOME/.cache/vllm/." "$VLLM_CACHE_ROOT/" 2>/dev/null || true

export DATASET_DIR=$SCRATCH/data/locomo/processed_train_$JOB_ID
export TMPDIR=$NODE_LOCAL_DIR/tmp
export RAY_TMPDIR=/tmp/$USER/ray_$JOB_ID
export SCRATCH_DIR=$WORKSPACE/verl_$JOB_ID
export HF_HOME=/gpfs/radev/home/wf287/scratch/hf_cache
export HF_DATASETS_CACHE=$WORKSPACE/hf_datasets
export TRITON_HOME=$NODE_LOCAL_DIR/trition
export TRITON_DUMP_DIR=$NODE_LOCAL_DIR/trition_dump
export EMBEDDING_CACHE_DIR=$WORKSPACE/embedding_cache
export MEMORY_CACHE_DIR=$WORKSPACE/memory/memory_cache_$JOB_ID/train
export MEMORY_CACHE_DIR_VAL=$WORKSPACE/memory/memory_cache_$JOB_ID/validation
export MEMORY_CACHE_DIR_TEST=$WORKSPACE/memory/memory_cache_$JOB_ID/test
# judge_llm.py caches answers by prompt hash only: keep one cache per answer-agent model.
export OPENAI_CACHE_DIR=$WORKSPACE/openai_cache/${VLLM_JUDGE_MODEL//\//__}
export TEACHER_CACHE_DIR=$WORKSPACE/teacher_cache
mkdir -p $DATASET_DIR $TMPDIR $RAY_TMPDIR $SCRATCH_DIR $HF_HOME $HF_DATASETS_CACHE $TRITON_HOME $TRITON_DUMP_DIR \
         $EMBEDDING_CACHE_DIR $MEMORY_CACHE_DIR $MEMORY_CACHE_DIR_VAL $MEMORY_CACHE_DIR_TEST \
         $OPENAI_CACHE_DIR $TEACHER_CACHE_DIR

# Fix DATA_SEED to compare runs on the same conversation split.
export DATA_SEED=${DATA_SEED:-$(echo "$JOB_ID" | cksum | awk '{print $1}')}
echo "[train] DATA_SEED=$DATA_SEED"

export HYDRA_FULL_ERROR=1
export HF_TOKEN="${HF_TOKEN:?Set HF_TOKEN via env or sourced .env file}"
export OPENAI_API_KEY="${OPENAI_API_KEY:?Set OPENAI_API_KEY via env or sourced .env file}"   # embeddings
export WANDB_API_KEY="${WANDB_API_KEY:?Set WANDB_API_KEY via env or sourced .env file}"
unset ROCR_VISIBLE_DEVICES

cd "$REPO"

# ---------------------------------------------------------------------------
# 3) Wait for the answer-agent servers (first load reads ~65GB from GPFS)
# ---------------------------------------------------------------------------
SERVER_WAIT_TIMEOUT=${SERVER_WAIT_TIMEOUT:-3600}
BASE_URLS=""
for ((i = 0; i < NUM_SERVERS; i++)); do
    if [ "$ANSWER_AGENT_TIMESHARE" = "1" ]; then
        # Not up yet: the trainer starts them on this node at the first reward call.
        BASE_URLS="${BASE_URLS:+$BASE_URLS,}http://127.0.0.1:$((VLLM_BASE_PORT + i))/v1"
        continue
    fi
    URL="http://$SERVER_NODE:$((VLLM_BASE_PORT + i))/v1"
    elapsed=0
    until curl -sf "$URL/models" > /dev/null 2>&1; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "[train] ERROR: gpt-oss server step exited; see $LOG_DIR/gpt_oss_server_*.log"
            exit 1
        fi
        if [ "$elapsed" -ge "$SERVER_WAIT_TIMEOUT" ]; then
            echo "[train] ERROR: $URL not healthy after ${SERVER_WAIT_TIMEOUT}s"
            exit 1
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    echo "[train] answer agent $i ready at $URL"
    BASE_URLS="${BASE_URLS:+$BASE_URLS,}$URL"
done

export JUDGE_PROVIDER=openai
export JUDGE_BASE_URLS="$BASE_URLS"
export JUDGE_API_KEY=EMPTY
export OPENAI_JUDGE_MODEL=$VLLM_JUDGE_MODEL
# gpt-oss spends output tokens on reasoning before the answer; the 1024 default can cut it off.
export ANSWER_AGENT_MAX_TOKENS=${ANSWER_AGENT_MAX_TOKENS:-4096}
export ANSWER_AGENT_MAX_PROMPT_TOKENS=${ANSWER_AGENT_MAX_PROMPT_TOKENS:-12288}

# ---------------------------------------------------------------------------
# 4) Training (flags as in _curriculum_learning.sh)
# ---------------------------------------------------------------------------
export PROJECT_NAME="rema-curriculum-v1"
export BASE_MODEL="Qwen/Qwen2.5-7B-Instruct"
CURRENT_MODEL_PATH=$BASE_MODEL

MAX_NUM_TURNS=4
NUM_TRAIN_CONVS=2
NUM_VAL_CONVS=1
NUM_TEST_CONVS=7
algorithm=grpo
num_rollouts=8
max_prompt_length=16384
max_response_length=2048
use_kl_loss=True
kl_loss_coef=0.01
use_kl_in_reward=False
kl_coef=0.0005
LAM_TOKEN_LEVEL=1.0
GAMMA_TURN_LEVEL=1.0
REPLAY_MIX_RATIO=0
TEST_SAVE_FREQ=5
NUM_EPOCHS=${NUM_EPOCHS:-50}
PPO_EPOCHS=2
REWARD_TYPE=persession
COMPRESSION_PENALTY=${COMPRESSION_PENALTY:-0.3}
CLIP_RATIO=0.2
STAGE_LR="2e-6"

FAST_EXPERIMENT=${FAST_EXPERIMENT:-1}
if [ "$FAST_EXPERIMENT" = "1" ]; then
    export REMA_REWARD_MAX_QA_TRAIN_INNER=${REMA_REWARD_MAX_QA_TRAIN_INNER:-16}
    export REMA_REWARD_MAX_QA_TRAIN_TERMINAL=${REMA_REWARD_MAX_QA_TRAIN_TERMINAL:-64}
    export REMA_REWARD_MAX_QA_EVAL=${REMA_REWARD_MAX_QA_EVAL:-0}
    export REMA_REWARD_QA_SAMPLE_STRATEGY=${REMA_REWARD_QA_SAMPLE_STRATEGY:-random}
    export REMA_REWARD_SAME_QAS_ACROSS_ROLLOUTS=${REMA_REWARD_SAME_QAS_ACROSS_ROLLOUTS:-1}
    export REMA_REWARD_QA_SAMPLE_SEED=${REMA_REWARD_QA_SAMPLE_SEED:-12345}
    export REMA_REWARD_MAX_OUTER_WORKERS=${REMA_REWARD_MAX_OUTER_WORKERS:-8}
    export REMA_REWARD_MAX_INNER_WORKERS=${REMA_REWARD_MAX_INNER_WORKERS:-4}
    export REMA_REWARD_TIMEOUT_S=${REMA_REWARD_TIMEOUT_S:-600}
fi

STAGES=(${STAGES_OVERRIDE:-32})
INNER_GPRO_FRAC=0.25

# Flags shared by the training and final-test runs (rebuilt per run, since the model path changes).
set_common_flags() {
    COMMON_FLAGS=(
        +actor_rollout_ref.rollout.inner_sampling_fraction=$INNER_GPRO_FRAC
        +actor_rollout_ref.rollout.inner_n=4
        +algorithm.use_bilevel_gae=False
        actor_rollout_ref.actor.ppo_epochs=$PPO_EPOCHS
        +trainer.rewardtype=$REWARD_TYPE
        +trainer.compression_penalty=$COMPRESSION_PENALTY
        trainer.project_name=$PROJECT_NAME
        trainer.nnodes=1
        trainer.n_gpus_per_node=$N_POLICY_GPUS
        +trainer.replay_mix_ratio=$REPLAY_MIX_RATIO
        +trainer.replay_strategy=uniform
        +trainer.replay_buffer_size=0
        data.train_files=$DATASET_DIR/train.parquet
        data.val_files=$DATASET_DIR/val.parquet
        data.val_batch_size=$NUM_VAL_CONVS
        +data.test_files=$DATASET_DIR/test.parquet
        +data.test_batch_size=$NUM_TEST_CONVS
        data.train_batch_size=$NUM_TRAIN_CONVS
        data.max_prompt_length=$max_prompt_length
        data.max_response_length=$max_response_length
        actor_rollout_ref.rollout.prompt_length=$max_prompt_length
        actor_rollout_ref.rollout.response_length=$max_response_length
        data.shuffle=False
        actor_rollout_ref.model.path=$CURRENT_MODEL_PATH
        actor_rollout_ref.model.use_remove_padding=True
        actor_rollout_ref.actor.use_dynamic_bsz=True
        actor_rollout_ref.actor.use_kl_loss=$use_kl_loss
        actor_rollout_ref.actor.kl_loss_coef=$kl_loss_coef
        actor_rollout_ref.actor.kl_loss_type=low_var_kl
        algorithm.use_kl_in_reward=$use_kl_in_reward
        algorithm.kl_ctrl.kl_coef=$kl_coef
        algorithm.lam_token_level=$LAM_TOKEN_LEVEL
        algorithm.gamma_turn_level=$GAMMA_TURN_LEVEL
        actor_rollout_ref.actor.entropy_coeff=0.001
        actor_rollout_ref.actor.ulysses_sequence_parallel_size=1
        actor_rollout_ref.actor.ppo_mini_batch_size=32
        actor_rollout_ref.actor.ppo_micro_batch_size_per_gpu=8
        actor_rollout_ref.actor.clip_ratio=$CLIP_RATIO
        actor_rollout_ref.actor.clip_mode=$CLIP_MODE
        actor_rollout_ref.actor.agg_mode=$AGG_MODE
        actor_rollout_ref.ref.log_prob_micro_batch_size_per_gpu=8
        actor_rollout_ref.rollout.log_prob_micro_batch_size_per_gpu=8
        actor_rollout_ref.rollout.tensor_model_parallel_size=1
        actor_rollout_ref.rollout.max_num_batched_tokens=$(((max_prompt_length + max_response_length) * 2))
        actor_rollout_ref.actor.ppo_max_token_len_per_gpu=$(((max_prompt_length + max_response_length) * 2))
        actor_rollout_ref.rollout.max_num_turns=$MAX_NUM_TURNS
        actor_rollout_ref.rollout.n=$num_rollouts
        actor_rollout_ref.rollout.stop_when_truncated=True
        actor_rollout_ref.actor.optim.lr=$STAGE_LR
        +trainer.val_before_train=True
        +trainer.val_only=False
        +trainer.save_val_generations=True
        +trainer.save_train_generations=True
        trainer.test_freq=$TEST_SAVE_FREQ
        trainer.save_freq=$TEST_SAVE_FREQ
        trainer.remove_previous_ckpt_in_save=False
        trainer.total_epochs=$NUM_EPOCHS
        trainer.total_training_steps=$NUM_EPOCHS
        algorithm.adv_estimator=$algorithm
        reward_model.reward_manager=rema
        reward_model.mask_unfinished_reward=True
        algorithm.filter_groups.enable=True
        trainer.logger='["console","wandb"]'
        $POLICY_EXTRA_FLAGS
        $EXTRA_FLAGS
        ${EMA_MOMENTUM:++actor_rollout_ref.ema_momentum=$EMA_MOMENTUM}
    )
}

preprocess() {
    python data/locomo/data_preprocess.py --max_sessions "$1" \
        --train_convs $NUM_TRAIN_CONVS --val_convs $NUM_VAL_CONVS --test_convs $NUM_TEST_CONVS \
        --seed $DATA_SEED --output_dir "$DATASET_DIR"
}

for STAGE_SESSIONS in "${STAGES[@]}"; do
    echo "[train] STARTING STAGE: $STAGE_SESSIONS sessions (model: $CURRENT_MODEL_PATH)"

    export STAGE_EXP_NAME="curr_${STAGE_SESSIONS}sess_${JOB_ID}_${MAX_NUM_TURNS}turns_${PPO_EPOCHS}ppo_Kl${kl_loss_coef}_${REWARD_TYPE}_${COMPRESSION_PENALTY}addcomp_turn_${algorithm}_${NUM_TRAIN_CONVS}convs${num_rollouts}r_innergrpo${INNER_GPRO_FRAC}sampleQA_vanillaoss120b${EXP_TAG:+_$EXP_TAG}"
    export HYDRA_RUN_DIR=$WORKSPACE/hydra_${STAGE_EXP_NAME}
    mkdir -p "$HYDRA_RUN_DIR"

    set_common_flags
    preprocess "$STAGE_SESSIONS" || { echo "[train] ERROR: preprocessing failed"; exit 1; }

    PYTHONUNBUFFERED=1 python -m verl.rema_trainer.main_ppo \
        +trainer.insert_penalty=0 \
        +trainer.update_bonus=0 \
        +trainer.delete_bonus=0 \
        "${COMMON_FLAGS[@]}" \
        trainer.experiment_name=$STAGE_EXP_NAME \
        +trainer.max_sessions=$STAGE_SESSIONS \
        actor_rollout_ref.rollout.val_kwargs.n=2 \
        +trainer.test_only=False \
        +trainer.test_after_train=False \
        hydra.run.dir=$HYDRA_RUN_DIR 2>&1 | tee "$LOG_DIR/${STAGE_EXP_NAME}.log"

    # Warm-start the next stage from this stage's best-on-val checkpoint.
    CHECKPOINT_ROOT="./checkpoints/$PROJECT_NAME/$STAGE_EXP_NAME"
    ITER_FILE="$CHECKPOINT_ROOT/best_checkpoint_info.txt"
    if [ ! -f "$ITER_FILE" ]; then
        echo "[train] ERROR: no $ITER_FILE for stage $STAGE_SESSIONS"
        exit 1
    fi
    BEST_STEP=$(cat "$ITER_FILE")
    SHARDED_PATH="$CHECKPOINT_ROOT/global_step_${BEST_STEP}/actor"
    CONSOLIDATED_PATH="$CHECKPOINT_ROOT/global_step_${BEST_STEP}/hf_fixed"
    python convert_fsdp_to_hf.py \
        --fsdp_checkpoint_path "$SHARDED_PATH" \
        --huggingface_model_path "$SHARDED_PATH/huggingface" \
        --output_path "$CONSOLIDATED_PATH" \
        --world_size $N_POLICY_GPUS || { echo "[train] ERROR: FSDP->HF conversion failed"; exit 1; }
    CURRENT_MODEL_PATH=$REPO/${CONSOLIDATED_PATH#./}
    echo "[train] stage $STAGE_SESSIONS complete (best step $BEST_STEP). Next model: $CURRENT_MODEL_PATH"
done

# ---------------------------------------------------------------------------
# 5) Final test of the best last-stage model on all 32 sessions
# ---------------------------------------------------------------------------
echo "[train] STARTING FINAL TEST ON 32 SESSIONS"
preprocess 32 || { echo "[train] ERROR: preprocessing failed"; exit 1; }
set_common_flags

export TEST_EXP_NAME="TEST_${STAGE_EXP_NAME}"
export HYDRA_RUN_DIR=$WORKSPACE/hydra_${TEST_EXP_NAME}
mkdir -p "$HYDRA_RUN_DIR"

PYTHONUNBUFFERED=1 python -m verl.rema_trainer.main_ppo \
    "${COMMON_FLAGS[@]}" \
    trainer.experiment_name=$TEST_EXP_NAME \
    +trainer.max_sessions=32 \
    actor_rollout_ref.rollout.val_kwargs.n=1 \
    +trainer.test_only=True \
    ${EMA_MOMENTUM:++actor_rollout_ref.ema_init_path=$REPO/${SHARDED_PATH#./}} \
    hydra.run.dir=$HYDRA_RUN_DIR 2>&1 | tee "$LOG_DIR/${TEST_EXP_NAME}.log"

echo "[train] ALL STAGES AND FINAL TEST COMPLETE"
