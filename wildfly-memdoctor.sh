#!/bin/bash
###############################################################################
# WildFly MemDoctor v1.0
# ─────────────────────────────────────────────────────────────────────────────
# Java Heap / Stack / Thread Dump Analyzer for WildFly Application Servers
#
# PURPOSE:
#   1. Captures heap dumps, thread dumps, and stack traces from WildFly JVM
#   2. Analyzes dumps to identify memory leak suspects
#   3. Logs warnings BEFORE the server crashes (threshold-based)
#   4. Generates daily reports with problems + suggested solutions
#   5. Works fully offline (air-gapped) — no internet required on PROD
#
# USAGE:
#   chmod +x wildfly-memdoctor.sh
#   ./wildfly-memdoctor.sh [command]
#
# COMMANDS:
#   monitor     - Start continuous monitoring (run as cron or service)
#   snapshot    - Take a one-time heap+thread+stack dump & analyze
#   report      - Generate daily report from collected data
#   install     - Set up cron jobs and directory structure
#   dashboard   - Print latest report summary to stdout
#
# DEPLOYMENT:
#   DEV:  Develop & test here. Has internet for tool downloads.
#   PROD: Copy the entire wildfly-memdoctor/ folder. No internet needed.
#         Just: scp -r wildfly-memdoctor/ user@prod:/opt/wildfly-memdoctor/
#
###############################################################################

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Edit these for your environment
# ═══════════════════════════════════════════════════════════════════════════════

# WildFly paths
WILDFLY_HOME="${WILDFLY_HOME:-/opt/wildfly}"
WILDFLY_PID_FILE="${WILDFLY_HOME}/wildfly.pid"
WILDFLY_LOG="${WILDFLY_HOME}/standalone/log/server.log"

# JDK tools path (jmap, jstack, jcmd, jstat)
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk}"
JMAP="${JAVA_HOME}/bin/jmap"
JSTACK="${JAVA_HOME}/bin/jstack"
JCMD="${JAVA_HOME}/bin/jcmd"
JSTAT="${JAVA_HOME}/bin/jstat"

# MemDoctor data directory
MEMDOCTOR_HOME="${MEMDOCTOR_HOME:-/opt/wildfly-memdoctor}"
DUMP_DIR="${MEMDOCTOR_HOME}/dumps"
REPORT_DIR="${MEMDOCTOR_HOME}/reports"
LOG_DIR="${MEMDOCTOR_HOME}/logs"
ALERT_DIR="${MEMDOCTOR_HOME}/alerts"

# Thresholds — triggers pre-crash warnings
HEAP_WARN_PERCENT=75       # Warn when heap usage > 75%
HEAP_CRITICAL_PERCENT=90   # Critical alert when heap > 90%
THREAD_WARN_COUNT=300      # Warn when thread count > 300
THREAD_CRITICAL_COUNT=500  # Critical when threads > 500
GC_OVERHEAD_WARN=30        # Warn when GC time > 30% of total time
METASPACE_WARN_PERCENT=85  # Warn when metaspace > 85%

# How often to sample (seconds) when in monitor mode
MONITOR_INTERVAL=60

# Retention: days to keep dumps and reports
RETENTION_DAYS=30

# Report email (optional — leave empty to skip)
REPORT_EMAIL=""

# ═══════════════════════════════════════════════════════════════════════════════
# INTERNAL VARIABLES
# ═══════════════════════════════════════════════════════════════════════════════

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
DATE_TODAY=$(date '+%Y-%m-%d')
LOG_FILE="${LOG_DIR}/memdoctor_${DATE_TODAY}.log"
VERSION="1.0.0"

# Colors for terminal output
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
WHT='\033[1;37m'
RST='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
    case "${level}" in
        ERROR)    echo -e "${RED}[${level}] ${msg}${RST}" ;;
        WARN)     echo -e "${YEL}[${level}] ${msg}${RST}" ;;
        INFO)     echo -e "${GRN}[${level}] ${msg}${RST}" ;;
        DEBUG)    echo -e "${CYN}[${level}] ${msg}${RST}" ;;
        *)        echo "[${level}] ${msg}" ;;
    esac
}

ensure_dirs() {
    mkdir -p "${DUMP_DIR}" "${REPORT_DIR}" "${LOG_DIR}" "${ALERT_DIR}"
    mkdir -p "${DUMP_DIR}/${DATE_TODAY}"
}

