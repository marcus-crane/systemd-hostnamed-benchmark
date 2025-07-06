#!/bin/bash

# benchmark_mounts.sh - Collect systemd-hostnamed startup performance data
set -euo pipefail

# Configuration
MAX_MOUNTS=${MAX_MOUNTS:-5000}
MOUNT_INCREMENT=${MOUNT_INCREMENT:-100}
START_MOUNTS=${START_MOUNTS:-0}
ITERATIONS_PER_TEST=${ITERATIONS_PER_TEST:-5}
BASE_DIR="/tmp/mount_benchmark"
RAW_RESULTS_FILE="systemd_hostnamed_raw_data.csv"
LOG_FILE="mount_benchmark.log"
RESTART_DELAY=${RESTART_DELAY:-2}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

warn() {
    echo "[WARN] $1" | tee -a "$LOG_FILE"
}

info() {
    echo "[INFO] $1" | tee -a "$LOG_FILE"
}

debug() {
    echo "[DEBUG] $1" | tee -a "$LOG_FILE"
}

check_dependencies() {
    local missing_deps=()
    command -v timeout >/dev/null 2>&1 || missing_deps+=("timeout")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing_deps[*]}"
        error "On EndeavourOS/Arch, install with: sudo pacman -S coreutils"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root to create bind mounts and restart services"
        exit 1
    fi
}

setup() {
    log "Setting up benchmark environment..."

    if [[ -d "$BASE_DIR" ]]; then
        warn "Existing test directory found, cleaning up..."
        cleanup_mounts
        rm -rf "$BASE_DIR"
    fi

    mkdir -p "$BASE_DIR"
    debug "Created base directory: $BASE_DIR"

    if [[ ! -f "$RAW_RESULTS_FILE" ]]; then
        echo "mount_count,iteration,startup_time_ms,success,total_system_mounts,timestamp,notes" > "$RAW_RESULTS_FILE"
        debug "Initialized new raw results file: $RAW_RESULTS_FILE"
    else
        log "Appending to existing results file: $RAW_RESULTS_FILE"
    fi

    if ! systemctl is-active --quiet systemd-hostnamed; then
        log "Starting systemd-hostnamed service..."
        systemctl start systemd-hostnamed
        sleep "$RESTART_DELAY"
    fi

    log "Setup complete. Base directory: $BASE_DIR"
    info "Initial system mount count: $(mount | wc -l)"
    info "Starting from: $START_MOUNTS mounts, increment: $MOUNT_INCREMENT, max: $MAX_MOUNTS"
}

create_mount() {
    local mount_num=$1
    local source_dir="$BASE_DIR/source_$mount_num"
    local target_dir="$BASE_DIR/target_$mount_num"

    if ! mkdir -p "$source_dir" "$target_dir"; then
        error "Failed to create directories for mount $mount_num"
        return 1
    fi

    if ! echo "test_data_$mount_num" > "$source_dir/test_file"; then
        error "Failed to create test file for mount $mount_num"
        return 1
    fi

    if mount --bind "$source_dir" "$target_dir"; then
        return 0
    else
        local mount_error=$?
        error "Failed to create bind mount $mount_num (exit code: $mount_error)"
        rm -f "$source_dir/test_file" 2>/dev/null || true
        rmdir "$target_dir" "$source_dir" 2>/dev/null || true
        return 1
    fi
}

cleanup_mounts() {
    log "Cleaning up test mounts..."

    local cleaned=0
    local failed=0

    while IFS= read -r mount_point; do
        if [[ -n "$mount_point" ]]; then
            if umount "$mount_point" 2>/dev/null; then
                ((cleaned++))
                rmdir "$mount_point" 2>/dev/null || true
            else
                ((failed++))
                warn "Failed to unmount: $mount_point"
            fi
        fi
    done < <(mount | grep "$BASE_DIR" | awk '{print $3}' | sort -r)

    if [[ -d "$BASE_DIR" ]]; then
        find "$BASE_DIR" -type d -name "source_*" -exec rm -rf {} + 2>/dev/null || true
        find "$BASE_DIR" -type d -empty -delete 2>/dev/null || true
    fi

    log "Mount cleanup complete. Cleaned: $cleaned, Failed: $failed"
}

record_iteration() {
    local mount_count=$1
    local iteration=$2
    local total_system_mounts=$3

    debug "Iteration $iteration: Stopping systemd-hostnamed..."

    if ! systemctl stop systemd-hostnamed 2>/dev/null; then
        warn "Failed to stop systemd-hostnamed on iteration $iteration"
        echo "$mount_count,$iteration,0,false,$total_system_mounts,$(date -Iseconds),failed_to_stop" >> "$RAW_RESULTS_FILE"
        return 1
    fi

    sleep "$RESTART_DELAY"

    local startup_start
    local startup_end
    local startup_duration
    local success_flag="false"
    local notes=""

    startup_start=$(date +%s%N)

    debug "Iteration $iteration: Starting systemd-hostnamed..."

    if systemctl start systemd-hostnamed 2>/dev/null; then
        startup_end=$(date +%s%N)
        startup_duration=$(( (startup_end - startup_start) / 1000000 ))
        success_flag="true"
        notes=""

        debug "Iteration $iteration: Startup successful in ${startup_duration}ms"
    else
        startup_end=$(date +%s%N)
        startup_duration=$(( (startup_end - startup_start) / 1000000 ))
        success_flag="false"

        if [[ $startup_duration -gt 85000 && $startup_duration -lt 95000 ]]; then
            notes="systemd_timeout_90s"
        else
            notes="systemd_failure_${startup_duration}ms"
        fi

        warn "systemd-hostnamed failed to start on iteration $iteration (${startup_duration}ms)"
    fi

    echo "$mount_count,$iteration,$startup_duration,$success_flag,$total_system_mounts,$(date -Iseconds),$notes" >> "$RAW_RESULTS_FILE"

    sleep 1

    return 0
}

