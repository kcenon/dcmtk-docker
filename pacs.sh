#!/usr/bin/env bash
set -euo pipefail

# DCMTK Docker PACS - Unified CLI Wrapper
# Usage: ./pacs.sh <command> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Project version - single source of truth is the VERSION file.
if [ -f "${SCRIPT_DIR}/VERSION" ]; then
    PACS_VERSION="$(cat "${SCRIPT_DIR}/VERSION")"
else
    PACS_VERSION="unknown"
fi

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
ALL_SERVICES=(pacs-server pacs-server-2 storescp-receiver mwl-server test-client)
SCP_SERVICES=(pacs-server pacs-server-2 storescp-receiver mwl-server)
VALID_TESTS=(all echo store find move pixeldata transfer-syntax load-smoke worklist adhoc-peers)

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

# Resolve a compose service name to its current container ID under the
# active compose project. Prints the ID on stdout (empty if no container).
service_container_id() {
    local service="$1"
    ${DC} ps -q "${service}" 2>/dev/null | head -n1
}

read_env_value() {
    local key="$1"
    local default="$2"
    local value="${!key:-}"

    if [ -n "${value}" ]; then
        printf '%s' "${value}"
        return 0
    fi

    local file
    for file in .env env.default; do
        if [ -f "${file}" ]; then
            value=$(awk -F= -v key="${key}" '
                { sub(/\r$/, "") }
                $0 ~ /^[[:space:]]*#/ { next }
                {
                    lhs = $1
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
                }
                lhs == key {
                    sub(/^[^=]*=/, "")
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                    print
                    exit
                }
            ' "${file}")
            if [ -n "${value}" ]; then
                printf '%s' "${value}"
                return 0
            fi
        fi
    done

    printf '%s' "${default}"
}

is_loopback_host() {
    case "$1" in
        localhost|127.0.0.1|::1) return 0 ;;
        *) return 1 ;;
    esac
}

wait_for_services() {
    # Wait for the given services to report healthy. Dumps the health status
    # and recent logs of any service that does not become ready in time.
    # Usage: wait_for_services <timeout_seconds> <service> [service ...]
    local timeout="$1"
    shift
    local services=("$@")

    if [ "${#services[@]}" -eq 0 ]; then
        services=("${SCP_SERVICES[@]}")
    fi

    local elapsed=0
    local interval=3
    info "Waiting for services to be healthy: ${services[*]} (timeout: ${timeout}s)..."

    while [ "${elapsed}" -lt "${timeout}" ]; do
        local pending=()
        local svc cid health
        for svc in "${services[@]}"; do
            cid=$(service_container_id "${svc}")
            if [ -z "${cid}" ]; then
                health="missing"
            else
                health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo "missing")
            fi
            if [ "${health}" != "healthy" ]; then
                pending+=("${svc}")
            fi
        done

        if [ "${#pending[@]}" -eq 0 ]; then
            ok "All required services are healthy"
            return 0
        fi

        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    err "Timeout waiting for healthy status after ${timeout}s"
    for svc in "${services[@]}"; do
        local cid health
        cid=$(service_container_id "${svc}")
        if [ -z "${cid}" ]; then
            health="missing"
        else
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo "missing")
        fi
        if [ "${health}" != "healthy" ]; then
            warn "Service ${svc} is not healthy (status: ${health}); recent logs:"
            ${DC} logs --tail=50 "${svc}" 2>&1 || true
        fi
    done
    return 1
}