find_wildfly_pid() {
    local pid=""
    # Method 1: PID file
    if [[ -f "${WILDFLY_PID_FILE}" ]]; then
        pid=$(cat "${WILDFLY_PID_FILE}" 2>/dev/null)
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "${pid}"
            return 0
        fi
    fi
    # Method 2: jps
    pid=$(${JAVA_HOME}/bin/jps -l 2>/dev/null | grep -i "jboss\|wildfly\|standalone" | awk '{print $1}' | head -1)
    if [[ -n "${pid}" ]]; then
        echo "${pid}"
        return 0
    fi
    # Method 3: ps
    pid=$(ps aux | grep -i "[j]boss.home\|[w]ildfly\|[s]tandalone.*-server" | grep -v grep | awk '{print $2}' | head -1)
    if [[ -n "${pid}" ]]; then
        echo "${pid}"
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# DATA COLLECTION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

collect_heap_stats() {
    local pid="$1"
    local outfile="${DUMP_DIR}/${DATE_TODAY}/heap_stats_${TIMESTAMP}.txt"

    log INFO "Collecting heap statistics for PID ${pid}..."

    # jstat -gc: S0C S1C S0U S1U EC EU OC OU MC MU ...
    echo "=== JSTAT GC STATS ===" > "${outfile}"
    ${JSTAT} -gc "${pid}" 2>/dev/null >> "${outfile}" || true
    echo "" >> "${outfile}"

    echo "=== JSTAT GC UTIL ===" >> "${outfile}"
    ${JSTAT} -gcutil "${pid}" 2>/dev/null >> "${outfile}" || true
    echo "" >> "${outfile}"

    echo "=== JSTAT GC CAUSE ===" >> "${outfile}"
    ${JSTAT} -gccause "${pid}" 2>/dev/null >> "${outfile}" || true
    echo "" >> "${outfile}"

    # jcmd GC.heap_info
    echo "=== JCMD HEAP INFO ===" >> "${outfile}"
    ${JCMD} "${pid}" GC.heap_info 2>/dev/null >> "${outfile}" || true
    echo "" >> "${outfile}"

    # jcmd VM.native_memory (if NMT enabled with -XX:NativeMemoryTracking=summary)
    echo "=== NATIVE MEMORY TRACKING ===" >> "${outfile}"
    ${JCMD} "${pid}" VM.native_memory summary 2>/dev/null >> "${outfile}" || echo "NMT not enabled" >> "${outfile}"

    echo "${outfile}"
}

collect_heap_dump() {
    local pid="$1"
    local outfile="${DUMP_DIR}/${DATE_TODAY}/heapdump_${TIMESTAMP}.hprof"

    log INFO "Capturing heap dump (this may take a moment)..."

    # Use jcmd (preferred) or jmap
    if ${JCMD} "${pid}" GC.heap_dump "${outfile}" 2>/dev/null; then
        log INFO "Heap dump saved: ${outfile}"
    elif ${JMAP} -dump:live,format=b,file="${outfile}" "${pid}" 2>/dev/null; then
        log INFO "Heap dump saved via jmap: ${outfile}"
    else
        log ERROR "Failed to capture heap dump"
        return 1
    fi
    echo "${outfile}"
}

collect_thread_dump() {
    local pid="$1"
    local outfile="${DUMP_DIR}/${DATE_TODAY}/threads_${TIMESTAMP}.txt"

    log INFO "Capturing thread dump..."

    echo "=== THREAD DUMP — $(date) ===" > "${outfile}"
    echo "PID: ${pid}" >> "${outfile}"
    echo "" >> "${outfile}"

    ${JSTACK} -l "${pid}" 2>/dev/null >> "${outfile}" || {
        log WARN "jstack failed, trying jcmd..."
        ${JCMD} "${pid}" Thread.print -l 2>/dev/null >> "${outfile}" || {
            log ERROR "Failed to capture thread dump"
            return 1
        }
    }

    log INFO "Thread dump saved: ${outfile}"
    echo "${outfile}"
}

collect_class_histogram() {
    local pid="$1"
    local outfile="${DUMP_DIR}/${DATE_TODAY}/class_histo_${TIMESTAMP}.txt"

    log INFO "Capturing class histogram (top memory consumers)..."

    ${JMAP} -histo:live "${pid}" 2>/dev/null | head -100 > "${outfile}" || {
        ${JCMD} "${pid}" GC.class_histogram 2>/dev/null | head -100 > "${outfile}" || {
            log WARN "Could not capture class histogram"
            return 1
        }
    }

    log INFO "Class histogram saved: ${outfile}"
    echo "${outfile}"
}

collect_gc_log_snapshot() {
    local outfile="${DUMP_DIR}/${DATE_TODAY}/gc_log_${TIMESTAMP}.txt"

    log INFO "Snapshotting GC log..."

    # Common GC log locations
    local gc_log=""
    for candidate in \
        "${WILDFLY_HOME}/standalone/log/gc.log" \
        "${WILDFLY_HOME}/standalone/log/gc.log.0.current" \
        "/var/log/wildfly/gc.log" \
        "${WILDFLY_HOME}/gc.log"; do
        if [[ -f "${candidate}" ]]; then
            gc_log="${candidate}"
            break
        fi
    done

    if [[ -n "${gc_log}" ]]; then
        tail -500 "${gc_log}" > "${outfile}"
        log INFO "GC log snapshot saved: ${outfile}"
    else
        log WARN "No GC log found. Enable with: -Xlog:gc*:file=gc.log:time,uptime,level,tags"
        echo "No GC log found" > "${outfile}"
    fi
    echo "${outfile}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ANALYSIS ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

analyze_heap_stats() {
    local stats_file="$1"
    local result_file="${DUMP_DIR}/${DATE_TODAY}/analysis_heap_${TIMESTAMP}.json"

    log INFO "Analyzing heap statistics..."

    # Parse jstat -gcutil output
    local gcutil_line=$(grep -A1 "^  S0" "${stats_file}" 2>/dev/null | tail -1)
    if [[ -z "${gcutil_line}" ]]; then
        gcutil_line=$(sed -n '/JSTAT GC UTIL/,/^$/p' "${stats_file}" | grep -v "===" | grep -v "^$" | tail -1)
    fi

    local old_gen_pct=0
    local eden_pct=0
    local meta_pct=0
    local gc_time=0

    if [[ -n "${gcutil_line}" ]]; then
        # gcutil columns: S0 S1 E O M CCS YGC YGCT FGC FGCT CGC CGCT GCT
        old_gen_pct=$(echo "${gcutil_line}" | awk '{printf "%.0f", $4}')
        eden_pct=$(echo "${gcutil_line}" | awk '{printf "%.0f", $3}')
        meta_pct=$(echo "${gcutil_line}" | awk '{printf "%.0f", $5}')
    fi

    cat > "${result_file}" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "heap_old_gen_percent": ${old_gen_pct:-0},
    "heap_eden_percent": ${eden_pct:-0},
    "metaspace_percent": ${meta_pct:-0},
    "status": "$(get_heap_status ${old_gen_pct:-0})",
    "findings": [
        $(generate_heap_findings ${old_gen_pct:-0} ${meta_pct:-0})
    ]
}
EOF

    echo "${result_file}"
}

get_heap_status() {
    local pct=$1
    if (( pct >= HEAP_CRITICAL_PERCENT )); then
        echo "CRITICAL"
    elif (( pct >= HEAP_WARN_PERCENT )); then
        echo "WARNING"
    else
        echo "OK"
    fi
}

generate_heap_findings() {
    local heap_pct=$1
    local meta_pct=$2
    local findings=""

    if (( heap_pct >= HEAP_CRITICAL_PERCENT )); then
        findings+='"CRITICAL: Old Gen heap at '${heap_pct}'% — server crash imminent. Immediate heap dump recommended."'
    elif (( heap_pct >= HEAP_WARN_PERCENT )); then
        findings+='"WARNING: Old Gen heap at '${heap_pct}'% — potential memory leak detected. Monitor closely."'
    fi

    if (( meta_pct >= METASPACE_WARN_PERCENT )); then
        [[ -n "${findings}" ]] && findings+=","
        findings+='"WARNING: Metaspace at '${meta_pct}'% — possible classloader leak from hot deployments."'
    fi

    if [[ -z "${findings}" ]]; then
        findings+='"OK: Memory usage within normal parameters."'
    fi

    echo "${findings}"
}

analyze_thread_dump() {
    local thread_file="$1"
    local result_file="${DUMP_DIR}/${DATE_TODAY}/analysis_threads_${TIMESTAMP}.json"

    log INFO "Analyzing thread dump..."

    local total_threads=$(grep -c "^\"" "${thread_file}" 2>/dev/null || echo 0)
    local blocked_threads=$(grep -c "java.lang.Thread.State: BLOCKED" "${thread_file}" 2>/dev/null || echo 0)
    local waiting_threads=$(grep -c "java.lang.Thread.State: WAITING" "${thread_file}" 2>/dev/null || echo 0)
    local timed_waiting=$(grep -c "java.lang.Thread.State: TIMED_WAITING" "${thread_file}" 2>/dev/null || echo 0)
    local runnable_threads=$(grep -c "java.lang.Thread.State: RUNNABLE" "${thread_file}" 2>/dev/null || echo 0)
    local deadlocks=$(grep -c "Found.*deadlock" "${thread_file}" 2>/dev/null || echo 0)

    # Find most common stack traces (leak suspects)
    local top_stacks=$(grep -A5 "java.lang.Thread.State:" "${thread_file}" 2>/dev/null \
        | grep "at " \
        | sort | uniq -c | sort -rn | head -10)

    # Find threads holding locks
    local lock_holders=$(grep -B2 "locked <" "${thread_file}" 2>/dev/null | head -20)

    # Identify suspect patterns
    local findings=""

    if (( deadlocks > 0 )); then
        findings+="{\"severity\":\"CRITICAL\",\"issue\":\"DEADLOCK DETECTED\",\"detail\":\"${deadlocks} deadlock(s) found\",\"solution\":\"Review lock ordering in synchronized blocks. Use java.util.concurrent locks with tryLock() timeout.\"},"
    fi

    if (( blocked_threads > 50 )); then
        findings+="{\"severity\":\"CRITICAL\",\"issue\":\"Excessive blocked threads: ${blocked_threads}\",\"detail\":\"Threads waiting for monitor locks\",\"solution\":\"Check for lock contention in DB connection pools, synchronized HashMap/ArrayList, or logging frameworks.\"},"
    fi

    if (( total_threads > THREAD_CRITICAL_COUNT )); then
        findings+="{\"severity\":\"CRITICAL\",\"issue\":\"Thread count critical: ${total_threads}\",\"detail\":\"Thread leak likely\",\"solution\":\"Check for unbounded thread pool creation. Review ExecutorService usage — ensure shutdown() is called. Check EJB @Asynchronous methods.\"},"
    elif (( total_threads > THREAD_WARN_COUNT )); then
        findings+="{\"severity\":\"WARNING\",\"issue\":\"High thread count: ${total_threads}\",\"detail\":\"Approaching thread limit\",\"solution\":\"Review thread pool configurations in standalone.xml. Check for threads created in loops without proper lifecycle management.\"},"
    fi

    # Remove trailing comma
    findings="${findings%,}"

    cat > "${result_file}" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "total_threads": ${total_threads},
    "runnable": ${runnable_threads},
    "blocked": ${blocked_threads},
    "waiting": ${waiting_threads},
    "timed_waiting": ${timed_waiting},
    "deadlocks": ${deadlocks},
    "status": "$(if (( deadlocks > 0 || total_threads > THREAD_CRITICAL_COUNT )); then echo CRITICAL; elif (( total_threads > THREAD_WARN_COUNT || blocked_threads > 20 )); then echo WARNING; else echo OK; fi)",
    "findings": [${findings}],
    "top_stack_traces": $(echo "${top_stacks}" | awk '{printf "    \"%s\",\n", $0}' | sed '$ s/,$//' | { echo "["; cat; echo "  ]"; })
}
EOF

    echo "${result_file}"
}

