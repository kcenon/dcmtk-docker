#!/usr/bin/env bash
set -euo pipefail

# DCMTK Docker PACS - Unified CLI Wrapper
# Usage: ./pacs.sh <command> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ── Docker Compose detection ─────────────────────
if docker compose version &>/dev/null; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    echo "Error: docker compose is not installed." >&2
    exit 1
fi

# ── Colors (TTY-aware) ───────────────────────────
if [ -t 1 ]; then
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN='' C_RED='' C_YELLOW='' C_CYAN=''
    C_BOLD='' C_DIM='' C_RESET=''
fi

# ── Service definitions ──────────────────────────
ALL_SERVICES=(pacs-server pacs-server-2 storescp-receiver test-client)
VALID_TESTS=(all echo store find move)

# ── Helper functions ─────────────────────────────
info()  { printf "${C_CYAN}>>>${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}>>>${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}>>>${C_RESET} %s\n" "$*"; }
err()   { printf "${C_RED}>>>${C_RESET} %s\n" "$*" >&2; }

ensure_env() {
    if [ ! -f .env ]; then
        info "Creating .env from env.default"
        cp env.default .env
    fi
}

wait_healthy() {
    local timeout="${1:-90}"
    local elapsed=0
    local interval=3
    info "Waiting for services to be healthy (timeout: ${timeout}s)..."

    while [ "${elapsed}" -lt "${timeout}" ]; do
        local all_healthy=true
        for svc in pacs-server pacs-server-2 storescp-receiver; do
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' "${svc}" 2>/dev/null || echo "missing")
            if [ "${health}" != "healthy" ]; then
                all_healthy=false
                break
            fi
        done

        if [ "${all_healthy}" = true ]; then
            ok "All services are healthy"
            return 0
        fi

        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    warn "Timeout waiting for healthy status after ${timeout}s"
    return 1
}

print_status_table() {
    printf "\n"
    printf "${C_BOLD}%-20s %-12s %-14s %-10s${C_RESET}\n" "SERVICE" "STATUS" "AE TITLE" "PORT"
    printf "%-20s %-12s %-14s %-10s\n" "────────────────────" "────────────" "──────────────" "──────────"

    for svc in "${ALL_SERVICES[@]}"; do
        local status ae_title port

        # Container status
        local state health
        state=$(docker inspect --format='{{.State.Status}}' "${svc}" 2>/dev/null || echo "not found")
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "${svc}" 2>/dev/null || echo "-")

        if [ "${state}" = "running" ] && [ "${health}" = "healthy" ]; then
            status="${C_GREEN}healthy${C_RESET}"
        elif [ "${state}" = "running" ] && [ "${health}" = "-" ]; then
            status="${C_YELLOW}running${C_RESET}"
        elif [ "${state}" = "running" ]; then
            status="${C_YELLOW}${health}${C_RESET}"
        else
            status="${C_RED}${state}${C_RESET}"
        fi

        # AE Title from container env
        ae_title=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${svc}" 2>/dev/null \
            | grep '^AE_TITLE=' | cut -d= -f2 || echo "-")
        [ -z "${ae_title}" ] && ae_title="-"

        # Host port mapping
        port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' "${svc}" 2>/dev/null || echo "-")
        [ -z "${port}" ] && port="-"

        printf "%-20s %-22b %-14s %-10s\n" "${svc}" "${status}" "${ae_title}" "${port}"
    done
    printf "\n"
}

# ── Commands ─────────────────────────────────────
cmd_up() {
    ensure_env
    info "Building and starting all services..."
    ${DC} up -d --build

    if wait_healthy 90; then
        print_status_table
    else
        warn "Some services may not be ready yet. Check with: ./pacs.sh status"
        print_status_table
    fi
}

cmd_down() {
    info "Stopping all services..."
    ${DC} down
    ok "All services stopped"
}

cmd_status() {
    # Check if any container exists
    local running
    running=$(docker ps --filter "name=pacs-server" --filter "name=storescp-receiver" --filter "name=test-client" -q 2>/dev/null | wc -l | tr -d ' ')

    if [ "${running}" -eq 0 ]; then
        warn "No services are running. Start with: ./pacs.sh up"
        return 0
    fi

    print_status_table
}

cmd_test() {
    local suite="${1:-all}"

    # Validate suite name
    local valid=false
    for t in "${VALID_TESTS[@]}"; do
        if [ "${suite}" = "${t}" ]; then
            valid=true
            break
        fi
    done

    if [ "${valid}" = false ]; then
        err "Unknown test suite: ${suite}"
        echo "Available: ${VALID_TESTS[*]}"
        exit 1
    fi

    # Check if test-client is running
    local state
    state=$(docker inspect --format='{{.State.Status}}' test-client 2>/dev/null || echo "not found")
    if [ "${state}" != "running" ]; then
        err "test-client container is not running. Start with: ./pacs.sh up"
        exit 1
    fi

    local script
    if [ "${suite}" = "all" ]; then
        script="/tests/test-all.sh"
    else
        script="/tests/test-${suite}.sh"
    fi

    shift 2>/dev/null || true
    info "Running test suite: ${suite}"
    ${DC} exec -T test-client bash "${script}" "$@"
}