print_status_table() {
    printf "\n"
    printf "${C_BOLD}%-20s %-12s %-14s %-10s${C_RESET}\n" "SERVICE" "STATUS" "AE TITLE" "PORT"
    printf "%-20s %-12s %-14s %-10s\n" "────────────────────" "────────────" "──────────────" "──────────"

    for svc in "${ALL_SERVICES[@]}"; do
        local status_label status_color ae_title port cid

        cid=$(service_container_id "${svc}")

        # Container status
        local state health
        if [ -z "${cid}" ]; then
            state="not found"
            health="-"
        else
            state=$(docker inspect --format='{{.State.Status}}' "${cid}" 2>/dev/null || echo "not found")
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "${cid}" 2>/dev/null || echo "-")
        fi

        # Keep the color separate from the label so the ANSI escape bytes do not
        # count toward the printf field width; otherwise %-Nb on a colored
        # string misaligns the STATUS column in a TTY. C_* are empty in non-TTY
        # mode, so the uncolored output is unchanged.
        if [ "${state}" = "running" ] && [ "${health}" = "healthy" ]; then
            status_label="healthy"; status_color="${C_GREEN}"
        elif [ "${state}" = "running" ] && [ "${health}" = "-" ]; then
            status_label="running"; status_color="${C_YELLOW}"
        elif [ "${state}" = "running" ]; then
            status_label="${health}"; status_color="${C_YELLOW}"
        else
            status_label="${state}"; status_color="${C_RED}"
        fi

        # AE Title from container env
        if [ -n "${cid}" ]; then
            ae_title=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null \
                | grep '^AE_TITLE=' | cut -d= -f2 || echo "-")
        else
            ae_title="-"
        fi
        [ -z "${ae_title}" ] && ae_title="-"

        # Host port mapping
        if [ -n "${cid}" ]; then
            port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' "${cid}" 2>/dev/null || echo "-")
        else
            port="-"
        fi
        [ -z "${port}" ] && port="-"

        # Pad the uncolored label to the column width first, then wrap the
        # padded field in color via %b so the escape codes sit outside the
        # measured width and the STATUS column aligns with its header.
        local status_field
        printf -v status_field "%-12s" "${status_label}"
        printf "%-20s %b %-14s %-10s\n" "${svc}" "${status_color}${status_field}${C_RESET}" "${ae_title}" "${port}"
    done
    printf "\n"
}

# ── Commands ─────────────────────────────────────
cmd_up() {
    ensure_env
    info "Building and starting all services..."
    ${DC} up -d --build

    if wait_for_services 90 "${SCP_SERVICES[@]}"; then
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
    # Check if any container exists for this compose project
    local running
    running=$(${DC} ps -q 2>/dev/null | wc -l | tr -d ' ')

    if [ "${running}" -eq 0 ]; then
        warn "No services are running. Start with: ./pacs.sh up"
        return 0
    fi

    print_status_table
}

# Wipe the PACS storage directories on the host side, scoped to the
# compose project's PACS service containers. Required before re-running
# test-store.sh against a stack that already holds studies from a prior
# run; the test-client container itself has no Docker CLI and no access
# to the PACS volumes (see issue #19).
#
# The PACS entrypoint re-indexes synthetic test data on every container
# start unless a .indexed marker exists. After wiping storage we recreate
# the marker so the restart leaves PACS empty rather than re-populating
# it from /dicom/testdata. See scripts/entrypoint.sh.
clean_pacs_storage() {
    local svc storage_dir state cid
    storage_dir="/dicom/db"
    for svc in pacs-server pacs-server-2; do
        cid=$(service_container_id "${svc}")
        if [ -z "${cid}" ]; then
            state="not found"
        else
            state=$(docker inspect --format='{{.State.Status}}' "${cid}" 2>/dev/null || echo "not found")
        fi
        if [ "${state}" != "running" ]; then
            warn "${svc} not running; skipping host-side cleanup"
            continue
        fi
        info "Wiping ${svc}:${storage_dir} (host-side cleanup)"
        ${DC} exec -T "${svc}" sh -c "
            find '${storage_dir}' -mindepth 1 -delete 2>/dev/null || true
            mkdir -p \"${storage_dir}/\${AE_TITLE}\"
            touch \"${storage_dir}/\${AE_TITLE}/.indexed\"
        "
    done

    # Restart the PACS services so dcmqrscp re-reads its (now-empty) index.
    info "Restarting PACS services to reload empty index"
    ${DC} restart pacs-server pacs-server-2 >/dev/null
    wait_for_services 60 pacs-server pacs-server-2 || warn "PACS services not healthy after restart"
}