analyze_class_histogram() {
    local histo_file="$1"
    local result_file="${DUMP_DIR}/${DATE_TODAY}/analysis_classes_${TIMESTAMP}.json"

    log INFO "Analyzing class histogram for leak suspects..."

    # Extract top memory consumers
    # Format: num #instances #bytes class_name
    local suspects=""

    # Known leak patterns
    while IFS= read -r line; do
        local class_name=$(echo "${line}" | awk '{print $4}')
        local instances=$(echo "${line}" | awk '{print $2}')
        local bytes=$(echo "${line}" | awk '{print $3}')

        [[ -z "${class_name}" ]] && continue

        local issue=""
        local solution=""

        case "${class_name}" in
            *HashMap*|*ConcurrentHashMap*)
                issue="Large number of HashMap instances (${instances})"
                solution="Check for Maps used as caches without eviction. Use WeakHashMap or Caffeine cache with maxSize. Review static Map fields that grow unbounded."
                ;;
            *ArrayList*|*LinkedList*)
                issue="Large collection count: ${class_name} (${instances})"
                solution="Check for Lists that accumulate data without clearing. Look for event listeners/observers that register but never unregister."
                ;;
            *byte[]|*char[]|*String)
                if (( instances > 500000 )); then
                    issue="Excessive ${class_name} instances (${instances})"
                    solution="Check for String concatenation in loops (use StringBuilder). Review logging that builds large strings. Check for unclosed InputStreams reading into byte[]."
                fi
                ;;
            *Connection*|*Statement*|*ResultSet*)
                issue="JDBC objects not released: ${class_name} (${instances})"
                solution="Ensure DB connections are closed in finally blocks or use try-with-resources. Check DataSource pool configuration in standalone.xml. Review @Transactional boundaries."
                ;;
            *Session*|*HttpSession*)
                issue="Excessive session objects (${instances})"
                solution="Review session timeout settings. Check for large objects stored in HttpSession. Implement session cleanup listeners."
                ;;
            *Timer*|*TimerTask*|*ScheduledFuture*)
                issue="Accumulated timer/scheduler objects (${instances})"
                solution="Cancel timers in @PreDestroy. Use ManagedScheduledExecutorService instead of java.util.Timer in EE containers."
                ;;
            *ClassLoader*|*ModuleClassLoader*)
                issue="Multiple classloader instances (${instances})"
                solution="Classloader leak from redeployments. Restart WildFly periodically. Check for ThreadLocal values referencing webapp classes. Review JNDI lookups caching classloader references."
                ;;
            *Proxy*|*\$Proxy*)
                if (( instances > 10000 )); then
                    issue="Excessive proxy objects: ${class_name} (${instances})"
                    solution="Check CDI/EJB injection in request-scoped beans creating many proxies. Review @Produces methods generating proxy instances."
                fi
                ;;
        esac

        if [[ -n "${issue}" ]]; then
            suspects+="{\"class\":\"${class_name}\",\"instances\":${instances},\"bytes\":${bytes},\"issue\":\"${issue}\",\"solution\":\"${solution}\"},"
        fi
    done < <(tail -n +4 "${histo_file}" | head -50)

    suspects="${suspects%,}"

    cat > "${result_file}" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "suspects": [${suspects}]
}
EOF

    echo "${result_file}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WILDFLY-SPECIFIC ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

