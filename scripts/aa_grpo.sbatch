#!/bin/bash
#SBATCH --job-name=aa_grpo
#SBATCH --partition=gpu
#SBATCH --qos=qos_nmi
#SBATCH --gres=gpu:h100:2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=400G
#SBATCH --time=04:00:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Answer-agent GRPO, step 3/3 — paper recipe for ahmedehabb/Memory-R2-answer-agent (sft_cont_step55):
#   STAGE=1  Qwen2.5-7B-Instruct, 5 epochs on the F1>=0.15 gpt-4o trace split
#            (paper run: normal_answer_f1_thr015_4gpu_minibs16_testfreq5). Keeps only the last ckpt.
#   STAGE=2  continue 5 more epochs from STAGE 1's last ckpt exported to HF
#            (scripts/rl/n11_sft_answer_continuation.sh). Keeps every ckpt (save_freq=5); the paper's
#            model is the 5th step of this stage.
# Hyperparameters are the defaults of src/scripts/rl/normal_trainer_answer_f1.sh: GRPO, n=8, T=1.0,
# micro 1/GPU, prompt 12288 / response 1024, KL loss 0.001, lr 1e-6; batch sizes scaled down below.
# Paper ran on 4xH200 with vLLM at 0.8. Here 2xH100 (80GB): sharded over 2 GPUs the fp32 actor params
# are ~14GB/GPU, grads another ~14GB and Adam states ~28GB, so the optimizer and the ref model are
# offloaded to CPU between phases. vLLM 0.8.5 (V1) budgets gpu_memory_utilization against the whole
# process's torch peak, which includes the FSDP actor living in the same worker: 0.6 (48GB) =
# actor 14 + vLLM weights 15 + profiling ~6 + ~12GB KV. 0.4 left no KV at all (job 2852665).
# Memory split only; training math is unchanged (same global batch sizes).
#
# Submit:
#   sbatch --export=ALL,STAGE=1 scripts/aa_grpo.sbatch
#   sbatch --export=ALL,STAGE=2,STAGE1_DIR=<ckpt dir of the STAGE 1 run> scripts/aa_grpo.sbatch
# Resume after a timeout (same N_GPUS only; ckpt shards are per world size): pass the old run's name,
#   sbatch --export=ALL,STAGE=1,EXP_NAME=stage1_thr015_job<old id> scripts/aa_grpo.sbatch
#   (STAGE=2: also pass STAGE1_DIR and the same TOTAL_EPOCHS; raising TOTAL_EPOCHS on resume extends the run.)
# Fewer epochs: --export=ALL,...,TOTAL_EPOCHS=4 (10 steps/epoch).

set -euo pipefail

REPO=/gpfs/radev/project/q_chen/wf287/memory_r2/src
SCRATCH=/gpfs/radev/home/wf287/scratch/memory_r2
CKPT_ROOT=$SCRATCH/checkpoints/answer_agent_grpo
STAGE=${STAGE:?STAGE=1|2 required}

GPFS_CONDA_ENV=/gpfs/radev/home/wf287/project/conda_envs/memory_r2
ENV_PACK=$SCRATCH/envpack/memory_r2.tar.zst   # tar of $GPFS_CONDA_ENV; rebuild after changing the env

# Node-local env + caches, same as eval_locomo.sbatch: importing torch/vllm/verl from the 72k-file
# conda env on GPFS in every ray worker is a small-file storm that can stall GPFS metadata
# (job 2838170 hung in D state at vLLM import). Unpack one big tarball to local disk instead.
export NODE_LOCAL_DIR=/tmp/$USER/aa_grpo_$SLURM_JOB_ID
mkdir -p "$NODE_LOCAL_DIR"
trap 'rm -rf "$NODE_LOCAL_DIR"' EXIT
if [ -f "$ENV_PACK" ]; then
    t0=$(date +%s)
    if ! zstd -q -dc "$ENV_PACK" | tar -xf - -C "$NODE_LOCAL_DIR"; then
        echo "[aa_grpo] ERROR: failed to unpack $ENV_PACK into $NODE_LOCAL_DIR"
        exit 1
    fi
    CONDA_ENV=$NODE_LOCAL_DIR/memory_r2
    echo "[aa_grpo] unpacked conda env to $CONDA_ENV in $(( $(date +%s) - t0 ))s"
