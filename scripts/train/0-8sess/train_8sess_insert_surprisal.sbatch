#!/bin/bash
#SBATCH --job-name=memr2_8s_ins_sp
#SBATCH --output=/home/wf287/scratch_pi_qc88/wf287/memory_r2/logs/slurm_%x_%j.out
#SBATCH --partition=gpu_h200 --time=03:55:00
#SBATCH --nodes=1 --ntasks=1 --gres=gpu:h200:2 --cpus-per-task=12 --mem=440G
#
# train_8sess_insert.sbatch with surprisal-based dynamic turns instead of 4 equal chunks per session:
# rollout turn k covers segment k of segment_bounds_json (Qwen2.5-7B base surprisal, tau 366.1,
# 2..7 segments per session, mean 3.6); a session ends after its last segment, max_num_turns=8.
# Fact extractor / memory manager inputs are unchanged (cumulative history). Prompt 16384, response 2048.
# Truncation per role is logged as trunc/{fact,memory}_{state,response} ([TRUNC ...] lines).
# Time: prior insert-only on 2x H200 timeshare ~2h47m (job 31623499) + longer rollouts/val ~25min, +45min.
# Final test is skipped here; submit with: bash scripts/train/0-8sess/submit_train_eval.sh train_8sess_insert_surprisal.sbatch

export STAGES_OVERRIDE=8 NUM_EPOCHS=10 DATA_SEED=2843377488 COMPRESSION_PENALTY=0.3 SKIP_FINAL_TEST=1
export MAX_NUM_TURNS=8 SEGMENTS_FILE=/home/wf287/project_pi_qc88/wf287/memory_r2/src/data/locomo/surprisal_base/segments.json
export EXTRA_FLAGS="+actor_rollout_ref.rollout.insert_only=True +actor_rollout_ref.rollout.use_segment_bounds=True" EXP_TAG=insertonly_surprisal
source /home/wf287/project_pi_qc88/wf287/memory_r2/scripts/train/train_memory_h200x2_timeshare.sbatch
