import { useState, useEffect, useCallback } from "react";

const MOCK_DATA = {
  report_date: "2026-04-05",
  server: "prod-wildfly-01",
  summary: { total_snapshots: 24, total_alerts: 7, critical_alerts: 2, warning_alerts: 5 },
  heap_trend: [
    { timestamp: "06:00", heap_old_gen_percent: 42, metaspace_percent: 55, status: "OK" },
    { timestamp: "08:00", heap_old_gen_percent: 51, metaspace_percent: 56, status: "OK" },
    { timestamp: "10:00", heap_old_gen_percent: 63, metaspace_percent: 58, status: "OK" },
    { timestamp: "12:00", heap_old_gen_percent: 72, metaspace_percent: 60, status: "OK" },
    { timestamp: "14:00", heap_old_gen_percent: 78, metaspace_percent: 62, status: "WARNING" },
    { timestamp: "16:00", heap_old_gen_percent: 85, metaspace_percent: 64, status: "WARNING" },
    { timestamp: "18:00", heap_old_gen_percent: 91, metaspace_percent: 66, status: "CRITICAL" },
    { timestamp: "20:00", heap_old_gen_percent: 88, metaspace_percent: 65, status: "WARNING" },
  ],
  alerts_timeline: [
    { timestamp: "14:10", overall_severity: "WARNING", heap_old_gen_pct: 78, thread_count: 285, alerts: [
      { type: "HEAP_WARNING", severity: "WARNING", message: "Old Gen at 78%", solution: "Check for request-scoped leaks. Run class histogram." }
    ]},
    { timestamp: "16:05", overall_severity: "WARNING", heap_old_gen_pct: 85, thread_count: 340, alerts: [
      { type: "HEAP_WARNING", severity: "WARNING", message: "Old Gen at 85%", solution: "Memory growing. Investigate DB connections and session objects." },
      { type: "THREAD_LEAK", severity: "WARNING", message: "Thread count: 340", solution: "Check ExecutorService instances not shut down." }
    ]},
    { timestamp: "18:02", overall_severity: "CRITICAL", heap_old_gen_pct: 91, thread_count: 412, alerts: [
      { type: "HEAP_CRITICAL", severity: "CRITICAL", message: "Old Gen at 91% — crash imminent", solution: "Take heap dump immediately, then restart." },
      { type: "GC_STORM", severity: "CRITICAL", message: "12 Full GCs in last interval", solution: "Server thrashing. Crash likely within minutes." }
    ]},
  ],
  class_suspects: [
    { class: "java.util.HashMap", instances: 284521, bytes: 45523360, issue: "Large number of HashMap instances (284521)", solution: "Check Maps used as caches without eviction. Use WeakHashMap or Caffeine cache with maxSize." },
    { class: "java.sql.Connection", instances: 847, bytes: 1355200, issue: "JDBC objects not released: Connection (847)", solution: "Ensure connections closed in finally blocks or try-with-resources. Check DataSource pool config." },
    { class: "org.hibernate.internal.SessionImpl", instances: 1203, bytes: 2887200, issue: "Growing SessionImpl count — Hibernate L1 cache leak", solution: "Call em.flush() + em.clear() in batch processing. Use @Transactional boundaries correctly." },
    { class: "java.lang.Thread", instances: 412, bytes: 824000, issue: "Thread count above threshold", solution: "Use ManagedExecutorService instead of Executors.newFixedThreadPool(). Ensure shutdown() in @PreDestroy." },
    { class: "byte[]", instances: 892103, bytes: 178420600, issue: "Excessive byte[] instances (892103)", solution: "Check for unclosed InputStreams. Review String concatenation in loops — use StringBuilder." },
  ],
  wildfly_issues: [
    { subsystem: "datasources", severity: "CRITICAL", issue: "Connection pool 95% exhausted (28/30)", solution: "Increase max-pool-size. Add check-valid-connection-sql. Check for connection leaks." },
    { subsystem: "jvm", severity: "CRITICAL", issue: "3 OOM errors found in server.log", solution: "Increase -Xmx in standalone.conf. Add -XX:+HeapDumpOnOutOfMemoryError." },
    { subsystem: "deployment-scanner", severity: "WARNING", issue: "Auto-deploy exploded is enabled", solution: "Disable in production to prevent classloader leaks from accidental redeployments." },
  ],
};

