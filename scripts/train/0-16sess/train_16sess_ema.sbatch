#!/bin/bash
#SBATCH --job-name=memr2_16s_ema
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=07:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# 16-session ablation, 5 epochs, warm-started from the best 8-session insert-only checkpoint (global_step_10/hf_fixed).
# 2x H200 on one node: policy and gpt-oss time-share both GPUs (see train_memory_h200x2_timeshare.sbatch).
# Scheme 2: fact extractor generates with an EMA (m=0.99, per optimizer step) of the jointly trained policy.
# Same DATA_SEED as the 8-session ablations and across train_16sess_{frozen_extractor,ema,joint}.sbatch, so they share the split.
# Submit: sbatch scripts/train/0-16sess/train_16sess_ema.sbatch

export INIT_MODEL_PATH=/home/wf287/scratch_pi_qc88/wf287/memory_r2/checkpoints/curr_8sess_3222791_4turns_2ppo_Kl0.01_persession_0.3addcomp_turn_grpo_2convs8r_innergrpo0.25sampleQA_vanillaoss120b_insertonly/global_step_10/hf_fixed
export STAGES_OVERRIDE=16 NUM_EPOCHS=5 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export EMA_MOMENTUM=0.99 EXP_TAG=from8sinsert_ema0.99
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x2_timeshare.sbatch
