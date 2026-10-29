#!/bin/bash
#SBATCH --job-name=memr2_train_ts
#SBATCH --partition=gpu
#SBATCH --qos=qos_nmi
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:h100:4
#SBATCH --cpus-per-task=48
#SBATCH --mem=800G
#SBATCH --time=2-00:00:00
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Same training as train_memory.sbatch on a single 4x H100 node: policy and the gpt-oss-120b answer
# agent take turns on the same 4 GPUs (rema_trainer/answer_agent_timeshare.py).
#   policy phases (rollout, log-prob, update, checkpoint) -> answer-agent servers stopped
#   reward phases (inner + terminal reward of a step, validation/test reward) -> 2 servers x TP=2 up
# One server start per training step plus one per validation/test reward call; restarts reuse the
# node-local compile cache and the page-cached weights, the first start reads ~65GB from GPFS.
#
# While the servers run the policy must hold almost no GPU memory: vLLM rollout sleeps after each
# generation, and actor/ref/optimizer are offloaded to CPU between phases.
#
# Prerequisite (once): sbatch scripts/train/prep_gpt_oss.sbatch
# Submit:              sbatch scripts/train/train_memory_timeshare.sbatch
# Overrides: same as train_memory.sbatch, plus ANSWER_AGENT_MAX_GPU_MEM_UTIL / ANSWER_AGENT_HEADROOM_GB.

ANSWER_AGENT_TIMESHARE=1
SERVER_GPUS=4
VLLM_TENSOR_PARALLEL=${VLLM_TENSOR_PARALLEL:-2}
N_POLICY_GPUS=4
POLICY_EXTRA_FLAGS="actor_rollout_ref.actor.fsdp_config.param_offload=True \
actor_rollout_ref.actor.fsdp_config.optimizer_offload=True \
actor_rollout_ref.ref.fsdp_config.param_offload=True"

source /gpfs/radev/project/q_chen/wf287/memory_r2/scripts/train/train_memory_run.sh