test_mount_count() {
    local mount_count=$1
    local total_system_mounts
    total_system_mounts=$(mount | wc -l)

    log "Testing $mount_count mounts (total system mounts: $total_system_mounts)"

    if ! systemctl is-active --quiet systemd-hostnamed; then
        warn "systemd-hostnamed is not active at $mount_count mounts"

        if ! systemctl start systemd-hostnamed 2>/dev/null; then
            error "Failed to start systemd-hostnamed at $mount_count mounts"

            for ((i=1; i<=ITERATIONS_PER_TEST; i++)); do
                echo "$mount_count,$i,90000,false,$total_system_mounts,$(date -Iseconds),health_check_failed" >> "$RAW_RESULTS_FILE"
            done

            if [[ $mount_count -ge 3000 ]]; then
                error "CRITICAL: Reached systemd mount parsing limit (~3000 mounts)"
                error "This matches documented systemd Issue #33186"
            fi

            return 1
        fi
        sleep "$RESTART_DELAY"
    fi

    for ((i=1; i<=ITERATIONS_PER_TEST; i++)); do
        info "Mount count $mount_count, iteration $i/$ITERATIONS_PER_TEST"

        if ! record_iteration "$mount_count" "$i" "$total_system_mounts"; then
            warn "Iteration $i failed, continuing with remaining iterations"
        fi
    done

    return 0
}

run_benchmark() {
    log "Starting systemd-hostnamed data collection: start $START_MOUNTS, max $MAX_MOUNTS mounts, increment $MOUNT_INCREMENT, $ITERATIONS_PER_TEST iterations per test"

    local current_mounts=0
    local target_mounts=0

    if [[ $START_MOUNTS -gt 0 ]]; then
        log "Creating initial mounts up to starting offset: $START_MOUNTS..."

        while [[ $current_mounts -lt $START_MOUNTS ]]; do
            current_mounts=$((current_mounts + 1))

            if ! create_mount "$current_mounts"; then
                error "Failed to create mount $current_mounts during initial setup, stopping benchmark"
                return 1
            fi

            if [[ $((current_mounts % 100)) -eq 0 ]]; then
                info "Created $current_mounts mounts (building to start offset)..."
            fi
        done

        log "Reached starting offset: $START_MOUNTS mounts"
    fi

    log "Collecting baseline data at $START_MOUNTS mounts (current system mounts: $(mount | wc -l))"
    test_mount_count "$START_MOUNTS"

    for ((target_mounts=START_MOUNTS + MOUNT_INCREMENT; target_mounts<=MAX_MOUNTS; target_mounts+=MOUNT_INCREMENT)); do
        log "Creating mounts up to $target_mounts..."

        while [[ $current_mounts -lt $target_mounts ]]; do
            current_mounts=$((current_mounts + 1))

            if ! create_mount "$current_mounts"; then
                error "Failed to create mount $current_mounts, stopping benchmark"
                return 1
            fi

            local progress_interval=100
            if [[ $MOUNT_INCREMENT -le 20 ]]; then
                progress_interval=10
            fi

            if [[ $((current_mounts % progress_interval)) -eq 0 ]]; then
                info "Created $current_mounts mounts..."
            fi
        done

        if ! test_mount_count "$current_mounts"; then
            error "Testing failed at $current_mounts mounts, stopping benchmark"
            return 1
        fi

        sleep 2
    done

    log "Data collection complete! Raw data saved to $RAW_RESULTS_FILE"
}

cleanup() {
    log "Performing cleanup..."

    jobs -p | xargs -r kill 2>/dev/null || true

    if ! systemctl is-active --quiet systemd-hostnamed; then
        systemctl start systemd-hostnamed 2>/dev/null || true
        sleep 1
    fi

    cleanup_mounts

    if [[ -d "$BASE_DIR" ]]; then
        rm -rf "$BASE_DIR" || warn "Failed to remove $BASE_DIR"
    fi

    log "Cleanup complete"
}

trap cleanup EXIT
trap 'error "Benchmark interrupted by user"; exit 130' INT
trap 'error "Benchmark terminated"; exit 143' TERM

main() {
    echo "systemd-hostnamed Raw Data Collection"
    echo "===================================="

    check_dependencies
    check_root
    setup

    debug "Testing mount creation functionality..."
    if create_mount "test"; then
        debug "Test mount successful, cleaning up..."
        umount "$BASE_DIR/target_test" 2>/dev/null || true
        rm -rf "$BASE_DIR/source_test" "$BASE_DIR/target_test" 2>/dev/null || true
    else
        error "Test mount failed - check permissions and mount support"
        exit 1
    fi

    run_benchmark

    echo
    log "Data collection completed successfully!"
    log "Raw data file: $RAW_RESULTS_FILE"
    log "Log file: $LOG_FILE"
    echo
    echo "To analyze results, run: python3 analyze_systemd_performance.py $RAW_RESULTS_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

