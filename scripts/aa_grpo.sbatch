#!/bin/bash
#SBATCH --job-name=aa_grpo
#SBATCH --partition=gpu_h200
#SBATCH --gres=gpu:h200:4
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=400G
#SBATCH --time=08:00:00
#SBATCH --output=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#
# Answer-agent GRPO, step 3/3 — paper recipe for ahmedehabb/Memory-R2-answer-agent (sft_cont_step55):
#   STAGE=1  Qwen2.5-7B-Instruct, 5 epochs on the F1>=0.15 gpt-4o trace split
#            (paper run: normal_answer_f1_thr015_4gpu_minibs16_testfreq5). Keeps only the last ckpt.
#   STAGE=2  continue 5 more epochs from STAGE 1's last ckpt exported to HF
#            (scripts/rl/n11_sft_answer_continuation.sh). Keeps every ckpt (save_freq=5); the paper's
#            model is the 5th step of this stage.
# Hyperparameters follow upstream (scripts/rl/n11_sft_answer_continuation.sh + normal_trainer_answer_f1.sh):
# GRPO, 4 GPUs, batch 64 / mini 16, micro 1/GPU, n=8, T=1.0, prompt 12288 / response 1024, KL loss 0.001,
# lr 1e-6, vLLM gpu_memory_utilization 0.8.
#
# Submit:
#   sbatch --export=ALL,STAGE=1 scripts/aa_grpo.sbatch
#   sbatch --export=ALL,STAGE=2,STAGE1_DIR=<ckpt dir of the STAGE 1 run> scripts/aa_grpo.sbatch

set -euo pipefail

REPO=/nfs/roberts/project/pi_qc88/wf287/memory_r2/src
SCRATCH=/nfs/roberts/scratch/pi_qc88/wf287/memory_r2
CKPT_ROOT=$SCRATCH/checkpoints/answer_agent_grpo
STAGE=${STAGE:?STAGE=1|2 required}

export PATH=/nfs/roberts/project/pi_qc88/wf287/conda-envs/memory_r2/bin:$PATH
export CONDA_ENV_NAME=""   # env is already on PATH; skip the launcher's conda activate
set -a; source "$REPO/.env"; set +a
export HF_HOME=/nfs/roberts/scratch/pi_qc88/wf287/hf_cache
export RAY_TMPDIR=/tmp/ray_$SLURM_JOB_ID
mkdir -p "$RAY_TMPDIR" "$CKPT_ROOT" "$HF_HOME"

export TRAIN_FILE=data/sft_rlhf/f1_gt_015/train.parquet
export VAL_FILE=data/sft_rlhf/f1_gt_015/val.parquet
export N_GPUS=4 TOTAL_EPOCHS=5 TRAIN_BS=64 PPO_MINI_BS=16 PPO_MICRO_BS_PER_GPU=1 ROLLOUT_N=8
export VLLM_GPU_MEMORY_UTILIZATION=0.8
export PROJECT_NAME=answer-agent-grpo

if [ "$STAGE" = "1" ]; then
    export MODEL_PATH=Qwen/Qwen2.5-7B-Instruct
    export EXP_NAME=stage1_thr015_job${SLURM_JOB_ID}
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
            --world_size 4
    fi
    export MODEL_PATH=$HF_INIT
    export EXP_NAME=stage2_cont_from_step${LAST}_job${SLURM_JOB_ID}
    REMOVE_PREV=False
fi

echo "[aa_grpo] stage=$STAGE model=$MODEL_PATH exp=$EXP_NAME ckpt=$CKPT_ROOT/$EXP_NAME"
bash "$REPO/scripts/rl/normal_trainer_answer_f1.sh" \
    trainer.default_local_dir="$CKPT_ROOT/$EXP_NAME" \
    trainer.remove_previous_ckpt_in_save=$REMOVE_PREV
