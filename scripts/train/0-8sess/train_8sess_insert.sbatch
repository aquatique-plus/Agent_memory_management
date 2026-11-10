#!/bin/bash
#SBATCH --job-name=memr2_8s_insert
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=05:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:3 --cpus-per-task=18 --mem=660G
#
# 8-session ablation, 10 epochs, 3x H200 on one node: 2 policy + 1 gpt-oss (see train_memory_h200x3.sbatch).
# Scheme 1: every memory op is an INSERT of an extracted fact; only fact-extractor rows get gradients.
# Same DATA_SEED across the ablations (train_8sess_{insert,insert_downweight,joint,ema}.sbatch) so they share the split.
# Submit: sbatch scripts/train/0-8sess/train_8sess_insert.sbatch

export STAGES_OVERRIDE=8 NUM_EPOCHS=10 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export EXTRA_FLAGS="+actor_rollout_ref.rollout.insert_only=True" EXP_TAG=insertonly
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x3.sbatch