const PATTERNS_DB = {
  "java.util.HashMap": {
    pattern: "STATIC_COLLECTION_LEAK",
    bad: `// ❌ Static map grows forever\nprivate static final Map<String, List<Entry>> cache = new HashMap<>();\n\npublic void log(String id, Entry e) {\n    cache.computeIfAbsent(id, k -> new ArrayList<>()).add(e);\n    // Map grows forever!\n}`,
    fix: `// ✅ Use bounded cache\nprivate static final Cache<String, List<Entry>> cache =\n    Caffeine.newBuilder()\n        .maximumSize(10_000)\n        .expireAfterWrite(Duration.ofHours(1))\n        .build();`,
  },
  "java.sql.Connection": {
    pattern: "DB_CONNECTION_LEAK",
    bad: `// ❌ Connection never closed on exception\nConnection conn = ds.getConnection();\nPreparedStatement ps = conn.prepareStatement(sql);\nResultSet rs = ps.executeQuery();\n// process...\nreturn result; // conn leaked!`,
    fix: `// ✅ try-with-resources\ntry (Connection conn = ds.getConnection();\n     PreparedStatement ps = conn.prepareStatement(sql);\n     ResultSet rs = ps.executeQuery()) {\n    // process...\n    return result;\n} // auto-closed`,
  },
  "org.hibernate.internal.SessionImpl": {
    pattern: "JPA_SESSION_LEAK",
    bad: `// ❌ L1 cache grows in batch loop\nfor (int i = 0; i < 10000; i++) {\n    Order o = em.find(Order.class, i);\n    o.setStatus("DONE");\n    em.merge(o);\n    // Hibernate cache grows!\n}`,
    fix: `// ✅ Flush + clear in batches\nfor (int i = 0; i < 10000; i++) {\n    Order o = em.find(Order.class, i);\n    o.setStatus("DONE");\n    em.merge(o);\n    if (i % 50 == 0) {\n        em.flush();\n        em.clear(); // Free L1 cache!\n    }\n}`,
  },
  "java.lang.Thread": {
    pattern: "THREAD_LEAK",
    bad: `// ❌ New pool per request\n@POST\npublic Response process(Data d) {\n    ExecutorService ex = Executors.newFixedThreadPool(5);\n    ex.submit(() -> work(d));\n    return Response.ok().build();\n    // 5 threads leaked per request!\n}`,
    fix: `// ✅ Container-managed executor\n@Resource(name="java:jboss/ee/concurrency/executor/default")\nprivate ManagedExecutorService ex;\n\n@POST\npublic Response process(Data d) {\n    ex.submit(() -> work(d));\n    return Response.ok().build();\n}`,
  },
  "byte[]": {
    pattern: "STREAM_LEAK",
    bad: `// ❌ Stream not closed on exception\nFileInputStream fis = new FileInputStream(path);\nBufferedReader r = new BufferedReader(\n    new InputStreamReader(fis));\nString s = r.readLine();\nr.close(); // Never reached on exception!`,
    fix: `// ✅ try-with-resources\ntry (BufferedReader r = Files.newBufferedReader(\n        Path.of(path))) {\n    String s = r.readLine();\n} // Auto-closed even on exception`,
  },
};

function Badge({ severity }) {
  const colors = {
    CRITICAL: { bg: "rgba(239,68,68,0.15)", fg: "#ef4444", border: "#ef4444" },
    WARNING: { bg: "rgba(245,158,11,0.15)", fg: "#f59e0b", border: "#f59e0b" },
    OK: { bg: "rgba(34,197,94,0.15)", fg: "#22c55e", border: "#22c55e" },
    INFO: { bg: "rgba(99,102,241,0.15)", fg: "#6366f1", border: "#6366f1" },
  };
  const c = colors[severity] || colors.INFO;
  return (
    <span style={{ display:"inline-block", padding:"2px 10px", borderRadius:4, fontSize:11, fontWeight:700, letterSpacing:1, textTransform:"uppercase", background:c.bg, color:c.fg, border:`1px solid ${c.border}22` }}>
      {severity}
    </span>
  );
}