analyze_wildfly_subsystems() {
    local pid="$1"
    local result_file="${DUMP_DIR}/${DATE_TODAY}/analysis_wildfly_${TIMESTAMP}.json"

    log INFO "Analyzing WildFly-specific subsystems..."

    local findings=""

    # Check datasource pool stats via jboss-cli
    local cli="${WILDFLY_HOME}/bin/jboss-cli.sh"
    if [[ -x "${cli}" ]]; then
        # Datasource pool statistics
        local ds_stats=$(${cli} --connect --command="/subsystem=datasources/data-source=*/statistics=pool:read-resource(include-runtime=true)" 2>/dev/null || echo "{}")

        local active_count=$(echo "${ds_stats}" | grep -oP '"ActiveCount"\s*=>\s*\K\d+' | head -1)
        local available_count=$(echo "${ds_stats}" | grep -oP '"AvailableCount"\s*=>\s*\K\d+' | head -1)
        local max_wait=$(echo "${ds_stats}" | grep -oP '"MaxWaitCount"\s*=>\s*\K\d+' | head -1)

        if [[ -n "${active_count}" && -n "${available_count}" ]]; then
            local total=$((active_count + available_count))
            if (( total > 0 )); then
                local usage_pct=$((active_count * 100 / total))
                if (( usage_pct > 90 )); then
                    findings+="{\"subsystem\":\"datasources\",\"severity\":\"CRITICAL\",\"issue\":\"Connection pool ${usage_pct}% exhausted (${active_count}/${total})\",\"solution\":\"Increase max-pool-size in standalone.xml. Check for connection leaks — ensure connections are returned to pool. Add <check-valid-connection-sql> for stale connection detection.\"},"
                fi
            fi
        fi

        # Deployment scanner status
        local deploy_stats=$(${cli} --connect --command="/subsystem=deployment-scanner/scanner=default:read-resource" 2>/dev/null || echo "{}")
        local auto_deploy=$(echo "${deploy_stats}" | grep -oP '"auto-deploy-exploded"\s*=>\s*\K\w+')
        if [[ "${auto_deploy}" == "true" ]]; then
            findings+="{\"subsystem\":\"deployment-scanner\",\"severity\":\"WARNING\",\"issue\":\"Auto-deploy exploded is enabled\",\"solution\":\"Disable auto-deploy-exploded in production to prevent accidental redeployments causing classloader leaks.\"},"
        fi

        # EJB pool stats
        local ejb_stats=$(${cli} --connect --command="/subsystem=ejb3:read-resource(recursive=true,include-runtime=true)" 2>/dev/null || echo "{}")
    fi

    # Check WildFly server log for OOM warnings
    if [[ -f "${WILDFLY_LOG}" ]]; then
        local oom_count=$(grep -c "OutOfMemoryError\|GC overhead limit\|Java heap space\|Metaspace" "${WILDFLY_LOG}" 2>/dev/null || echo 0)
        if (( oom_count > 0 )); then
            local last_oom=$(grep "OutOfMemoryError\|GC overhead limit\|Java heap space\|Metaspace" "${WILDFLY_LOG}" | tail -1)
            findings+="{\"subsystem\":\"jvm\",\"severity\":\"CRITICAL\",\"issue\":\"${oom_count} OOM errors found in server.log\",\"detail\":\"Last: ${last_oom}\",\"solution\":\"Increase -Xmx in standalone.conf. If recurring, analyze heap dumps to find leak source. Consider adding -XX:+HeapDumpOnOutOfMemoryError.\"},"
        fi

        # Check for stuck deployments
        local stuck=$(grep -c "WFLYSRV0coords.*deploy.*stuck\|MSC.*service.*failed" "${WILDFLY_LOG}" 2>/dev/null || echo 0)
        if (( stuck > 0 )); then
            findings+="{\"subsystem\":\"deployment\",\"severity\":\"WARNING\",\"issue\":\"${stuck} stuck/failed deployment entries in log\",\"solution\":\"Review deployment dependencies. Check for circular CDI injection. Verify all required DataSources and JMS queues exist.\"},"
        fi
    fi

    findings="${findings%,}"

    cat > "${result_file}" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "wildfly_findings": [${findings}]
}
EOF

    echo "${result_file}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PRE-CRASH DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

