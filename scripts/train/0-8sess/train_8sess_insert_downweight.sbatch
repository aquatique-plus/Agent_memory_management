#!/bin/bash
#SBATCH --job-name=memr2_8s_insdw
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu --qos=qos_nmi --time=05:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=24 --mem=500G
#SBATCH hetjob
#SBATCH --partition=gpu --qos=qos_nmi --time=05:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h100:1 --cpus-per-task=8 --mem=160G
#
# 8-session ablation, 10 epochs, 2x H200 policy + 1x H100 gpt-oss (see train_memory_h200x2_h100x1.sbatch).
# Scheme 1b: scheme 1 (insert-only) plus: tokens of facts that no QA behind their reward retrieved get weight
# 0.1 in the policy loss, for positive advantages only.
# Same DATA_SEED across the ablations (train_8sess_{insert,insert_downweight,joint,ema}.sbatch) so they share the split.
# Submit: sbatch scripts/train/0-8sess/train_8sess_insert_downweight.sbatch

export STAGES_OVERRIDE=8 NUM_EPOCHS=10 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export EXTRA_FLAGS="+actor_rollout_ref.rollout.insert_only=True +actor_rollout_ref.actor.unretrieved_fact_weight=0.1" EXP_TAG=insertonly_unretw0.1
source /gpfs/radev/project/q_chen/wf287/memory_r2/scripts/train/train_memory_h200x2_h100x1.sbatch