cmd_logs() {
    local service="${1:-}"
    shift 2>/dev/null || true

    if [ -n "${service}" ]; then
        ${DC} logs -f "${service}" "$@"
    else
        ${DC} logs -f "$@"
    fi
}

cmd_shell() {
    local state
    state=$(docker inspect --format='{{.State.Status}}' test-client 2>/dev/null || echo "not found")
    if [ "${state}" != "running" ]; then
        err "test-client container is not running. Start with: ./pacs.sh up"
        exit 1
    fi

    info "Opening shell in test-client..."
    ${DC} exec test-client bash
}

cmd_reset() {
    warn "This will stop all services and wipe Docker volumes"
    info "Stopping services..."
    ${DC} down -v

    ok "Volumes removed. Restarting..."
    cmd_up
}

cmd_clean() {
    warn "Removing all containers, images, and volumes for this project"
    ${DC} down -v --rmi local --remove-orphans
    ok "Cleaned up all Docker resources"
}

cmd_echo() {
    local host="${1:-localhost}"
    local port="${2:-11112}"

    # Try host-side echoscu first
    if command -v echoscu &>/dev/null; then
        info "C-ECHO to ${host}:${port} (host)"
        if echoscu "${host}" "${port}"; then
            ok "C-ECHO succeeded"
        else
            err "C-ECHO failed"
            return 1
        fi
    else
        # Fallback: use test-client container
        local state
        state=$(docker inspect --format='{{.State.Status}}' test-client 2>/dev/null || echo "not found")
        if [ "${state}" != "running" ]; then
            err "No local echoscu and test-client is not running"
            exit 1
        fi

        info "C-ECHO to ${host}:${port} (via test-client container)"
        if ${DC} exec -T test-client echoscu "${host}" "${port}"; then
            ok "C-ECHO succeeded"
        else
            err "C-ECHO failed"
            return 1
        fi
    fi
}

cmd_help() {
    cat <<EOF
${C_BOLD}DCMTK Docker PACS - CLI Wrapper${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ./pacs.sh <command> [options]

${C_BOLD}Commands:${C_RESET}
  ${C_GREEN}up${C_RESET}                Build and start all services
  ${C_GREEN}down${C_RESET}              Stop all services
  ${C_GREEN}status${C_RESET}            Show service health, ports, and AE titles
  ${C_GREEN}test${C_RESET} [suite]      Run tests (all, echo, store, find, move)
  ${C_GREEN}logs${C_RESET} [service]    Tail logs (all or specific service)
  ${C_GREEN}shell${C_RESET}             Open bash in the test-client container
  ${C_GREEN}reset${C_RESET}             Stop, wipe volumes, and restart fresh
  ${C_GREEN}clean${C_RESET}             Remove all containers, images, and volumes
  ${C_GREEN}echo${C_RESET} [host] [port] Quick C-ECHO verification
  ${C_GREEN}help${C_RESET}              Show this help message

${C_BOLD}Examples:${C_RESET}
  ./pacs.sh up                    # Start everything
  ./pacs.sh test                  # Run all tests
  ./pacs.sh test echo             # Run only C-ECHO tests
  ./pacs.sh logs pacs-server      # Tail primary PACS logs
  ./pacs.sh echo localhost 11112  # Quick connectivity check
  ./pacs.sh reset                 # Fresh restart with clean data

${C_BOLD}Services:${C_RESET}
  pacs-server        Primary PACS (C-ECHO/STORE/FIND/MOVE)
  pacs-server-2      Secondary PACS for multi-PACS tests
  storescp-receiver  Store SCP receiver for C-MOVE testing
  test-client        Interactive client with all DCMTK SCU tools
EOF
}

# ── Main dispatch ────────────────────────────────
command="${1:-help}"
shift 2>/dev/null || true

case "${command}" in
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    status)  cmd_status "$@" ;;
    test)    cmd_test "$@" ;;
    logs)    cmd_logs "$@" ;;
    shell)   cmd_shell "$@" ;;
    reset)   cmd_reset "$@" ;;
    clean)   cmd_clean "$@" ;;
    echo)    cmd_echo "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        err "Unknown command: ${command}"
        echo "Run './pacs.sh help' for usage."
        exit 1
        ;;
esac