check_precrash_indicators() {
    local pid="$1"
    local alert_file="${ALERT_DIR}/alert_${TIMESTAMP}.json"
    local alerts=""
    local severity="OK"

    # 1. Heap usage trend
    local gcutil=$(${JSTAT} -gcutil "${pid}" 2>/dev/null | tail -1)
    local old_pct=$(echo "${gcutil}" | awk '{printf "%.0f", $4}')
    local meta_pct=$(echo "${gcutil}" | awk '{printf "%.0f", $5}')
    local fgc_count=$(echo "${gcutil}" | awk '{print $9}')
    local fgc_time=$(echo "${gcutil}" | awk '{print $10}')
    local gc_total_time=$(echo "${gcutil}" | awk '{print $NF}')

    # 2. Check GC overhead
    # If Full GC count is high and growing, crash is coming
    local prev_fgc_file="${LOG_DIR}/.prev_fgc"
    if [[ -f "${prev_fgc_file}" ]]; then
        local prev_fgc=$(cat "${prev_fgc_file}")
        local fgc_delta=$((fgc_count - prev_fgc))
        if (( fgc_delta > 5 )); then
            alerts+="{\"type\":\"GC_STORM\",\"severity\":\"CRITICAL\",\"message\":\"${fgc_delta} Full GCs in last monitoring interval — server thrashing\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Server is spending most time in GC. Crash likely within minutes. Capture heap dump NOW and prepare for restart.\"},"
            severity="CRITICAL"
        fi
    fi
    echo "${fgc_count}" > "${prev_fgc_file}"

    # 3. Heap near limit
    if (( old_pct >= HEAP_CRITICAL_PERCENT )); then
        alerts+="{\"type\":\"HEAP_CRITICAL\",\"severity\":\"CRITICAL\",\"message\":\"Old Gen at ${old_pct}% — crash imminent\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Heap nearly full. OOM crash expected soon. Take heap dump immediately, then restart. Investigate the heap dump for retained objects.\"},"
        severity="CRITICAL"
    elif (( old_pct >= HEAP_WARN_PERCENT )); then
        alerts+="{\"type\":\"HEAP_WARNING\",\"severity\":\"WARNING\",\"message\":\"Old Gen at ${old_pct}%\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Memory growing. Check for request-scoped leaks (DB connections, streams, collections growing in session). Run class histogram to identify growing objects.\"},"
        [[ "${severity}" != "CRITICAL" ]] && severity="WARNING"
    fi

    # 4. Thread count
    local thread_count=$(ls /proc/${pid}/task 2>/dev/null | wc -l || echo 0)
    if (( thread_count > THREAD_CRITICAL_COUNT )); then
        alerts+="{\"type\":\"THREAD_LEAK\",\"severity\":\"CRITICAL\",\"message\":\"Thread count: ${thread_count} (limit: ${THREAD_CRITICAL_COUNT})\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Thread leak detected. Check for ExecutorService instances not properly shut down. Review @Asynchronous EJB methods. Check WebSocket endpoint lifecycle.\"},"
        severity="CRITICAL"
    fi

    # 5. Metaspace
    if (( meta_pct >= METASPACE_WARN_PERCENT )); then
        alerts+="{\"type\":\"METASPACE_LEAK\",\"severity\":\"WARNING\",\"message\":\"Metaspace at ${meta_pct}%\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Classloader leak — likely from hot redeployments. Each deploy loads new classes without unloading old ones. Schedule a WildFly restart. Avoid redeployment; do full redeploy cycles.\"},"
        [[ "${severity}" != "CRITICAL" ]] && severity="WARNING"
    fi

    # 6. File descriptor exhaustion
    local fd_count=$(ls /proc/${pid}/fd 2>/dev/null | wc -l || echo 0)
    local fd_limit=$(cat /proc/${pid}/limits 2>/dev/null | grep "Max open files" | awk '{print $4}')
    if [[ -n "${fd_limit}" ]] && (( fd_limit > 0 )); then
        local fd_pct=$((fd_count * 100 / fd_limit))
        if (( fd_pct > 85 )); then
            alerts+="{\"type\":\"FD_EXHAUSTION\",\"severity\":\"CRITICAL\",\"message\":\"File descriptors at ${fd_pct}% (${fd_count}/${fd_limit})\",\"time\":\"${TIMESTAMP}\",\"solution\":\"Unclosed file handles or sockets. Check for InputStream/OutputStream not closed in finally/try-with-resources. Review HTTP client connections not released.\"},"
            severity="CRITICAL"
        fi
    fi

    alerts="${alerts%,}"

    if [[ -n "${alerts}" ]]; then
        cat > "${alert_file}" <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "pid": ${pid},
    "overall_severity": "${severity}",
    "heap_old_gen_pct": ${old_pct:-0},
    "metaspace_pct": ${meta_pct:-0},
    "thread_count": ${thread_count},
    "fd_count": ${fd_count},
    "full_gc_count": ${fgc_count:-0},
    "alerts": [${alerts}]
}
EOF
        log "${severity}" "Pre-crash indicators detected! Alert saved: ${alert_file}"

        # If critical, auto-capture dumps
        if [[ "${severity}" == "CRITICAL" ]]; then
            log WARN "Auto-capturing diagnostic dumps due to CRITICAL status..."
            collect_thread_dump "${pid}" >/dev/null 2>&1
            collect_class_histogram "${pid}" >/dev/null 2>&1
            # Only auto heap-dump if we haven't done one in the last 10 minutes
            local recent_dump=$(find "${DUMP_DIR}/${DATE_TODAY}" -name "heapdump_*.hprof" -mmin -10 2>/dev/null | head -1)
            if [[ -z "${recent_dump}" ]]; then
                collect_heap_dump "${pid}" >/dev/null 2>&1
            fi
        fi
    fi

    echo "${severity}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DAILY REPORT GENERATOR
# ═══════════════════════════════════════════════════════════════════════════════

