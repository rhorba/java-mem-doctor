#!/usr/bin/env bash
# Smoke test: run wildfly-memdoctor.sh against the lab server and check that it
# finds the leak the lab plants on purpose, and nothing on the healthy baseline.
#
# Run from the repo root:  bash lab/smoke-test.sh
# Needs: docker, curl, jq (all preinstalled on GitHub's ubuntu runners).
#
# Env: IMAGE (default memlab-smoke), CONTAINER (default memlab-smoke),
#      PORT (default 18080), KEEP=1 to leave the container running afterwards.

set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /opt/... paths as they are

IMAGE="${IMAGE:-memlab-smoke}"
CONTAINER="${CONTAINER:-memlab-smoke}"
PORT="${PORT:-18080}"
MD_HOME=/opt/wildfly-memdoctor
DEPLOYMENTS=/opt/jboss/wildfly/standalone/deployments
WORK="$(mktemp -d)"
REPORT="${WORK}/report.json"

step() { printf '\n== %s\n' "$*"; }

cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        echo "--- smoke test failed (exit ${rc}); container log tail:"
        docker logs --tail 60 "${CONTAINER}" 2>&1 || true
        echo "--- memdoctor log:"
        docker exec "${CONTAINER}" bash -c "cat ${MD_HOME}/logs/*.log" 2>&1 | tail -60 || true
    fi
    [[ "${KEEP:-0}" == 1 ]] || docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

md() { docker exec "${CONTAINER}" bash -c "cd ${MD_HOME} && ./wildfly-memdoctor.sh $*"; }

for tool in docker curl jq; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "missing required tool: ${tool}"; exit 1; }
done
jqf() { jq "$@" < "${REPORT}"; }

step "Build the lab image"
docker build -f lab/Dockerfile -t "${IMAGE}" .

step "Start WildFly"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" -p "${PORT}:8080" "${IMAGE}" >/dev/null

step "Wait for leak.war to deploy"
for _ in $(seq 1 90); do
    if docker exec "${CONTAINER}" test -f "${DEPLOYMENTS}/leak.war.deployed"; then break; fi
    if docker exec "${CONTAINER}" test -f "${DEPLOYMENTS}/leak.war.failed"; then
        echo "leak.war failed to deploy"; exit 1
    fi
    sleep 2
done
docker exec "${CONTAINER}" test -f "${DEPLOYMENTS}/leak.war.deployed" || { echo "leak.war not deployed after 180s"; exit 1; }

step "Baseline snapshot (healthy server)"
md snapshot

step "Trigger the leak"
for _ in $(seq 1 50); do
    curl -fsS "http://localhost:${PORT}/leak/leak.jsp?n=50&kb=64&threads=1" > /dev/null
done

step "Second snapshot and report"
md snapshot
md report
# Stream the file out rather than docker cp, so no host path is handed to docker (Git Bash on Windows)
docker exec "${CONTAINER}" bash -c "cat \"\$(ls -1 ${MD_HOME}/reports/report_*.json | tail -1)\"" > "${REPORT}"

step "Check the report"
failures=0
check() {
    local desc="$1" expr="$2"
    if jqf -e "${expr}" >/dev/null; then
        echo "PASS  ${desc}"
    else
        echo "FAIL  ${desc}    (jq: ${expr})"
        failures=$(( failures + 1 ))
    fi
}

check "report has two snapshots"            '(.heap_trend | length) == 2'
check "baseline heap status is OK"          '.heap_trend[0].status == "OK"'
check "baseline has no class suspects"      '(.class_suspects[0].suspects | length) == 0'
check "baseline has no thread findings"     '(.thread_analyses[0].findings | length) == 0'
check "old gen grew after the leak"         '.heap_trend[1].heap_old_gen_percent > .heap_trend[0].heap_old_gen_percent'
# shellcheck disable=SC2016  # the $ is part of the Java class name, not a shell variable
check "leak_jsp\$CachedSession is flagged"  'any(.class_suspects[1].suspects[]; .class | endswith("leak_jsp$CachedSession"))'
check "thread pile-up on leak_jsp is found" 'any(.thread_analyses[1].findings[]; (.detail // "") | contains("leak_jsp"))'

dashboard="$(md dashboard)"
for pattern in 'Status: .*(WARNING|CRITICAL)' 'Heap \(Old\): [0-9]+%' 'Threads: +[0-9]+'; do
    if grep -qE "${pattern}" <<< "${dashboard}"; then
        echo "PASS  dashboard shows /${pattern}/"
    else
        echo "FAIL  dashboard shows /${pattern}/"
        failures=$(( failures + 1 ))
    fi
done

echo
jqf '{old_gen: [.heap_trend[].heap_old_gen_percent], threads: [.thread_analyses[].total_threads], suspects: [.class_suspects[1].suspects[].class]}'

if (( failures > 0 )); then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "All checks passed"
