#!/bin/bash
#SBATCH --job-name=race_cancel
#SBATCH --partition=day
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --output=/gpfs/radev/home/wf287/scratch/memory_r2/logs/slurm_%x_%j.out
#
# Watch two queued jobs; once one has been RUNNING for MIN_RUN seconds (or COMPLETED), scancel the
# other and exit. A job that dies before that (startup crash, OOM in the first steps) does not count:
# FAILED/CANCELLED/TIMEOUT/... is "gone", and the monitor exits leaving the other job queued.
# If both qualify in the same poll, keep the one that started first (tie -> keep JOB_A).
# Idempotent, so overlapping copies can cover more than the 24h day-partition limit:
#   sbatch --export=ALL,JOB_A=<id>,JOB_B=<id> scripts/race_cancel.sbatch
#   sbatch --begin=now+20hours --export=ALL,JOB_A=<id>,JOB_B=<id> scripts/race_cancel.sbatch

set -uo pipefail
JOB_A=${JOB_A:?}; JOB_B=${JOB_B:?}
POLL=${POLL:-60}
MIN_RUN=${MIN_RUN:-1200}   # model load + first rollout/update fit well inside 20 min

log() { echo "[$(date '+%F %T')] $*"; }

# prints: pending | young | started <start epoch> | gone | unknown
status() {
    local st start elapsed
    IFS='|' read -r st start elapsed < <(sacct -nXP -j "$1" -o State,Start,ElapsedRaw 2>/dev/null | head -1)
    case "${st:-}" in
        "") echo unknown ;;
        PENDING|REQUEUED*) echo pending ;;
        RUNNING*|CONFIGURING*|COMPLETING*)
            if [ "${elapsed:-0}" -ge "$MIN_RUN" ]; then echo "started $(date -d "$start" +%s)"; else echo young; fi ;;
        COMPLETED*) echo "started $(date -d "$start" +%s)" ;;
        *) echo gone ;;
    esac
}

log "watching A=$JOB_A B=$JOB_B every ${POLL}s, min run ${MIN_RUN}s"
while true; do
    read -r sa ta <<<"$(status "$JOB_A")"
    read -r sb tb <<<"$(status "$JOB_B")"
    if [ "$sa" = unknown ] || [ "$sb" = unknown ]; then
        :
    elif [ "$sa" = started ] && [ "$sb" = started ]; then
        if [ "$tb" -lt "$ta" ]; then loser=$JOB_A; else loser=$JOB_B; fi
        log "both started (A@$ta B@$tb); cancelling $loser"
        scancel "$loser"; exit 0
    elif [ "$sa" = started ] && [ "$sb" = pending ]; then
        log "$JOB_A started; cancelling $JOB_B"; scancel "$JOB_B"; exit 0
    elif [ "$sb" = started ] && [ "$sa" = pending ]; then
        log "$JOB_B started; cancelling $JOB_A"; scancel "$JOB_A"; exit 0
    elif [ "$sa" = gone ] || [ "$sb" = gone ]; then
        log "a job ended without a healthy run (A=$sa B=$sb); leaving the other alone, exiting"; exit 0
    fi
    sleep "$POLL"
done
