#!/bin/bash
#SBATCH --job-name=memr2_train_h200x2_ts
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=2-00:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# Same training as train_memory_h200x3.sbatch on 2x H200: the policy and the gpt-oss-120b answer agent
# take turns on the same 2 GPUs (rema_trainer/answer_agent_timeshare.py, as in train_memory_timeshare.sbatch).
#   policy phases (rollout, log-prob, update, checkpoint) -> answer-agent servers stopped
#   reward phases (inner + terminal reward of a step, validation/test reward) -> 2 servers x TP=1 up
# While the servers run, vLLM rollout sleeps and actor/ref/optimizer are offloaded to CPU.
# Two servers each with a whole H200, so the reward threads keep the h200x3 concurrency (16 outer x 8 inner).
# CPUs: gpu_h200 allows at most 6 CPUs per GPU.
#
# Prerequisite (once): sbatch scripts/train/prep_gpt_oss.sbatch
# Submit:              sbatch scripts/train/train_memory_h200x2_timeshare.sbatch
# Overrides: same as train_memory.sbatch, plus ANSWER_AGENT_MAX_GPU_MEM_UTIL / ANSWER_AGENT_HEADROOM_GB.

ANSWER_AGENT_TIMESHARE=1
SERVER_GPUS=2
VLLM_TENSOR_PARALLEL=1
export REMA_REWARD_MAX_OUTER_WORKERS=${REMA_REWARD_MAX_OUTER_WORKERS:-16}
export REMA_REWARD_MAX_INNER_WORKERS=${REMA_REWARD_MAX_INNER_WORKERS:-8}
N_POLICY_GPUS=2
POLICY_EXTRA_FLAGS="actor_rollout_ref.actor.fsdp_config.param_offload=True \
actor_rollout_ref.actor.fsdp_config.optimizer_offload=True \
actor_rollout_ref.ref.fsdp_config.param_offload=True"

source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_run.sh
