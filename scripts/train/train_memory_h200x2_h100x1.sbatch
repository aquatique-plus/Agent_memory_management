#!/bin/bash
#SBATCH --job-name=memr2_train_het
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu --qos=qos_nmi --time=2-00:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=24 --mem=500G
#SBATCH hetjob
#SBATCH --partition=gpu --qos=qos_nmi --time=2-00:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h100:1 --cpus-per-task=8 --mem=160G
#
# Same training as train_memory.sbatch (defaults of _curriculum_learning.sh, paper 2/1/7 split,
# local gpt-oss-120b answer agent), on 3 GPUs via a heterogeneous job:
#   het group 0 (batch step) -> policy training, 2x H200
#   het group 1 (srun step)  -> gpt-oss-120b, 1x H100 (TP=1)
# Slurm starts both groups together, so the job waits until both GPU types are free.
#
# Policy on 2 GPUs: each FSDP shard holds half of the 7B fp32 params + grads + Adam (~60GB), so
# actor/ref/optimizer are offloaded to CPU between phases to leave room for vLLM rollout.
# gpt-oss on 1 H100: the ~65GB weights leave only a few GB of KV cache, so utilization is raised
# and concurrency capped; expect slower reward computation than the 4-GPU answer-agent setup.
#
# Prerequisite (once): sbatch scripts/train/prep_gpt_oss.sbatch
# Submit:              sbatch scripts/train/train_memory_h200x2_h100x1.sbatch
# Overrides: same as train_memory.sbatch, plus VLLM_GPU_MEM_UTIL / VLLM_MAX_NUM_SEQS for gpt-oss.

SERVER_NODE=$(scontrol show hostnames "$SLURM_JOB_NODELIST_HET_GROUP_1")
SERVER_SRUN_ARGS="--het-group=1"
SERVER_GPUS=1
VLLM_TENSOR_PARALLEL=1
export VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-0.92}
export VLLM_MAX_NUM_SEQS=${VLLM_MAX_NUM_SEQS:-128}
N_POLICY_GPUS=2
POLICY_EXTRA_FLAGS="actor_rollout_ref.actor.fsdp_config.param_offload=True \
actor_rollout_ref.actor.fsdp_config.optimizer_offload=True \
actor_rollout_ref.ref.fsdp_config.param_offload=True"

source /gpfs/radev/project/q_chen/wf287/memory_r2/scripts/train/train_memory_run.sh