function MiniChart({ data, width = 320, height = 80 }) {
  if (!data.length) return null;
  const max = 100;
  const pts = data.map((d, i) => ({
    x: (i / (data.length - 1)) * width,
    y: height - (d.heap_old_gen_percent / max) * height,
    v: d.heap_old_gen_percent,
    t: d.timestamp,
  }));
  const line = pts.map((p, i) => `${i === 0 ? "M" : "L"}${p.x},${p.y}`).join(" ");
  const area = line + ` L${width},${height} L0,${height} Z`;
  const warnY = height - (75 / max) * height;
  const critY = height - (90 / max) * height;

  return (
    <svg viewBox={`0 0 ${width} ${height}`} style={{ width: "100%", maxWidth: width, height: "auto" }}>
      <defs>
        <linearGradient id="heapGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#818cf8" stopOpacity="0.4" />
          <stop offset="100%" stopColor="#818cf8" stopOpacity="0.02" />
        </linearGradient>
      </defs>
      <line x1="0" y1={warnY} x2={width} y2={warnY} stroke="#f59e0b" strokeWidth="0.5" strokeDasharray="4,4" opacity="0.5" />
      <line x1="0" y1={critY} x2={width} y2={critY} stroke="#ef4444" strokeWidth="0.5" strokeDasharray="4,4" opacity="0.5" />
      <path d={area} fill="url(#heapGrad)" />
      <path d={line} fill="none" stroke="#818cf8" strokeWidth="2" />
      {pts.map((p, i) => (
        <g key={i}>
          <circle cx={p.x} cy={p.y} r="3" fill={p.v >= 90 ? "#ef4444" : p.v >= 75 ? "#f59e0b" : "#818cf8"} />
          <text x={p.x} y={height - 2} textAnchor="middle" fill="#71717a" fontSize="8" fontFamily="monospace">{p.t}</text>
        </g>
      ))}
      <text x={width + 2} y={warnY + 3} fill="#f59e0b" fontSize="7" fontFamily="monospace">75%</text>
      <text x={width + 2} y={critY + 3} fill="#ef4444" fontSize="7" fontFamily="monospace">90%</text>
    </svg>
  );
}

