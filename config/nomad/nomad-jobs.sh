#!/bin/bash
set -e

ROOT_PATH="$(pwd)"  # repo root
NOMAD_JOBS_PATH="$ROOT_PATH/nomad"

# List of Nomad jobs in dependency order
JOBS=("consul" "vault" "traefik" "traefik-cert-sync" "redis" "clamav" "wazuh")

# Simple service wait function using Nomad's status
wait_for_job() {
    local job="$1"
    echo "Waiting for $job to be running..."
    until nomad status "$job" | grep -q "running"; do
        sleep 2
    done
    echo "$job is now running."
}

usage() {
    echo "Usage: $0 {start|stop|status|restart|plan}"
    exit 1
}

start_jobs() {
    for job in "${JOBS[@]}"; do
        echo "Starting job: $job"
        nomad run "$NOMAD_JOBS_PATH/$job.nomad"
        
        # Wait for critical dependencies
        case "$job" in
            vault|consul)
                wait_for_job "$job"
                ;;
        esac
    done
}

stop_jobs() {
    # Stop in reverse order
    for (( idx=${#JOBS[@]}-1 ; idx>=0 ; idx-- )) ; do
        job="${JOBS[idx]}"
        echo "Stopping job: $job"
        nomad stop -purge "$job" || true
    done
}

status_jobs() {
    for job in "${JOBS[@]}"; do
        echo "Status for job: $job"
        nomad status "$job" || echo "Job not running"
        echo "-----------------------------"
    done
}

restart_jobs() {
    stop_jobs
    sleep 3
    start_jobs
}

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