cmd_test() {
    # If the first arg looks like an option (starts with '-'), treat the suite
    # as the default 'all' and forward every arg to the test script. Otherwise
    # consume exactly one positional arg as the suite name.
    local suite="all"
    if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
        suite="$1"
        shift
    fi

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
    local cid state
    cid=$(service_container_id test-client)
    if [ -z "${cid}" ]; then
        state="not found"
    else
        state=$(docker inspect --format='{{.State.Status}}' "${cid}" 2>/dev/null || echo "not found")
    fi
    if [ "${state}" != "running" ]; then
        err "test-client container is not running. Start with: ./pacs.sh up"
        exit 1
    fi

    # Defense in depth: ensure every SCP the tests rely on is healthy before
    # invoking the test entry points (issue #20).
    if ! wait_for_services 60 "${SCP_SERVICES[@]}"; then
        err "Required SCP services are not healthy; aborting test run."
        exit 1
    fi

    # Suites that require PACS to start empty need host-side cleanup,
    # because the in-container helper cannot reach the PACS volumes.
    case "${suite}" in
        store|all) clean_pacs_storage ;;
    esac

    local script
    if [ "${suite}" = "all" ]; then
        script="/tests/test-all.sh"
    else
        script="/tests/test-${suite}.sh"
    fi

    info "Running test suite: ${suite}"
    ${DC} exec -T test-client bash "${script}" "$@"
}

cmd_logs() {
    # Only consume the first arg as a service name when it doesn't start with
    # '-'. This preserves docker compose log options such as --tail, --since,
    # and --timestamps when no service is specified.
    local service=""
    if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
        service="$1"
        shift
    fi

    if [ -n "${service}" ]; then
        ${DC} logs -f "${service}" "$@"
    else
        ${DC} logs -f "$@"
    fi
}

cmd_shell() {
    local cid state
    cid=$(service_container_id test-client)
    if [ -z "${cid}" ]; then
        state="not found"
    else
        state=$(docker inspect --format='{{.State.Status}}' "${cid}" 2>/dev/null || echo "not found")
    fi
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

# Remove host-side generated DICOM data while preserving source fixtures.
# The test-client bind mounts ./data into /dicom/testdata and writes synthetic
# CT/MR/CR studies under data/ct, data/mr, data/cr (see issue #37). The
# data/dicom-templates directory is checked into git and must never be touched.
#
# Usage: ./pacs.sh clean-data [--dry-run]
cmd_clean_data() {
    local dry_run=false
    if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
        dry_run=true
    fi

    # Resolve the data directory to an absolute path and refuse to act if it
    # is missing — guards against running from an unexpected CWD.
    local data_root="${SCRIPT_DIR}/data"
    if [ ! -d "${data_root}" ]; then
        err "data directory not found at ${data_root}"
        exit 1
    fi

    # Narrow allowlist of generated subdirectories. Anything not listed here
    # (notably data/dicom-templates) is left untouched.
    local generated_dirs=(ct mr cr dicom-output received)

    local removed=0
    local sub abs
    for sub in "${generated_dirs[@]}"; do
        abs="${data_root}/${sub}"
        if [ ! -e "${abs}" ]; then
            continue
        fi
        # Safety: refuse to delete anything that is not under data_root.
        case "${abs}" in
            "${data_root}/"*) ;;
            *) err "Refusing to remove ${abs}: outside ${data_root}"; exit 1 ;;
        esac
        if [ "${dry_run}" = true ]; then
            info "[dry-run] would remove ${abs}"
        else
            info "Removing ${abs}"
            rm -rf -- "${abs}"
        fi
        removed=$((removed + 1))
    done

    if [ "${removed}" -eq 0 ]; then
        ok "No generated data to remove"
    elif [ "${dry_run}" = true ]; then
        ok "Dry run complete (${removed} path(s) would be removed)"
    else
        ok "Removed ${removed} generated data path(s); source fixtures preserved"
    fi
}

