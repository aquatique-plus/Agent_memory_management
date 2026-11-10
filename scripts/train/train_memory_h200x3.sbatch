#!/bin/bash
#SBATCH --job-name=memr2_train_h200x3
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=2-00:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:3 --cpus-per-task=18 --mem=660G
#
# Same training as train_memory_h200x2_h100x1.sbatch, on one node with 3x H200 (this cluster rejects
# GPU hetjobs across gpu_h200/gpu_h100 with "Invalid qos specification"):
#   GPUs 0-1 -> policy training (same offload setup as the 2x H200 het group)
#   GPU 2    -> gpt-oss-120b (TP=1), started in the batch step (ANSWER_AGENT_LOCAL=1)
# gpt-oss on 1 H200 (141GB) has ~60GB of KV cache (vs a few GB on the H100), so concurrency is raised on
# both ends: server max_num_seqs 128 -> 256, and the reward threads 8 outer x 4 inner -> 16 x 8 (with one
# server judge_llm.py sends one request per thread, so these threads are the real in-flight cap).
# Only throughput changes: the sampled QAs are seeded, so rewards are the same as the H100 setup.
# CPUs: gpu_h200 allows at most 6 CPUs per GPU (48 CPUs / 8 GPUs per node).
#
# Prerequisite (once): sbatch scripts/train/prep_gpt_oss.sbatch
# Submit:              sbatch scripts/train/train_memory_h200x3.sbatch
# Overrides: same as train_memory.sbatch, plus VLLM_GPU_MEM_UTIL / VLLM_MAX_NUM_SEQS for gpt-oss.

ANSWER_AGENT_LOCAL=1
SERVER_GPUS=1
VLLM_TENSOR_PARALLEL=1
export VLLM_GPU_MEM_UTIL=${VLLM_GPU_MEM_UTIL:-0.92}
export VLLM_MAX_NUM_SEQS=${VLLM_MAX_NUM_SEQS:-256}
export REMA_REWARD_MAX_OUTER_WORKERS=${REMA_REWARD_MAX_OUTER_WORKERS:-16}
export REMA_REWARD_MAX_INNER_WORKERS=${REMA_REWARD_MAX_INNER_WORKERS:-8}
N_POLICY_GPUS=2
POLICY_EXTRA_FLAGS="actor_rollout_ref.actor.fsdp_config.param_offload=True \
actor_rollout_ref.actor.fsdp_config.optimizer_offload=True \
actor_rollout_ref.ref.fsdp_config.param_offload=True"

source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_run.sh