generate_daily_report() {
    local report_date="${1:-${DATE_TODAY}}"
    local report_file="${REPORT_DIR}/report_${report_date}.html"
    local dump_path="${DUMP_DIR}/${report_date}"

    log INFO "Generating daily report for ${report_date}..."

    if [[ ! -d "${dump_path}" ]]; then
        log WARN "No data found for ${report_date}"
        return 1
    fi

    # Collect all analysis files
    local heap_analyses=$(find "${dump_path}" -name "analysis_heap_*.json" 2>/dev/null | sort)
    local thread_analyses=$(find "${dump_path}" -name "analysis_threads_*.json" 2>/dev/null | sort)
    local class_analyses=$(find "${dump_path}" -name "analysis_classes_*.json" 2>/dev/null | sort)
    local wildfly_analyses=$(find "${dump_path}" -name "analysis_wildfly_*.json" 2>/dev/null | sort)
    local alerts=$(find "${ALERT_DIR}" -name "alert_${report_date}*.json" 2>/dev/null | sort)

    # Build JSON data for the report
    local report_json="${REPORT_DIR}/report_${report_date}.json"

    cat > "${report_json}" <<EOF
{
    "report_date": "${report_date}",
    "generated_at": "$(date -Iseconds)",
    "server": "$(hostname)",
    "wildfly_home": "${WILDFLY_HOME}",
    "summary": {
        "total_snapshots": $(echo "${heap_analyses}" | grep -c "." || echo 0),
        "total_alerts": $(echo "${alerts}" | grep -c "." || echo 0),
        "critical_alerts": $(for f in ${alerts}; do cat "$f" 2>/dev/null; done | grep -c '"CRITICAL"' || echo 0),
        "warning_alerts": $(for f in ${alerts}; do cat "$f" 2>/dev/null; done | grep -c '"WARNING"' || echo 0)
    },
    "heap_trend": [
$(for f in ${heap_analyses}; do
    if [[ -f "$f" ]]; then
        cat "$f"
        echo ","
    fi
done | sed '$ s/,$//')
    ],
    "thread_analyses": [
$(for f in ${thread_analyses}; do
    if [[ -f "$f" ]]; then
        cat "$f"
        echo ","
    fi
done | sed '$ s/,$//')
    ],
    "class_suspects": [
$(for f in ${class_analyses}; do
    if [[ -f "$f" ]]; then
        cat "$f"
        echo ","
    fi
done | sed '$ s/,$//')
    ],
    "wildfly_issues": [
$(for f in ${wildfly_analyses}; do
    if [[ -f "$f" ]]; then
        cat "$f"
        echo ","
    fi
done | sed '$ s/,$//')
    ],
    "alerts_timeline": [
$(for f in ${alerts}; do
    if [[ -f "$f" ]]; then
        cat "$f"
        echo ","
    fi
done | sed '$ s/,$//')
    ]
}
EOF

    # Generate HTML report
    generate_html_report "${report_json}" "${report_file}"

    log INFO "Daily report saved: ${report_file}"
    log INFO "JSON data saved: ${report_json}"
    echo "${report_file}"
}