cmd_echo() {
    local host="${1:-localhost}"
    local port="${2:-11112}"
    local called_ae="${3:-}"
    local calling_ae="${4:-}"
    local pacs1_ae pacs2_ae storescp_ae
    local pacs1_host_port pacs2_host_port storescp_host_port internal_port

    pacs1_ae=$(read_env_value "PACS1_AE_TITLE" "DCMTK_PACS")
    pacs2_ae=$(read_env_value "PACS2_AE_TITLE" "DCMTK_PAC2")
    storescp_ae=$(read_env_value "STORESCP_AE_TITLE" "STORE_SCP")
    pacs1_host_port=$(read_env_value "PACS1_HOST_PORT" "11112")
    pacs2_host_port=$(read_env_value "PACS2_HOST_PORT" "11113")
    storescp_host_port=$(read_env_value "STORESCP_HOST_PORT" "11114")
    internal_port=$(read_env_value "DICOM_PORT" "11112")

    if [ -z "${called_ae}" ]; then
        if is_loopback_host "${host}" && [ "${port}" = "${pacs2_host_port}" ]; then
            called_ae="${pacs2_ae}"
        elif is_loopback_host "${host}" && [ "${port}" = "${storescp_host_port}" ]; then
            called_ae="${storescp_ae}"
        else
            called_ae="${pacs1_ae}"
        fi
    fi
    if [ -z "${calling_ae}" ]; then
        calling_ae=$(read_env_value "TEST_SCU_AE_TITLE" "TEST_SCU")
    fi

    # Try host-side echoscu first
    if command -v echoscu &>/dev/null; then
        info "C-ECHO to ${host}:${port} (host, called AE: ${called_ae}, calling AE: ${calling_ae})"
        if echoscu -aet "${calling_ae}" -aec "${called_ae}" "${host}" "${port}"; then
            ok "C-ECHO succeeded"
        else
            err "C-ECHO failed"
            return 1
        fi
    else
        # Fallback: use test-client container
        local cid state
        cid=$(service_container_id test-client)
        if [ -z "${cid}" ]; then
            state="not found"
        else
            state=$(docker inspect --format='{{.State.Status}}' "${cid}" 2>/dev/null || echo "not found")
        fi
        if [ "${state}" != "running" ]; then
            err "No local echoscu and test-client is not running"
            exit 1
        fi

        local target_host="${host}"
        local target_port="${port}"
        if is_loopback_host "${host}"; then
            case "${port}" in
                "${pacs1_host_port}") target_host="pacs-server"; target_port="${internal_port}" ;;
                "${pacs2_host_port}") target_host="pacs-server-2"; target_port="${internal_port}" ;;
                "${storescp_host_port}") target_host="storescp-receiver"; target_port="${internal_port}" ;;
            esac
        fi

        info "C-ECHO to ${target_host}:${target_port} (via test-client container, called AE: ${called_ae}, calling AE: ${calling_ae})"
        if ${DC} exec -T test-client echoscu -aet "${calling_ae}" -aec "${called_ae}" "${target_host}" "${target_port}"; then
            ok "C-ECHO succeeded"
        else
            err "C-ECHO failed"
            return 1
        fi
    fi
}

cmd_help() {
    cat <<EOF
${C_BOLD}DCMTK Docker PACS - CLI Wrapper${C_RESET} ${C_DIM}v${PACS_VERSION}${C_RESET}

${C_BOLD}Usage:${C_RESET}
  ./pacs.sh <command> [options]

${C_BOLD}Commands:${C_RESET}
  ${C_GREEN}up${C_RESET}                Build and start all services
  ${C_GREEN}down${C_RESET}              Stop all services
  ${C_GREEN}status${C_RESET}            Show service health, ports, and AE titles
  ${C_GREEN}test${C_RESET} [suite]      Run tests (all, echo, store, find, move, pixeldata,
                    transfer-syntax, load-smoke, worklist, adhoc-peers)
                    Note: the restricted-mode suite is CI-only (compose overlay),
                    not a './pacs.sh test' target
  ${C_GREEN}logs${C_RESET} [service]    Tail logs (all or specific service)
  ${C_GREEN}shell${C_RESET}             Open bash in the test-client container
  ${C_GREEN}reset${C_RESET}             Stop, wipe volumes, and restart fresh
  ${C_GREEN}clean${C_RESET}             Remove all containers, images, and volumes
  ${C_GREEN}clean-data${C_RESET} [--dry-run]
                    Remove host-side generated DICOM data (data/ct, data/mr,
                    data/cr, data/dicom-output, data/received); preserves
                    data/dicom-templates source fixtures
  ${C_GREEN}echo${C_RESET} [host] [port] [called-ae] [calling-ae]
                    Quick C-ECHO verification
  ${C_GREEN}add-peer${C_RESET} <name> <ae> <host> <port>
                    Register an ad-hoc C-MOVE destination and restart PACS
  ${C_GREEN}version${C_RESET}           Show the dcmtk-docker version
  ${C_GREEN}help${C_RESET}              Show this help message

${C_BOLD}Examples:${C_RESET}
  ./pacs.sh up                    # Start everything
  ./pacs.sh test                  # Run all tests
  ./pacs.sh test echo             # Run only C-ECHO tests
  ./pacs.sh logs pacs-server      # Tail primary PACS logs
  ./pacs.sh echo localhost 11112             # Primary PACS C-ECHO
  ./pacs.sh echo localhost 11113 DCMTK_PAC2  # Secondary PACS C-ECHO
  ./pacs.sh reset                 # Fresh restart with clean data

${C_BOLD}Services:${C_RESET}
  pacs-server        Primary PACS (C-ECHO/STORE/FIND/MOVE)
  pacs-server-2      Secondary PACS for multi-PACS tests
  storescp-receiver  Store SCP receiver for C-MOVE testing
  test-client        Interactive client with all DCMTK SCU tools
EOF
}

