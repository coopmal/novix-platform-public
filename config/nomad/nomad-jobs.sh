#!/bin/bash
set -euo pipefail

ROOT_PATH="$(pwd)"                # Repo root
NOMAD_JOBS_PATH="$ROOT_PATH/nomad"

# Nomad jobs in dependency order
JOBS=("consul" "vault" "traefik" "traefik-cert-sync" "redis" "clamav" "wazuh")

# Timeout for waiting for jobs (seconds)
DEFAULT_TIMEOUT=60
CRITICAL_TIMEOUT=120

# Wait for a job to be running with timeout
wait_for_job() {
    local job="$1"
    local timeout="${2:-$DEFAULT_TIMEOUT}"
    local elapsed=0

    echo "Waiting for job '$job' to be running (timeout: ${timeout}s)..."
    until nomad status "$job" 2>/dev/null | grep -q "running"; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [ $elapsed -ge $timeout ]; then
            echo "ERROR: Job '$job' did not reach 'running' state after $timeout seconds"
            nomad status "$job"
            exit 1
        fi
    done
    echo "Job '$job' is now running."
}

usage() {
    echo "Usage: $0 {start|stop|status|restart|plan}"
    exit 1
}

# Start jobs in order
start_jobs() {
    for job in "${JOBS[@]}"; do
        echo "Starting job: $job"
        nomad run "$NOMAD_JOBS_PATH/$job.nomad"

        # Wait for critical dependencies or long-running jobs
        case "$job" in
            consul|vault)
                wait_for_job "$job" $CRITICAL_TIMEOUT
                ;;
            *)
                wait_for_job "$job" $DEFAULT_TIMEOUT
                ;;
        esac
    done
}

# Stop jobs in reverse order
stop_jobs() {
    for (( idx=${#JOBS[@]}-1 ; idx>=0 ; idx-- )); do
        job="${JOBS[idx]}"
        echo "Stopping job: $job"
        nomad stop -purge "$job" || true
    done
}

# Show status for all jobs
status_jobs() {
    for job in "${JOBS[@]}"; do
        echo "Status for job: $job"
        nomad status "$job" || echo "Job not running"
        echo "-----------------------------"
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
        echo "Plan for job: $job"
        nomad job plan "$NOMAD_JOBS_PATH/$job.nomad"
        echo "-----------------------------"
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
