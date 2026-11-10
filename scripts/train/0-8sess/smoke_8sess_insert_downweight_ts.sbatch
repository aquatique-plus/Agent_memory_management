#!/bin/bash
#SBATCH --job-name=memr2_8s_smoke_ts
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=00:30:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# 30-min smoke test of train_8sess_insert_downweight.sbatch on the 2x H200 timeshare setup: 1 training
# step (NUM_EPOCHS=1) after val_before_train. Checks env unpack, gpt-oss copy to node-local disk, answer-agent
# up/down switching around validation and the step's rewards, and the policy update. Not a real run.
# Submit: sbatch scripts/train/0-8sess/smoke_8sess_insert_downweight_ts.sbatch

export STAGES_OVERRIDE=8 NUM_EPOCHS=1 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3
export EXTRA_FLAGS="+actor_rollout_ref.rollout.insert_only=True +actor_rollout_ref.actor.unretrieved_fact_weight=0.1" EXP_TAG=insertonly_unretw0.1_smoke
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x2_timeshare.sbatch