# ── Ad-hoc C-MOVE peer registration ──────────────
# Register an ad-hoc C-MOVE destination by appending to EXTRA_PEERS in .env and
# restarting the PACS so dcmqrscp re-reads its HostTable. dcmqrscp only loads its
# config at startup, so a restart is required for the new destination to apply.
cmd_add_peer() {
    local name="${1:-}" ae="${2:-}" host="${3:-}" port="${4:-}"
    if [ -z "${name}" ] || [ -z "${ae}" ] || [ -z "${host}" ] || [ -z "${port}" ]; then
        err "Usage: ./pacs.sh add-peer <name> <ae-title> <host> <port>"
        echo "  Registers an ad-hoc C-MOVE destination (sets EXTRA_PEERS) and"
        echo "  restarts the PACS so dcmqrscp picks it up."
        exit 1
    fi
    ensure_env
    # Validate fields so a malformed entry never reaches EXTRA_PEERS or the
    # HostTable injector (see scripts/inject-extra-peers.sh). The space- and
    # colon-delimited EXTRA_PEERS format forbids those characters in fields.
    case "${name}" in ""|*[!A-Za-z0-9_]*) err "Invalid peer name '${name}' (letters, digits, underscore only)"; exit 1 ;; esac
    case "${ae}"   in ""|*[!A-Za-z0-9_]*) err "Invalid AE title '${ae}' (letters, digits, underscore only)"; exit 1 ;; esac
    case "${host}" in ""|*[!A-Za-z0-9.-]*) err "Invalid host '${host}'"; exit 1 ;; esac
    case "${port}" in ""|*[!0-9]*) err "Invalid port '${port}' (must be numeric)"; exit 1 ;; esac
    local entry="${name}=${ae}:${host}:${port}"
    local current newval
    current=$(read_env_value "EXTRA_PEERS" "")
    if [ -n "${current}" ]; then
        newval="${current} ${entry}"
    else
        newval="${entry}"
    fi
    if grep -q '^EXTRA_PEERS=' .env 2>/dev/null; then
        sed -i.bak "s|^EXTRA_PEERS=.*|EXTRA_PEERS=${newval}|" .env && rm -f .env.bak
    else
        echo "EXTRA_PEERS=${newval}" >> .env
    fi
    info "Registered ad-hoc peer: ${entry}"
    info "Restarting PACS services to apply..."
    ${DC} up -d pacs-server pacs-server-2
    if wait_for_services 60 pacs-server pacs-server-2; then
        ok "Peer '${name}' is now a valid C-MOVE destination"
        info "EXTRA_PEERS=${newval}"
    else
        warn "PACS services not healthy after restart"
    fi
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
    clean-data) cmd_clean_data "$@" ;;
    echo)    cmd_echo "$@" ;;
    add-peer) cmd_add_peer "$@" ;;
    version|--version|-v) echo "dcmtk-docker ${PACS_VERSION}" ;;
    help|-h|--help) cmd_help ;;
    *)
        err "Unknown command: ${command}"
        echo "Run './pacs.sh help' for usage."
        exit 1
        ;;
esac