generate_html_report() {
    local json_file="$1"
    local html_file="$2"

    cat > "${html_file}" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WildFly MemDoctor — Daily Report</title>
<style>
  :root {
    --bg: #0f1117; --surface: #1a1d27; --border: #2a2d3a;
    --text: #e4e4e7; --muted: #71717a; --accent: #818cf8;
    --ok: #34d399; --warn: #fbbf24; --crit: #f87171;
    --font: 'JetBrains Mono', 'Fira Code', monospace;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:var(--font); background:var(--bg); color:var(--text); padding:2rem; line-height:1.6; }
  .header { border-bottom:2px solid var(--accent); padding-bottom:1rem; margin-bottom:2rem; }
  .header h1 { font-size:1.5rem; color:var(--accent); }
  .header .meta { color:var(--muted); font-size:0.85rem; margin-top:0.5rem; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:1rem; margin:1.5rem 0; }
  .stat-card { background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:1.2rem; text-align:center; }
  .stat-card .value { font-size:2rem; font-weight:bold; }
  .stat-card .label { color:var(--muted); font-size:0.8rem; text-transform:uppercase; letter-spacing:1px; }
  .ok { color:var(--ok); } .warn { color:var(--warn); } .crit { color:var(--crit); }
  section { margin:2rem 0; }
  section h2 { color:var(--accent); font-size:1.1rem; margin-bottom:1rem; border-left:3px solid var(--accent); padding-left:0.8rem; }
  .finding { background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:1rem; margin:0.8rem 0; }
  .finding.critical { border-left:4px solid var(--crit); }
  .finding.warning { border-left:4px solid var(--warn); }
  .finding .badge { display:inline-block; padding:2px 8px; border-radius:4px; font-size:0.7rem; font-weight:bold; text-transform:uppercase; }
  .finding .badge.critical { background:rgba(248,113,113,0.2); color:var(--crit); }
  .finding .badge.warning { background:rgba(251,191,36,0.2); color:var(--warn); }
  .finding .badge.ok { background:rgba(52,211,153,0.2); color:var(--ok); }
  .finding .issue { margin:0.5rem 0; font-weight:bold; }
  .finding .solution { color:var(--ok); margin-top:0.5rem; padding:0.5rem; background:rgba(52,211,153,0.05); border-radius:4px; font-size:0.85rem; }
  .finding .solution::before { content:"💡 FIX: "; font-weight:bold; }
  .code-block { background:#0d0f14; border:1px solid var(--border); border-radius:6px; padding:1rem; font-size:0.8rem; overflow-x:auto; margin:0.5rem 0; white-space:pre-wrap; }
  table { width:100%; border-collapse:collapse; margin:1rem 0; }
  th, td { padding:0.6rem 0.8rem; text-align:left; border-bottom:1px solid var(--border); font-size:0.85rem; }
  th { color:var(--accent); font-size:0.75rem; text-transform:uppercase; letter-spacing:1px; }
  .empty { color:var(--muted); text-align:center; padding:2rem; font-style:italic; }
  footer { margin-top:3rem; padding-top:1rem; border-top:1px solid var(--border); color:var(--muted); font-size:0.75rem; text-align:center; }
</style>
</head>
<body>
<div class="header">
  <h1>🩺 WildFly MemDoctor — Daily Diagnostic Report</h1>
  <div class="meta">
    Report will be populated by the JSON data file.<br>
    Open this file alongside the JSON report for full details.
  </div>
</div>
<div class="grid">
  <div class="stat-card"><div class="value" id="snapshots">—</div><div class="label">Snapshots</div></div>
  <div class="stat-card"><div class="value crit" id="criticals">—</div><div class="label">Critical Alerts</div></div>
  <div class="stat-card"><div class="value warn" id="warnings">—</div><div class="label">Warnings</div></div>
  <div class="stat-card"><div class="value ok" id="status">—</div><div class="label">Overall Status</div></div>
</div>
<section>
  <h2>Memory Leak Suspects & Solutions</h2>
  <div id="findings"><p class="empty">Load the corresponding report_YYYY-MM-DD.json to populate.</p></div>
</section>
<section>
  <h2>Alert Timeline</h2>
  <div id="alerts"><p class="empty">No alerts recorded.</p></div>
</section>
<section>
  <h2>Recommended Actions</h2>
  <div id="actions"><p class="empty">Pending analysis...</p></div>
</section>
<footer>WildFly MemDoctor v1.0 — Offline Java Memory Diagnostics</footer>

<script>
// Auto-load JSON report if served from same directory
(async function() {
  const jsonFile = location.pathname.replace('.html', '.json');
  try {
    const resp = await fetch(jsonFile);
    if (!resp.ok) return;
    const data = await resp.json();
    document.getElementById('snapshots').textContent = data.summary?.total_snapshots || 0;
    document.getElementById('criticals').textContent = data.summary?.critical_alerts || 0;
    document.getElementById('warnings').textContent = data.summary?.warning_alerts || 0;
    const crit = data.summary?.critical_alerts || 0;
    const warn = data.summary?.warning_alerts || 0;
    document.getElementById('status').textContent = crit > 0 ? 'CRITICAL' : warn > 0 ? 'WARNING' : 'HEALTHY';
    document.getElementById('status').className = crit > 0 ? 'value crit' : warn > 0 ? 'value warn' : 'value ok';

    // Populate findings
    let findingsHtml = '';
    (data.class_suspects || []).forEach(cs => {
      (cs.suspects || []).forEach(s => {
        findingsHtml += `<div class="finding warning">
          <span class="badge warning">SUSPECT</span>
          <div class="issue">${s.class}: ${s.issue}</div>
          <div class="solution">${s.solution}</div>
          <div style="color:var(--muted);font-size:0.8rem;margin-top:0.3rem">Instances: ${s.instances} | Bytes: ${s.bytes}</div>
        </div>`;
      });
    });
    if (findingsHtml) document.getElementById('findings').innerHTML = findingsHtml;

    // Populate alerts
    let alertsHtml = '';
    (data.alerts_timeline || []).forEach(at => {
      (at.alerts || []).forEach(a => {
        const cls = a.severity === 'CRITICAL' ? 'critical' : 'warning';
        alertsHtml += `<div class="finding ${cls}">
          <span class="badge ${cls}">${a.severity}</span> <span style="color:var(--muted)">${a.time}</span>
          <div class="issue">${a.type}: ${a.message}</div>
          <div class="solution">${a.solution}</div>
        </div>`;
      });
    });
    if (alertsHtml) document.getElementById('alerts').innerHTML = alertsHtml;
  } catch(e) { console.log('No JSON report found for auto-loading:', e); }
})();
</script>
</body>
</html>
HTMLEOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN COMMANDS
# ═══════════════════════════════════════════════════════════════════════════════

cmd_snapshot() {
    ensure_dirs
    log INFO "=== WildFly MemDoctor Snapshot ==="

    local pid
    pid=$(find_wildfly_pid) || {
        log ERROR "WildFly process not found! Is the server running?"
        exit 1
    }
    log INFO "Found WildFly PID: ${pid}"

    # Collect everything
    local heap_stats=$(collect_heap_stats "${pid}")
    local thread_dump=$(collect_thread_dump "${pid}")
    local class_histo=$(collect_class_histogram "${pid}")
    local gc_log=$(collect_gc_log_snapshot)

    # Analyze
    local heap_analysis=$(analyze_heap_stats "${heap_stats}")
    local thread_analysis=$(analyze_thread_dump "${thread_dump}")
    local class_analysis=$(analyze_class_histogram "${class_histo}")
    local wildfly_analysis=$(analyze_wildfly_subsystems "${pid}")

    # Check pre-crash indicators
    local status=$(check_precrash_indicators "${pid}")

    echo ""
    log INFO "=== Snapshot Complete ==="
    log INFO "Status: ${status}"
    log INFO "Data saved to: ${DUMP_DIR}/${DATE_TODAY}/"
    log INFO "Run './wildfly-memdoctor.sh report' for full daily report"
}

cmd_monitor() {
    ensure_dirs
    log INFO "=== WildFly MemDoctor Monitor Mode ==="
    log INFO "Monitoring every ${MONITOR_INTERVAL}s (Ctrl+C to stop)"

    while true; do
        local pid
        pid=$(find_wildfly_pid) || {
            log ERROR "WildFly process not found! Waiting for restart..."
            sleep "${MONITOR_INTERVAL}"
            continue
        }

        # Quick health check (lightweight)
        local status=$(check_precrash_indicators "${pid}")

        # Every 10 minutes, do a full class histogram
        local minute=$(date '+%M')
        if (( minute % 10 == 0 )); then
            local heap_stats=$(collect_heap_stats "${pid}")
            analyze_heap_stats "${heap_stats}" >/dev/null 2>&1
            local class_histo=$(collect_class_histogram "${pid}")
            analyze_class_histogram "${class_histo}" >/dev/null 2>&1
        fi

        # Every hour, capture thread dump
        if (( minute == 0 )); then
            local thread_dump=$(collect_thread_dump "${pid}")
            analyze_thread_dump "${thread_dump}" >/dev/null 2>&1
            analyze_wildfly_subsystems "${pid}" >/dev/null 2>&1
        fi

        sleep "${MONITOR_INTERVAL}"
    done
}

cmd_report() {
    ensure_dirs
    local report_date="${1:-${DATE_TODAY}}"
    generate_daily_report "${report_date}"
}

cmd_install() {
    ensure_dirs
    log INFO "=== Installing WildFly MemDoctor ==="

    # Create systemd service file
    cat > "${MEMDOCTOR_HOME}/wildfly-memdoctor.service" <<EOF
[Unit]
Description=WildFly MemDoctor - Java Memory Diagnostics
After=wildfly.service

[Service]
Type=simple
ExecStart=${MEMDOCTOR_HOME}/wildfly-memdoctor.sh monitor
Restart=always
RestartSec=10
User=root
Environment=WILDFLY_HOME=${WILDFLY_HOME}
Environment=JAVA_HOME=${JAVA_HOME}
Environment=MEMDOCTOR_HOME=${MEMDOCTOR_HOME}

[Install]
WantedBy=multi-user.target
EOF

    # Create cron job for daily reports
    cat > "${MEMDOCTOR_HOME}/memdoctor-cron" <<EOF
# WildFly MemDoctor — Daily Report + Cleanup
# Generate daily report at 23:55
55 23 * * * root ${MEMDOCTOR_HOME}/wildfly-memdoctor.sh report >> ${LOG_DIR}/cron.log 2>&1

# Cleanup old dumps (retain ${RETENTION_DAYS} days)
0 2 * * * root find ${DUMP_DIR} -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} + 2>/dev/null
0 2 * * * root find ${REPORT_DIR} -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null
0 2 * * * root find ${ALERT_DIR} -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null

# Snapshot every 10 minutes during business hours
*/10 6-22 * * * root ${MEMDOCTOR_HOME}/wildfly-memdoctor.sh snapshot >> ${LOG_DIR}/cron.log 2>&1
EOF

    log INFO "Service file created: ${MEMDOCTOR_HOME}/wildfly-memdoctor.service"
    log INFO "Cron file created: ${MEMDOCTOR_HOME}/memdoctor-cron"
    echo ""
    echo -e "${WHT}To activate:${RST}"
    echo -e "  ${CYN}# Option A: systemd service (recommended for continuous monitoring)${RST}"
    echo "  sudo cp ${MEMDOCTOR_HOME}/wildfly-memdoctor.service /etc/systemd/system/"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable --now wildfly-memdoctor"
    echo ""
    echo -e "  ${CYN}# Option B: cron-based (periodic snapshots + daily reports)${RST}"
    echo "  sudo cp ${MEMDOCTOR_HOME}/memdoctor-cron /etc/cron.d/wildfly-memdoctor"
    echo ""
    echo -e "  ${CYN}# Recommended JVM flags (add to standalone.conf):${RST}"
    echo '  JAVA_OPTS="$JAVA_OPTS -XX:+HeapDumpOnOutOfMemoryError"'
    echo '  JAVA_OPTS="$JAVA_OPTS -XX:HeapDumpPath='${DUMP_DIR}'"'
    echo '  JAVA_OPTS="$JAVA_OPTS -XX:NativeMemoryTracking=summary"'
    echo '  JAVA_OPTS="$JAVA_OPTS -Xlog:gc*:file='${WILDFLY_HOME}'/standalone/log/gc.log:time,uptime,level,tags:filecount=5,filesize=50m"'
}

cmd_dashboard() {
    local latest_report=$(ls -t "${REPORT_DIR}"/report_*.json 2>/dev/null | head -1)
    local latest_alert=$(ls -t "${ALERT_DIR}"/alert_*.json 2>/dev/null | head -1)

    echo -e "${WHT}╔══════════════════════════════════════════════════╗${RST}"
    echo -e "${WHT}║    🩺 WildFly MemDoctor Dashboard                ║${RST}"
    echo -e "${WHT}╚══════════════════════════════════════════════════╝${RST}"
    echo ""

    if [[ -n "${latest_alert}" ]]; then
        local severity=$(python3 -c "import json;print(json.load(open('${latest_alert}'))['overall_severity'])" 2>/dev/null || echo "UNKNOWN")
        local heap=$(python3 -c "import json;print(json.load(open('${latest_alert}'))['heap_old_gen_pct'])" 2>/dev/null || echo "?")
        local threads=$(python3 -c "import json;print(json.load(open('${latest_alert}'))['thread_count'])" 2>/dev/null || echo "?")
        local fds=$(python3 -c "import json;print(json.load(open('${latest_alert}'))['fd_count'])" 2>/dev/null || echo "?")

        case "${severity}" in
            CRITICAL) echo -e "  Status:     ${RED}■ CRITICAL${RST}" ;;
            WARNING)  echo -e "  Status:     ${YEL}■ WARNING${RST}" ;;
            *)        echo -e "  Status:     ${GRN}■ HEALTHY${RST}" ;;
        esac
        echo -e "  Heap (Old): ${heap}%"
        echo -e "  Threads:    ${threads}"
        echo -e "  File Descs: ${fds}"
        echo -e "  Last Check: $(basename ${latest_alert} .json | sed 's/alert_//')"
    else
        echo -e "  ${YEL}No monitoring data yet. Run: ./wildfly-memdoctor.sh snapshot${RST}"
    fi

    echo ""
    if [[ -n "${latest_report}" ]]; then
        echo -e "  ${CYN}Latest Report: ${latest_report}${RST}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════

