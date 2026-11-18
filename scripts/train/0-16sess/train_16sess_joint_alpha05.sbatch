#!/bin/bash
#SBATCH --job-name=memr2_16s_joint_a05
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=07:00:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# Same as train_16sess_joint.sbatch (Scheme 3, joint training), but with the memory-size free-zone ratio
# alpha = REMA_REWARD_COMPRESSION_THRESHOLD_FRAC lowered from the default 0.7 to 0.5: memory above
# 0.5 x cumulative session tokens is penalized (workers/reward_manager/rema.py).
# Submit: sbatch scripts/train/0-16sess/train_16sess_joint_alpha05.sbatch

export INIT_MODEL_PATH=/home/wf287/scratch_pi_qc88/wf287/memory_r2/checkpoints/curr_8sess_3222791_4turns_2ppo_Kl0.01_persession_0.3addcomp_turn_grpo_2convs8r_innergrpo0.25sampleQA_vanillaoss120b_insertonly/global_step_10/hf_fixed
export STAGES_OVERRIDE=16 NUM_EPOCHS=5 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export REMA_REWARD_COMPRESSION_THRESHOLD_FRAC=0.5
export EXP_TAG=from8sinsert_joint_alpha0.5
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x2_timeshare.sbatch
