#!/bin/bash
# Submit a training sbatch that sets SKIP_FINAL_TEST=1 (e.g. train_8sess_insert_surprisal.sbatch) and its
# test eval (scripts/eval_locomo.sbatch), which starts after training succeeds.
# Eval: best-on-val checkpoint, prompt 28672 / response 4096, gpt-oss-120b answer agent, gpt-4o-mini judge,
# same EXTRA_FLAGS as training; 6 turns (runs with SEGMENTS_FILE: 8, one per surprisal segment).
# Eval runs on 2x H100 for 1.5h: gpt-oss on one (TP=1, small KV cache), memory manager on the other (offloaded).
# Usage: bash scripts/train/0-8sess/submit_train_eval.sh train_8sess_insert_surprisal.sbatch
#        bash scripts/train/0-8sess/submit_train_eval.sh --eval-only <train_job_id> <train sbatch>
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=$(cd "$DIR/../.." && pwd)
EVAL_ONLY_JOB=""
if [ "$1" = "--eval-only" ]; then EVAL_ONLY_JOB=$2; shift 2; fi
TRAIN_SBATCH=$DIR/$(basename "$1")
[ -f "$TRAIN_SBATCH" ] || { echo "no $TRAIN_SBATCH"; exit 1; }

# Read the experiment settings from the training sbatch.
EXTRA_FLAGS=$(sed -n 's/^export EXTRA_FLAGS="\([^"]*\)".*/\1/p' "$TRAIN_SBATCH")
EXP_TAG=$(sed -n 's/^export EXTRA_FLAGS=.* EXP_TAG=\(.*\)$/\1/p' "$TRAIN_SBATCH")
SEGMENTS_FILE=$(sed -n 's/^export MAX_NUM_TURNS=[0-9]* SEGMENTS_FILE=\(.*\)$/\1/p' "$TRAIN_SBATCH")
EVAL_FLAGS=$(echo "$EXTRA_FLAGS" | tr ' ' '\n' | tr '\n' ' ')
EVAL_TURNS=6
[ -n "$SEGMENTS_FILE" ] && EVAL_TURNS=8

TRAIN_JOB=${EVAL_ONLY_JOB:-$(sbatch --parsable "$TRAIN_SBATCH")}
EVAL_JOB=$(sbatch --parsable --dependency=afterok:"$TRAIN_JOB" --job-name="memr2_eval_${EXP_TAG}" \
    --partition=gpu_h100 --gres=gpu:h100:2 --cpus-per-task=12 --mem=240G --time=01:30:00 \
    --export=ALL,CKPT_TRAIN_JOB="$TRAIN_JOB",RUN_TAG="test8_${EXP_TAG}_oss120b",ANSWER_AGENT_MODEL=openai/gpt-oss-120b,LLM_JUDGE=1,JUDGE_MODEL=gpt-4o-mini,MAX_NUM_TURNS="$EVAL_TURNS",SEGMENTS_FILE="$SEGMENTS_FILE",MM_PARAM_OFFLOAD=1,VLLM_GPU_MEM_UTIL=0.92,VLLM_MAX_NUM_SEQS=128,EXTRA_HYDRA_OVERRIDES="$EVAL_FLAGS" \
    "$SCRIPTS/eval_locomo.sbatch")
echo -e "$(date +%F)\t$EXP_TAG\ttrain=$TRAIN_JOB\teval=$EVAL_JOB\tturns_eval=$EVAL_TURNS\tflags=$EVAL_FLAGS"
