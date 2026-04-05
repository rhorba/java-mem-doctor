# 🩺 WildFly MemDoctor v1.0

**Offline Java Heap / Stack / Thread Dump Analyzer for WildFly Application Servers**

Detects memory leaks, predicts crashes, and suggests exact code fixes — works fully air-gapped (no internet required on PROD).

---

## What It Does

| Feature | Description |
|---|---|
| **Heap Analysis** | Captures heap stats, class histograms, identifies objects consuming most memory |
| **Thread Analysis** | Detects deadlocks, thread leaks, blocked threads, excessive thread counts |
| **Stack Trace Analysis** | Pinpoints the exact classes/methods causing issues |
| **Pre-Crash Detection** | Monitors JVM metrics and alerts BEFORE the server crashes |
| **Daily Reports** | HTML + JSON reports with problems, suspect classes, and suggested fixes |
| **WildFly-Specific** | Checks datasource pools, deployment scanner, EJB pools, server.log for OOM |
| **Code Fix Suggestions** | Maps detected patterns to known leak patterns with before/after code examples |
| **Offline/Air-Gapped** | Zero internet dependency — copy-paste between DEV and PROD |

---

## Directory Structure

```
wildfly-memdoctor/
├── wildfly-memdoctor.sh      # Main script (the only thing you need to run)
├── KNOWN_PATTERNS.md          # Reference catalog of 10+ common Java/WildFly leak patterns
├── README.md                  # This file
├── dumps/                     # Auto-created: raw dumps + analysis JSON
│   └── 2026-04-05/
│       ├── heap_stats_*.txt
│       ├── threads_*.txt
│       ├── class_histo_*.txt
│       ├── analysis_heap_*.json
│       ├── analysis_threads_*.json
│       └── analysis_classes_*.json
├── reports/                   # Auto-created: daily HTML + JSON reports
│   ├── report_2026-04-05.html
│   └── report_2026-04-05.json
├── alerts/                    # Auto-created: pre-crash alert files
│   └── alert_2026-04-05_*.json
└── logs/                      # Auto-created: memdoctor's own logs
    └── memdoctor_2026-04-05.log
```

---

## Quick Start

### 1. Deploy to Server

**On DEV (has internet):**
```bash
# No dependencies to install — it uses JDK tools (jmap, jstack, jstat, jcmd)
# that are already on your server with the JDK

# Just copy the folder
scp -r wildfly-memdoctor/ user@prod-server:/opt/wildfly-memdoctor/
```

**On PROD (no internet):**
```bash
cd /opt/wildfly-memdoctor
chmod +x wildfly-memdoctor.sh
```

### 2. Configure

Edit the top of `wildfly-memdoctor.sh`:

```bash
# Point to your WildFly installation
WILDFLY_HOME="/opt/wildfly"

# Point to your JDK
JAVA_HOME="/usr/lib/jvm/java-11-openjdk"

# Adjust thresholds
HEAP_WARN_PERCENT=75       # Alert when heap > 75%
HEAP_CRITICAL_PERCENT=90   # Critical when heap > 90%
THREAD_WARN_COUNT=300      # Alert when threads > 300
```

### 3. Run

```bash
# One-time snapshot (heap + threads + analysis)
./wildfly-memdoctor.sh snapshot

# Generate today's report
./wildfly-memdoctor.sh report

# Start continuous monitoring
./wildfly-memdoctor.sh monitor

# Check current status
./wildfly-memdoctor.sh dashboard

# Install as systemd service + cron
./wildfly-memdoctor.sh install
```

---

## Deployment: DEV → PROD (No Internet)

Since PROD has no internet, the workflow is:

```
┌──────────────┐                    ┌──────────────┐
│     DEV      │                    │     PROD     │
│ (internet)   │    scp / rsync     │ (air-gapped) │
│              │ ──────────────────▶│              │
│ Edit configs │                    │ Run monitor  │
│ Test script  │                    │ View reports │
│              │ ◀──────────────────│              │
│              │    scp reports     │ Collect data │
└──────────────┘                    └──────────────┘
```

**Step-by-step:**