function CodeBlock({ code, label }) {
  return (
    <div style={{ margin: "6px 0" }}>
      {label && <div style={{ fontSize: 10, color: "#71717a", textTransform: "uppercase", letterSpacing: 1, marginBottom: 4 }}>{label}</div>}
      <pre style={{ background: "#0c0e14", border: "1px solid #1e2030", borderRadius: 6, padding: "10px 12px", fontSize: 11, lineHeight: 1.5, overflowX: "auto", color: "#c4c4cc", fontFamily: "'JetBrains Mono', 'Fira Code', monospace", margin: 0, whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
        {code}
      </pre>
    </div>
  );
}

function SuspectCard({ suspect, expanded, onToggle }) {
  const pattern = PATTERNS_DB[suspect.class];
  const bytesStr = suspect.bytes > 1048576 ? `${(suspect.bytes / 1048576).toFixed(1)} MB` : `${(suspect.bytes / 1024).toFixed(0)} KB`;

  return (
    <div style={{ background: "#13151f", border: "1px solid #1e2030", borderLeft: "3px solid #f59e0b", borderRadius: 8, padding: "14px 16px", marginBottom: 10, transition: "all 0.2s" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", cursor: "pointer" }} onClick={onToggle}>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
            <Badge severity="WARNING" />
            <code style={{ fontSize: 13, color: "#818cf8", fontWeight: 600 }}>{suspect.class}</code>
          </div>
          <div style={{ fontSize: 13, color: "#d4d4d8", marginBottom: 4 }}>{suspect.issue}</div>
          <div style={{ fontSize: 11, color: "#71717a" }}>
            Instances: <span style={{ color: "#f59e0b" }}>{suspect.instances.toLocaleString()}</span> · Memory: <span style={{ color: "#f59e0b" }}>{bytesStr}</span>
          </div>
        </div>
        <div style={{ fontSize: 18, color: "#52525b", transform: expanded ? "rotate(180deg)" : "rotate(0)", transition: "transform 0.2s" }}>▼</div>
      </div>

      {expanded && (
        <div style={{ marginTop: 12, paddingTop: 12, borderTop: "1px solid #1e2030" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}>
            <span style={{ fontSize: 16 }}>💡</span>
            <span style={{ fontSize: 12, color: "#22c55e", fontWeight: 600 }}>SUGGESTED FIX</span>
          </div>
          <div style={{ fontSize: 12, color: "#a1a1aa", marginBottom: 10, lineHeight: 1.6, padding: "8px 12px", background: "rgba(34,197,94,0.06)", borderRadius: 6 }}>
            {suspect.solution}
          </div>
          {pattern && (
            <>
              <div style={{ fontSize: 11, color: "#71717a", marginBottom: 4, marginTop: 12 }}>
                Pattern: <code style={{ color: "#818cf8" }}>{pattern.pattern}</code>
              </div>
              <CodeBlock code={pattern.bad} label="❌ problematic code" />
              <CodeBlock code={pattern.fix} label="✅ corrected code" />
            </>
          )}
        </div>
      )}
    </div>
  );
}

export default function App() {
  const [data] = useState(MOCK_DATA);
  const [tab, setTab] = useState("overview");
  const [expandedSuspect, setExpandedSuspect] = useState(null);
  const [expandedAlert, setExpandedAlert] = useState(null);

  const criticals = data.summary.critical_alerts;
  const warnings = data.summary.warning_alerts;
  const overall = criticals > 0 ? "CRITICAL" : warnings > 0 ? "WARNING" : "HEALTHY";

  const tabs = [
    { id: "overview", label: "Overview", icon: "📊" },
    { id: "suspects", label: "Leak Suspects", icon: "🔍" },
    { id: "alerts", label: "Alerts", icon: "🚨" },
    { id: "wildfly", label: "WildFly", icon: "🐝" },
    { id: "deploy", label: "Deploy Guide", icon: "📦" },
  ];

  return (
    <div style={{ fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', monospace", background: "#0a0c12", color: "#e4e4e7", minHeight: "100vh", padding: 0 }}>
      {/* Header */}
      <div style={{ background: "linear-gradient(135deg, #0f1117 0%, #13151f 100%)", borderBottom: "1px solid #1e2030", padding: "16px 20px" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ fontSize: 24 }}>🩺</span>
          <div>
            <h1 style={{ fontSize: 16, fontWeight: 700, margin: 0, letterSpacing: "0.5px", color: "#818cf8" }}>WildFly MemDoctor</h1>
            <div style={{ fontSize: 11, color: "#52525b", marginTop: 2 }}>{data.server} · {data.report_date} · v1.0</div>
          </div>
          <div style={{ marginLeft: "auto" }}>
            <Badge severity={overall === "HEALTHY" ? "OK" : overall} />
          </div>
        </div>
      </div>

      {/* Tabs */}
      <div style={{ display: "flex", gap: 0, borderBottom: "1px solid #1e2030", background: "#0d0f17", overflowX: "auto" }}>
        {tabs.map(t => (
          <button key={t.id} onClick={() => setTab(t.id)} style={{
            padding: "10px 16px", fontSize: 11, fontFamily: "inherit", border: "none", cursor: "pointer", whiteSpace: "nowrap",
            background: tab === t.id ? "#13151f" : "transparent",
            color: tab === t.id ? "#818cf8" : "#52525b",
            borderBottom: tab === t.id ? "2px solid #818cf8" : "2px solid transparent",
            transition: "all 0.15s",
          }}>
            {t.icon} {t.label}
          </button>
        ))}
      </div>

      <div style={{ padding: "16px 20px", maxWidth: 900, margin: "0 auto" }}>

        {/* OVERVIEW TAB */}
        {tab === "overview" && (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 20 }}>
              {[
                { label: "Snapshots", value: data.summary.total_snapshots, color: "#818cf8" },
                { label: "Critical", value: criticals, color: "#ef4444" },
                { label: "Warnings", value: warnings, color: "#f59e0b" },
                { label: "Status", value: overall, color: overall === "HEALTHY" ? "#22c55e" : overall === "WARNING" ? "#f59e0b" : "#ef4444" },
              ].map((s, i) => (
                <div key={i} style={{ background: "#13151f", border: "1px solid #1e2030", borderRadius: 8, padding: "14px 16px", textAlign: "center" }}>
                  <div style={{ fontSize: 24, fontWeight: 700, color: s.color }}>{s.value}</div>
                  <div style={{ fontSize: 10, color: "#52525b", textTransform: "uppercase", letterSpacing: 1, marginTop: 4 }}>{s.label}</div>
                </div>
              ))}
            </div>

            <div style={{ background: "#13151f", border: "1px solid #1e2030", borderRadius: 8, padding: 16, marginBottom: 20 }}>
              <h3 style={{ fontSize: 12, color: "#818cf8", margin: "0 0 12px", textTransform: "uppercase", letterSpacing: 1 }}>Heap Usage Trend (Old Gen %)</h3>
              <MiniChart data={data.heap_trend} width={500} height={100} />
            </div>

            <div style={{ background: "#13151f", border: "1px solid #1e2030", borderRadius: 8, padding: 16 }}>
              <h3 style={{ fontSize: 12, color: "#818cf8", margin: "0 0 12px", textTransform: "uppercase", letterSpacing: 1 }}>Top Memory Consumers</h3>
              {data.class_suspects.slice(0, 3).map((s, i) => (
                <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "8px 0", borderBottom: i < 2 ? "1px solid #1e2030" : "none" }}>
                  <code style={{ fontSize: 12, color: "#d4d4d8" }}>{s.class}</code>
                  <span style={{ fontSize: 11, color: "#f59e0b" }}>{(s.bytes / 1048576).toFixed(1)} MB</span>
                </div>
              ))}
            </div>
          </>
        )}

        {/* SUSPECTS TAB */}
        {tab === "suspects" && (
          <>
            <h2 style={{ fontSize: 14, color: "#818cf8", margin: "0 0 12px", borderLeft: "3px solid #818cf8", paddingLeft: 10 }}>
              Memory Leak Suspects ({data.class_suspects.length})
            </h2>
            <div style={{ fontSize: 11, color: "#71717a", marginBottom: 16 }}>
              Click any suspect to see the problematic code pattern and the suggested fix.
            </div>
            {data.class_suspects.map((s, i) => (
              <SuspectCard key={i} suspect={s} expanded={expandedSuspect === i} onToggle={() => setExpandedSuspect(expandedSuspect === i ? null : i)} />
            ))}
          </>
        )}

        {/* ALERTS TAB */}
        {tab === "alerts" && (
          <>
            <h2 style={{ fontSize: 14, color: "#818cf8", margin: "0 0 16px", borderLeft: "3px solid #818cf8", paddingLeft: 10 }}>
              Alert Timeline
            </h2>
            {data.alerts_timeline.map((at, i) => (
              <div key={i} style={{ marginBottom: 12 }}>
                <div onClick={() => setExpandedAlert(expandedAlert === i ? null : i)} style={{
                  background: "#13151f", border: "1px solid #1e2030",
                  borderLeft: `3px solid ${at.overall_severity === "CRITICAL" ? "#ef4444" : "#f59e0b"}`,
                  borderRadius: 8, padding: "12px 16px", cursor: "pointer"
                }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
                    <Badge severity={at.overall_severity} />
                    <span style={{ fontSize: 11, color: "#71717a" }}>{at.timestamp}</span>
                    <span style={{ fontSize: 11, color: "#52525b", marginLeft: "auto" }}>
                      Heap: {at.heap_old_gen_pct}% · Threads: {at.thread_count}
                    </span>
                  </div>
                  {at.alerts.map((a, j) => (
                    <div key={j} style={{ fontSize: 12, color: "#d4d4d8", marginBottom: 2 }}>
                      {a.type}: {a.message}
                    </div>
                  ))}
                  {expandedAlert === i && at.alerts.map((a, j) => (
                    <div key={`fix-${j}`} style={{ marginTop: 8, padding: "8px 12px", background: "rgba(34,197,94,0.06)", borderRadius: 6 }}>
                      <div style={{ fontSize: 11, color: "#22c55e", fontWeight: 600, marginBottom: 4 }}>💡 FIX: {a.type}</div>
                      <div style={{ fontSize: 12, color: "#a1a1aa", lineHeight: 1.6 }}>{a.solution}</div>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </>
        )}

        {/* WILDFLY TAB */}
        {tab === "wildfly" && (
          <>
            <h2 style={{ fontSize: 14, color: "#818cf8", margin: "0 0 16px", borderLeft: "3px solid #818cf8", paddingLeft: 10 }}>
              WildFly Subsystem Issues
            </h2>
            {data.wildfly_issues.map((w, i) => (
              <div key={i} style={{
                background: "#13151f", border: "1px solid #1e2030",
                borderLeft: `3px solid ${w.severity === "CRITICAL" ? "#ef4444" : "#f59e0b"}`,
                borderRadius: 8, padding: "14px 16px", marginBottom: 10
              }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
                  <Badge severity={w.severity} />
                  <code style={{ fontSize: 11, color: "#818cf8" }}>{w.subsystem}</code>
                </div>
                <div style={{ fontSize: 13, color: "#d4d4d8", marginBottom: 8 }}>{w.issue}</div>
                <div style={{ padding: "8px 12px", background: "rgba(34,197,94,0.06)", borderRadius: 6 }}>
                  <span style={{ fontSize: 11, color: "#22c55e", fontWeight: 600 }}>💡 FIX: </span>
                  <span style={{ fontSize: 12, color: "#a1a1aa" }}>{w.solution}</span>
                </div>
              </div>
            ))}

            <h3 style={{ fontSize: 12, color: "#818cf8", margin: "24px 0 10px", textTransform: "uppercase", letterSpacing: 1 }}>Recommended standalone.conf Flags</h3>
            <CodeBlock code={`# Add to ${"{WILDFLY_HOME}"}/bin/standalone.conf\nJAVA_OPTS="$JAVA_OPTS -XX:+HeapDumpOnOutOfMemoryError"\nJAVA_OPTS="$JAVA_OPTS -XX:HeapDumpPath=/opt/wildfly-memdoctor/dumps"\nJAVA_OPTS="$JAVA_OPTS -XX:NativeMemoryTracking=summary"\nJAVA_OPTS="$JAVA_OPTS -XX:MaxMetaspaceSize=512m"\nJAVA_OPTS="$JAVA_OPTS -Xlog:gc*:file=gc.log:time,uptime,level,tags"`} />
          </>
        )}

        {/* DEPLOY TAB */}
        {tab === "deploy" && (
          <>
            <h2 style={{ fontSize: 14, color: "#818cf8", margin: "0 0 16px", borderLeft: "3px solid #818cf8", paddingLeft: 10 }}>
              Deploy Guide: DEV → PROD (Air-Gapped)
            </h2>

            <div style={{ background: "#13151f", border: "1px solid #1e2030", borderRadius: 8, padding: 16, marginBottom: 16 }}>
              <div style={{ fontSize: 12, color: "#d4d4d8", lineHeight: 1.8 }}>
                <strong style={{ color: "#818cf8" }}>Zero internet needed on PROD.</strong> The tool uses only JDK built-in tools (jmap, jstack, jstat, jcmd) and bash.
              </div>
            </div>

            {[
              { step: 1, title: "Configure on DEV", cmd: "vim wildfly-memdoctor/wildfly-memdoctor.sh\n# Edit: WILDFLY_HOME, JAVA_HOME, thresholds" },
              { step: 2, title: "Copy to PROD", cmd: "scp -r wildfly-memdoctor/ user@prod:/opt/wildfly-memdoctor/" },
              { step: 3, title: "Make executable", cmd: "chmod +x /opt/wildfly-memdoctor/wildfly-memdoctor.sh" },
              { step: 4, title: "Install cron + service", cmd: "./wildfly-memdoctor.sh install\nsudo cp wildfly-memdoctor.service /etc/systemd/system/\nsudo systemctl enable --now wildfly-memdoctor" },
              { step: 5, title: "Test with snapshot", cmd: "./wildfly-memdoctor.sh snapshot\n./wildfly-memdoctor.sh dashboard" },
              { step: 6, title: "Pull reports to DEV", cmd: "scp user@prod:/opt/wildfly-memdoctor/reports/* ./reports/\n# Open report_YYYY-MM-DD.html in browser" },
            ].map(s => (
              <div key={s.step} style={{ display: "flex", gap: 12, marginBottom: 12 }}>
                <div style={{ width: 28, height: 28, borderRadius: "50%", background: "#818cf8", color: "#0a0c12", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 13, fontWeight: 700, flexShrink: 0, marginTop: 2 }}>
                  {s.step}
                </div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: "#d4d4d8", marginBottom: 4 }}>{s.title}</div>
                  <CodeBlock code={s.cmd} />
                </div>
              </div>
            ))}

            <div style={{ background: "#13151f", border: "1px solid #22c55e33", borderRadius: 8, padding: 16, marginTop: 20 }}>
              <div style={{ fontSize: 12, color: "#22c55e", fontWeight: 600, marginBottom: 6 }}>📋 Available Commands</div>
              <pre style={{ fontSize: 11, color: "#a1a1aa", margin: 0, lineHeight: 1.8, fontFamily: "inherit" }}>
{`./wildfly-memdoctor.sh snapshot    # One-time heap+thread dump + analysis
./wildfly-memdoctor.sh monitor     # Continuous monitoring (run as service)
./wildfly-memdoctor.sh report      # Generate daily HTML+JSON report
./wildfly-memdoctor.sh install     # Set up systemd + cron
./wildfly-memdoctor.sh dashboard   # Print current status
./wildfly-memdoctor.sh cleanup     # Remove old data`}
              </pre>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