cmd_cleanup() {
    log INFO "Cleaning up data older than ${RETENTION_DAYS} days..."
    find "${DUMP_DIR}" -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} + 2>/dev/null || true
    find "${REPORT_DIR}" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    find "${ALERT_DIR}" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    log INFO "Cleanup complete."
}

# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"

    case "${cmd}" in
        snapshot)   cmd_snapshot ;;
        monitor)    cmd_monitor ;;
        report)     cmd_report "${2:-}" ;;
        install)    cmd_install ;;
        dashboard)  cmd_dashboard ;;
        cleanup)    cmd_cleanup ;;
        help|--help|-h)
            echo ""
            echo -e "${WHT}WildFly MemDoctor v${VERSION}${RST} — Java Memory Leak Detector"
            echo ""
            echo "Usage: $0 <command>"
            echo ""
            echo "Commands:"
            echo "  snapshot    Take a one-time heap+thread+stack dump & analyze"
            echo "  monitor     Start continuous monitoring (use as service)"
            echo "  report      Generate daily HTML+JSON report"
            echo "  install     Set up systemd service & cron jobs"
            echo "  dashboard   Print current status summary"
            echo "  cleanup     Remove data older than ${RETENTION_DAYS} days"
            echo ""
            echo "Configuration:"
            echo "  Edit variables at the top of this script, or set env vars:"
            echo "  WILDFLY_HOME, JAVA_HOME, MEMDOCTOR_HOME"
            echo ""
            echo "Deployment (DEV → PROD, no internet needed):"
            echo "  scp -r wildfly-memdoctor/ user@prod-server:/opt/"
            echo ""
            ;;
        *)
            echo "Unknown command: ${cmd}"
            echo "Run '$0 help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