1. **DEV**: Edit `wildfly-memdoctor.sh` with PROD paths
2. **DEV → PROD**: `scp -r wildfly-memdoctor/ user@prod:/opt/`
3. **PROD**: `chmod +x /opt/wildfly-memdoctor/wildfly-memdoctor.sh`
4. **PROD**: `./wildfly-memdoctor.sh install` (sets up cron + systemd)
5. **PROD → DEV**: `scp user@prod:/opt/wildfly-memdoctor/reports/* ./reports/` (to view HTML reports in browser)

---

## Recommended JVM Flags

Add these to `${WILDFLY_HOME}/bin/standalone.conf`:

```bash
# Auto heap dump on OOM (captured before crash)
JAVA_OPTS="$JAVA_OPTS -XX:+HeapDumpOnOutOfMemoryError"
JAVA_OPTS="$JAVA_OPTS -XX:HeapDumpPath=/opt/wildfly-memdoctor/dumps"

# Native Memory Tracking (enables VM.native_memory in jcmd)
JAVA_OPTS="$JAVA_OPTS -XX:NativeMemoryTracking=summary"

# GC logging (for GC analysis)
JAVA_OPTS="$JAVA_OPTS -Xlog:gc*:file=/opt/wildfly/standalone/log/gc.log:time,uptime,level,tags:filecount=5,filesize=50m"

# Explicit metaspace limit (prevents unbounded metaspace growth)
JAVA_OPTS="$JAVA_OPTS -XX:MaxMetaspaceSize=512m"
```

---

## Understanding the Reports

### Alert Severities

| Level | Meaning | Action |
|---|---|---|
| **CRITICAL** | Crash imminent or deadlock detected | Immediate intervention needed |
| **WARNING** | Memory/threads trending up | Investigate within 24 hours |
| **OK** | Everything within normal bounds | No action needed |

### Common Findings & What They Mean

| Finding | Root Cause | Quick Fix |
|---|---|---|
| Old Gen > 90% | Memory leak | Check class histogram for growing objects |
| Thread count > 500 | Thread leak | Find ExecutorService not shutdown |
| Metaspace growing | Classloader leak | Avoid hot-redeploy, restart WildFly |
| Many blocked threads | Lock contention | Review synchronized blocks, DB pool size |
| Deadlock detected | Lock ordering bug | Use tryLock() with timeout |
| DB pool exhausted | Connection leak | Use try-with-resources for JDBC |
| FD count > 85% | Stream/socket leak | Close all streams in finally blocks |

---

## How It Detects Problems

```
Every 60 seconds (monitor mode):
  │
  ├─ jstat -gcutil → Heap %, GC frequency
  │   └─ If Old Gen > 90% → CRITICAL alert
  │   └─ If Full GC count spiking → GC Storm alert
  │
  ├─ /proc/PID/task → Thread count
  │   └─ If > 500 → Thread leak alert
  │
  ├─ /proc/PID/fd → File descriptor count
  │   └─ If > 85% of limit → FD exhaustion alert
  │
  Every 10 minutes:
  ├─ jstat -gc → Detailed heap stats
  ├─ jmap -histo → Class histogram (top memory consumers)
  │   └─ Matches against KNOWN_PATTERNS.md
  │
  Every hour:
  ├─ jstack → Full thread dump
  │   └─ Deadlock detection
  │   └─ Blocked thread analysis
  │   └─ Top repeated stack traces
  ├─ jboss-cli → WildFly subsystem health
  │
  Daily at 23:55:
  └─ Aggregate all data → HTML + JSON report
```

---

## Troubleshooting

**"WildFly process not found"**
- Check that WildFly is running: `ps aux | grep wildfly`
- Set `WILDFLY_PID_FILE` to match your setup
- Or set the PID manually: `export WILDFLY_PID=12345`

**"jstat/jmap/jstack: command not found"**
- Ensure `JAVA_HOME` points to JDK (not JRE)
- Install JDK if only JRE is present

**"Permission denied" for jmap/jstack**
- Run as the same user as WildFly, or as root
- Check if ptrace is restricted: `echo 0 > /proc/sys/kernel/yama/ptrace_scope`

**Heap dump takes too long**
- Normal for large heaps (4GB+ can take minutes)
- Ensure enough disk space (dump ≈ heap size)

---

## License

Internal tool. No external dependencies. Copy freely between environments.
"# java-mem-doctor" 
