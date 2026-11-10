#!/bin/bash
#SBATCH --job-name=memr2_8s_ema
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=07:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# 8-session ablation, 10 epochs, 2x H200 on one node: policy and gpt-oss time-share both GPUs (see train_memory_h200x2_timeshare.sbatch).
# Scheme 3: fact extractor generates with an EMA (m=0.99, per optimizer step) of the jointly trained policy.
# Same DATA_SEED across the ablations (train_8sess_{insert,insert_downweight,joint,ema}.sbatch) so they share the split.
# Submit: sbatch scripts/train/0-8sess/train_8sess_ema.sbatch

export STAGES_OVERRIDE=8 NUM_EPOCHS=10 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export EMA_MOMENTUM=0.99 EXP_TAG=ema0.99
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x2_timeshare.sbatch
