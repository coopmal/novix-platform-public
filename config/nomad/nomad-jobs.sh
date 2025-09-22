#!/bin/bash
set -euo pipefail

# =====================================
# Nomad Jobs Bootstrap Script (Idempotent)
# =====================================

# Absolute path to this script's directory
ROOT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOMAD_JOBS_PATH="$ROOT_PATH"

# Nomad jobs in dependency order
JOBS=("consul" "vault" "traefik" "traefik-cert-sync" "redis" "clamav" "wazuh")

# Timeouts
DEFAULT_TIMEOUT=60
CRITICAL_TIMEOUT=120

# Logging
LOG_FILE="/var/log/nomad-jobs.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Wait for a Nomad job to be running
wait_for_job() {
    local job="$1"
    local timeout="${2:-$DEFAULT_TIMEOUT}"
    local elapsed=0

    echo "[$(date)] Waiting for job '$job' to be running (timeout: ${timeout}s)..." | tee -a "$LOG_FILE"
    until nomad status "$job" 2>/dev/null | grep -q "running"; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [ $elapsed -ge $timeout ]; then
            echo "[$(date)] WARNING: Job '$job' did not reach 'running' state after $timeout seconds" | tee -a "$LOG_FILE"
            nomad status "$job" | tee -a "$LOG_FILE"
            # Fail only for critical jobs
            if [[ "$job" == "consul" || "$job" == "vault" ]]; then
                echo "[$(date)] ERROR: Critical job '$job' failed to start." | tee -a "$LOG_FILE"
                exit 1
            else
                return 1
            fi
        fi
    done
    echo "[$(date)] Job '$job' is running." | tee -a "$LOG_FILE"
}

# Show usage
usage() {
    echo "Usage: $0 {start|stop|status|restart|plan}"
    exit 1
}

# Start jobs (idempotent)
start_jobs() {
    for job in "${JOBS[@]}"; do
        echo "[$(date)] Starting job: $job" | tee -a "$LOG_FILE"

        # Skip if already running
        if nomad status "$job" 2>/dev/null | grep -q "running"; then
            echo "[$(date)] Job '$job' already running, skipping..." | tee -a "$LOG_FILE"
            continue
        fi

        nomad run "$NOMAD_JOBS_PATH/$job.nomad" | tee -a "$LOG_FILE"

        # Wait for job to be running
        case "$job" in
            consul|vault)
                wait_for_job "$job" $CRITICAL_TIMEOUT
                ;;
            *)
                wait_for_job "$job" $DEFAULT_TIMEOUT || true
                ;;
        esac
    done
}

# Stop jobs in reverse order
stop_jobs() {
    for (( idx=${#JOBS[@]}-1 ; idx>=0 ; idx-- )); do
        job="${JOBS[idx]}"
        echo "[$(date)] Stopping job: $job" | tee -a "$LOG_FILE"
        if nomad status "$job" &>/dev/null; then
            nomad stop -purge "$job" | tee -a "$LOG_FILE" || true
        else
            echo "[$(date)] Job '$job' not running, skipping stop..." | tee -a "$LOG_FILE"
        fi
    done
}

# Show status for all jobs
status_jobs() {
    for job in "${JOBS[@]}"; do
        echo "[$(date)] Status for job: $job" | tee -a "$LOG_FILE"
        nomad status "$job" || echo "Job not running"
        echo "-----------------------------" | tee -a "$LOG_FILE"
    done
}

# Restart all jobs
restart_jobs() {
    stop_jobs
    sleep 3
    start_jobs
}

# Plan jobs
plan_jobs() {
    for job in "${JOBS[@]}"; do
        echo "[$(date)] Plan for job: $job" | tee -a "$LOG_FILE"
        nomad job plan "$NOMAD_JOBS_PATH/$job.nomad" | tee -a "$LOG_FILE"
        echo "-----------------------------" | tee -a "$LOG_FILE"
    done
}

# Main
if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    start)
        start_jobs
        ;;
    stop)
        stop_jobs
        ;;
    status)
        status_jobs
        ;;
    restart)
        restart_jobs
        ;;
    plan)
        plan_jobs
        ;;
    *)
        usage
        ;;
esac