else
    CONDA_ENV=$GPFS_CONDA_ENV
    echo "[aa_grpo] WARNING: $ENV_PACK missing, importing from GPFS env $CONDA_ENV"
fi
export PATH=$CONDA_ENV/bin:$PATH
export CONDA_ENV_NAME=""   # env is already on PATH; skip the launcher's conda activate
export VLLM_CACHE_ROOT=$NODE_LOCAL_DIR/vllm_cache
export TORCHINDUCTOR_CACHE_DIR=$NODE_LOCAL_DIR/inductor_cache
export XDG_CACHE_HOME=$NODE_LOCAL_DIR/xdg_cache
mkdir -p "$VLLM_CACHE_ROOT" "$TORCHINDUCTOR_CACHE_DIR" "$XDG_CACHE_HOME"
cp -r "$HOME/.cache/vllm/." "$VLLM_CACHE_ROOT/" 2>/dev/null || true

set -a; source "$REPO/.env"; set +a
export HF_HOME=/gpfs/radev/home/wf287/scratch/hf_cache
export RAY_TMPDIR=/tmp/ray_$SLURM_JOB_ID
mkdir -p "$RAY_TMPDIR" "$CKPT_ROOT"

export TRAIN_FILE=data/sft_rlhf/f1_gt_015/train.parquet
export VAL_FILE=data/sft_rlhf/f1_gt_015/val.parquet
# Paper: batch 64 / mini 16 on ~650 train rows -> 10 steps/epoch, step 50 after 5 epochs.
# Our single gpt-4o trace gives 205 train rows, so batch 20 keeps 10 steps/epoch (205 // 20) and
# mini 5 keeps the paper's 4 actor updates per step.
export N_GPUS=2 TOTAL_EPOCHS=${TOTAL_EPOCHS:-5} TRAIN_BS=20 PPO_MINI_BS=5 PPO_MICRO_BS_PER_GPU=1 ROLLOUT_N=8
export VLLM_GPU_MEMORY_UTILIZATION=0.6
export FSDP_OPTIMIZER_OFFLOAD=True REF_PARAM_OFFLOAD=True
export PROJECT_NAME=answer-agent-grpo

if [ "$STAGE" = "1" ]; then
    export MODEL_PATH=Qwen/Qwen2.5-7B-Instruct
    export EXP_NAME=${EXP_NAME:-stage1_thr015_job${SLURM_JOB_ID}}
    REMOVE_PREV=True
else
    STAGE1_DIR=${STAGE1_DIR:?STAGE1_DIR=<stage-1 ckpt dir> required for STAGE=2}
    LAST=$(cat "$STAGE1_DIR/latest_checkpointed_iteration.txt")
    HF_INIT=$STAGE1_DIR/global_step_${LAST}/hf
    if [ ! -f "$HF_INIT/config.json" ]; then
        echo "[aa_grpo] exporting stage-1 step $LAST -> $HF_INIT"
        python "$REPO/convert_fsdp_to_hf.py" \
            --fsdp_checkpoint_path "$STAGE1_DIR/global_step_${LAST}/actor" \
            --huggingface_model_path Qwen/Qwen2.5-7B-Instruct \
            --output_path "$HF_INIT" \
            --world_size $N_GPUS
    fi
    export MODEL_PATH=$HF_INIT
    export EXP_NAME=${EXP_NAME:-stage2_cont_from_step${LAST}_job${SLURM_JOB_ID}}
    REMOVE_PREV=False
fi

echo "[aa_grpo] stage=$STAGE model=$MODEL_PATH exp=$EXP_NAME ckpt=$CKPT_ROOT/$EXP_NAME"
bash "$REPO/scripts/rl/normal_trainer_answer_f1.sh" \
    trainer.default_local_dir="$CKPT_ROOT/$EXP_NAME" \
    trainer.remove_previous_ckpt_in_save=$REMOVE_PREV
