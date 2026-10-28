#!/bin/bash
#SBATCH --job-name=memr2_train
#SBATCH --partition=gpu
#SBATCH --qos=qos_nmi
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:h100:4
#SBATCH --cpus-per-task=48
#SBATCH --mem=800G
#SBATCH --time=2-00:00:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Memory-management (Extractor + Manager) LoGo-GRPO training with the defaults of
# src/scripts/examples/_curriculum_learning.sh, the README's training entry point:
# Qwen2.5-7B-Instruct, STAGES=(32), 4 turns, 8 rollouts, inner GRPO frac 0.25 / inner_n 4,
# lambda_comp 0.3, KL loss 0.01, lr 2e-6, 50 steps, ckpt/test every 5; then a final 32-session test.
#
# Deviations from that script:
#   - Data: paper split (train conv-43,47 / val conv-44 / test 7 held-out convs) instead of 1/1/8,
#     which would put conv-47 in test. Regenerated per stage into scratch, never into src/data.
#   - Answer agent: gpt-oss-120b served locally (2nd node) instead of the Together API.
#   - lambda_comp 0.3 (the paper default per the README) instead of the script's 0.2.
#
#   node 0 (batch step) -> policy training, 4 GPUs
#   node 1 (srun step)  -> gpt-oss-120b vLLM servers, 4 GPUs (2 servers x TP=2)
#
# Prerequisite (once): sbatch scripts/train/prep_gpt_oss.sbatch
# Submit:              sbatch scripts/train/train_memory.sbatch
# Overrides (env, e.g. `sbatch --export=ALL,STAGES_OVERRIDE="8 16 32" scripts/train/train_memory.sbatch`):
#   STAGES_OVERRIDE        session curriculum (default "32"; paper curriculum is "8 16 32")
#   COMPRESSION_PENALTY    lambda_comp (default 0.3)
#   VLLM_TENSOR_PARALLEL   gpt-oss TP per server (default 2)
#   SERVER_WAIT_TIMEOUT    seconds to wait for gpt-oss servers (default 3600)

NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
SERVER_NODE=${NODES[1]}
SERVER_SRUN_ARGS="--nodes=1 --ntasks=1 --nodelist=$SERVER_NODE"
SERVER_GPUS=4
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-2}
N_POLICY_GPUS=4
POLICY_EXTRA_FLAGS=""

source /gpfs/radev/project/q_chen/wf287/memory_r2/scripts/train/train_memory_run.sh
