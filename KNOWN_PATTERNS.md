###############################################################################
# KNOWN MEMORY LEAK PATTERNS — WildFly / Java EE
# ═══════════════════════════════════════════════════════════════════════════════
# This file is a reference catalog of common memory leak patterns.
# The memdoctor analysis engine uses these to match against class histogram
# and thread dump findings.
#
# Format per entry:
#   PATTERN_ID | SEVERITY | CLASS_PATTERN | DESCRIPTION | BAD_CODE | FIX_CODE
###############################################################################

#─── 1. DATABASE CONNECTION LEAKS ─────────────────────────────────────────────

PATTERN: DB_CONNECTION_LEAK
SEVERITY: CRITICAL
CLASSES: java.sql.Connection, com.mysql.jdbc.ConnectionImpl, oracle.jdbc.driver.T4CConnection, org.postgresql.jdbc.PgConnection
SYMPTOM: Growing active connection count in pool, "Unable to acquire connection" errors
DESCRIPTION: Database connections obtained but not returned to pool

BAD CODE:
```java
// ❌ Connection never closed if exception occurs
public List<User> getUsers() {
    Connection conn = dataSource.getConnection();
    PreparedStatement ps = conn.prepareStatement("SELECT * FROM users");
    ResultSet rs = ps.executeQuery();
    List<User> users = new ArrayList<>();
    while (rs.next()) {
        users.add(mapUser(rs));
    }
    return users;  // conn, ps, rs never closed!
}
```

FIX CODE:
```java
// ✅ try-with-resources ensures cleanup
public List<User> getUsers() {
    try (Connection conn = dataSource.getConnection();
         PreparedStatement ps = conn.prepareStatement("SELECT * FROM users");
         ResultSet rs = ps.executeQuery()) {
        List<User> users = new ArrayList<>();
        while (rs.next()) {
            users.add(mapUser(rs));
        }
        return users;
    }  // All three auto-closed here, even on exception
}
```

WILDFLY CONFIG FIX (standalone.xml):
```xml
<!-- Add leak detection to your datasource -->
<datasource jndi-name="java:jboss/datasources/MyDS" pool-name="MyDS">
    <connection-url>jdbc:mysql://localhost:3306/mydb</connection-url>
    <pool>
        <min-pool-size>5</min-pool-size>
        <max-pool-size>30</max-pool-size>
        <!-- Detect and close leaked connections -->
        <flush-strategy>IdleConnections</flush-strategy>
    </pool>
    <validation>
        <check-valid-connection-sql>SELECT 1</check-valid-connection-sql>
        <validate-on-match>false</validate-on-match>
        <background-validation>true</background-validation>
        <background-validation-millis>30000</background-validation-millis>
    </validation>
    <timeout>
        <!-- Auto-close connections idle for >5 min -->
        <idle-timeout-minutes>5</idle-timeout-minutes>
        <!-- Detect connections held too long -->
        <allocation-retry>2</allocation-retry>
        <allocation-retry-wait-millis>3000</allocation-retry-wait-millis>
    </timeout>
</datasource>
```

#─── 2. ENTITYMANAGER / JPA SESSION LEAK ──────────────────────────────────────

PATTERN: JPA_SESSION_LEAK
SEVERITY: CRITICAL
CLASSES: org.hibernate.internal.SessionImpl, org.hibernate.engine.spi.EntityEntry, org.hibernate.collection.internal.PersistentBag
SYMPTOM: Growing SessionImpl count, Hibernate first-level cache growing unbounded

BAD CODE:
```java
// ❌ Manual EntityManager without closing
@Stateless
public class OrderService {
    @PersistenceUnit
    private EntityManagerFactory emf;

    public void processOrders() {
        EntityManager em = emf.createEntityManager();
        // Process thousands of orders...
        for (int i = 0; i < 10000; i++) {
            Order order = em.find(Order.class, i);
            order.setStatus("PROCESSED");
            em.merge(order);
            // Hibernate L1 cache grows with every entity!
        }
        // em never closed!
    }
}
```

FIX CODE:
```java
// ✅ Use container-managed EM + batch clearing
@Stateless
public class OrderService {
    @PersistenceContext
    private EntityManager em;  // Container-managed: auto-closed per tx

    public void processOrders() {
        int batchSize = 50;
        for (int i = 0; i < 10000; i++) {
            Order order = em.find(Order.class, i);
            order.setStatus("PROCESSED");
            em.merge(order);

            if (i % batchSize == 0) {
                em.flush();   // Write to DB
                em.clear();   // Free L1 cache memory!
            }
        }
    }
}
```

#─── 3. STATIC COLLECTION GROWTH ─────────────────────────────────────────────

PATTERN: STATIC_COLLECTION_LEAK
SEVERITY: CRITICAL
CLASSES: java.util.HashMap, java.util.ArrayList, java.util.HashSet, java.util.concurrent.ConcurrentHashMap
SYMPTOM: Steadily growing heap, class histogram shows large collection counts

BAD CODE:
```java
// ❌ Static map grows forever
public class AuditLogger {
    // This NEVER gets cleaned up!
    private static final Map<String, List<AuditEntry>> auditCache = new HashMap<>();

    public void logAction(String userId, String action) {
        auditCache.computeIfAbsent(userId, k -> new ArrayList<>())
                  .add(new AuditEntry(action, Instant.now()));
        // Map grows with every user, every action, forever
    }
}
```

FIX CODE:
```java
// ✅ Option A: Use bounded cache (Caffeine or Guava)
public class AuditLogger {
    private static final Cache<String, List<AuditEntry>> auditCache =
        Caffeine.newBuilder()
            .maximumSize(10_000)          // Max entries
            .expireAfterWrite(Duration.ofHours(1))  // TTL
            .build();

    public void logAction(String userId, String action) {
        List<AuditEntry> entries = auditCache.get(userId, k -> new ArrayList<>());
        entries.add(new AuditEntry(action, Instant.now()));
    }
}

// ✅ Option B: Use WeakHashMap (entries GC'd when key is no longer referenced)
private static final Map<String, List<AuditEntry>> auditCache =
    Collections.synchronizedMap(new WeakHashMap<>());

// ✅ Option C: Use LinkedHashMap with max size
private static final Map<String, List<AuditEntry>> auditCache =
    Collections.synchronizedMap(new LinkedHashMap<>(100, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry eldest) {
            return size() > 10_000;
        }
    });
```

#─── 4. THREAD LEAK (ExecutorService) ────────────────────────────────────────

PATTERN: THREAD_LEAK
SEVERITY: CRITICAL
CLASSES: java.lang.Thread, java.util.concurrent.ThreadPoolExecutor, java.util.concurrent.ForkJoinPool
SYMPTOM: Thread count continuously growing, eventual "unable to create native thread"

BAD CODE:
```java
// ❌ New executor per request, never shut down
@Path("/process")
public class ProcessResource {
    @POST
    public Response process(Data data) {
        // Creates a NEW thread pool for EVERY request!
        ExecutorService executor = Executors.newFixedThreadPool(5);
        executor.submit(() -> heavyProcessing(data));
        return Response.accepted().build();
        // executor never shut down — 5 threads leaked per request!
    }
}
```

FIX CODE:
```java
// ✅ Use container-managed executor (WildFly)
@Path("/process")
public class ProcessResource {
    // Inject WildFly's managed executor — properly lifecycle'd
    @Resource(name = "java:jboss/ee/concurrency/executor/default")
    private ManagedExecutorService executor;

    @POST
    public Response process(Data data) {
        executor.submit(() -> heavyProcessing(data));
        return Response.accepted().build();
    }
}
```

WILDFLY CONFIG (standalone.xml):
```xml
<subsystem xmlns="urn:jboss:domain:ee:6.0">
    <concurrent>
        <managed-executor-services>
            <managed-executor-service name="default"
                jndi-name="java:jboss/ee/concurrency/executor/default"
                context-service="default"
                core-threads="5"
                max-threads="25"
                keepalive-time="5000"/>
        </managed-executor-services>
    </concurrent>
</subsystem>
```

#─── 5. CLASSLOADER LEAK (Hot Redeploy) ──────────────────────────────────────

PATTERN: CLASSLOADER_LEAK
SEVERITY: WARNING
CLASSES: org.jboss.modules.ModuleClassLoader, java.lang.ClassLoader
SYMPTOM: Metaspace/PermGen growing after each redeploy, eventual OOM: Metaspace

BAD CODE:
```java
// ❌ ThreadLocal holding reference to webapp class prevents classloader GC
public class RequestContext {
    // This ThreadLocal prevents the ENTIRE webapp classloader from being GC'd
    // after redeployment, because the Thread survives redeployment
    private static final ThreadLocal<MyWebappObject> context =
        new ThreadLocal<>();

    public static void set(MyWebappObject obj) {
        context.set(obj);
    }
    // No cleanup on undeploy!
}
```

FIX CODE:
```java
// ✅ Always clean ThreadLocals
public class RequestContext {
    private static final ThreadLocal<MyWebappObject> context =
        new ThreadLocal<>();

    public static void set(MyWebappObject obj) {
        context.set(obj);
    }

    public static void clear() {
        context.remove();  // MUST call this!
    }
}

// ✅ Use a ServletRequestListener to auto-cleanup
@WebListener
public class ContextCleanupListener implements ServletRequestListener {
    @Override
    public void requestDestroyed(ServletRequestEvent sre) {
        RequestContext.clear();  // Clean on every request end
    }
}

// ✅ Or even better: use CDI @RequestScoped instead of ThreadLocal
@RequestScoped
public class RequestContext {
    private MyWebappObject currentObject;
    // CDI handles lifecycle automatically!
}
```

#─── 6. HTTP SESSION BLOAT ────────────────────────────────────────────────────

PATTERN: SESSION_BLOAT
SEVERITY: WARNING
CLASSES: io.undertow.servlet.spec.HttpSessionImpl, org.wildfly.clustering.web.session
SYMPTOM: Growing heap correlated with user count, sessions not expiring

BAD CODE:
```java
// ❌ Storing large objects in session
@WebServlet("/dashboard")
public class DashboardServlet extends HttpServlet {
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        HttpSession session = req.getSession();
        // Storing entire report (could be megabytes!) in session
        List<ReportData> fullReport = reportService.generateFullReport();
        session.setAttribute("report", fullReport);  // MB per user!
        // Also: no session timeout configured
    }
}
```

FIX CODE:
```java
// ✅ Store only IDs/keys in session, fetch data on demand
@WebServlet("/dashboard")
public class DashboardServlet extends HttpServlet {
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        HttpSession session = req.getSession();
        // Store only the report ID, not the data
        String reportId = reportService.generateAndCache("user123");
        session.setAttribute("reportId", reportId);  // Just a string!
    }
}
```

WILDFLY CONFIG (web.xml):
```xml
<!-- Set session timeout to 30 minutes -->
<session-config>
    <session-timeout>30</session-timeout>
</session-config>
```

#─── 7. STREAM / RESOURCE LEAK ───────────────────────────────────────────────

PATTERN: STREAM_LEAK
SEVERITY: WARNING
CLASSES: java.io.FileInputStream, java.io.BufferedReader, java.net.Socket, javax.net.ssl.SSLSocket
SYMPTOM: Growing file descriptor count, "Too many open files" errors

BAD CODE:
```java
// ❌ Stream not closed on exception
public String readConfig(String path) throws IOException {
    FileInputStream fis = new FileInputStream(path);
    BufferedReader reader = new BufferedReader(new InputStreamReader(fis));
    String content = reader.lines().collect(Collectors.joining("\n"));
    reader.close();  // Never reached if exception above!
    return content;
}
```

FIX CODE:
```java
// ✅ try-with-resources
public String readConfig(String path) throws IOException {
    try (BufferedReader reader = Files.newBufferedReader(Path.of(path))) {
        return reader.lines().collect(Collectors.joining("\n"));
    }  // Auto-closed even on exception
}
```

#─── 8. CDI OBSERVER LEAK ────────────────────────────────────────────────────

PATTERN: CDI_OBSERVER_LEAK
SEVERITY: WARNING
CLASSES: javax.enterprise.event.Event, org.jboss.weld.event.ObserverNotifier
SYMPTOM: Growing number of observer method invocations, slow event processing

BAD CODE:
```java
// ❌ @Dependent-scoped bean observing events stays in memory
@Dependent  // Default scope — new instance for each injection point
public class NotificationHandler {
    // This observer keeps the @Dependent bean alive!
    public void onOrderPlaced(@Observes OrderPlacedEvent event) {
        // Process...
    }
    // Bean never destroyed because observer reference keeps it alive
}
```

FIX CODE:
```java
// ✅ Use @ApplicationScoped for observers
@ApplicationScoped  // Single instance, properly managed
public class NotificationHandler {
    public void onOrderPlaced(@Observes OrderPlacedEvent event) {
        // Process...
    }
}

// ✅ Or use @Disposes/@PreDestroy for cleanup
```

#─── 9. EJB TIMER LEAK ───────────────────────────────────────────────────────

PATTERN: EJB_TIMER_LEAK
SEVERITY: WARNING
CLASSES: org.jboss.as.ejb3.timerservice.TimerImpl, javax.ejb.TimerHandle
SYMPTOM: Growing timer count in WildFly management console

BAD CODE:
```java
// ❌ Creating timers without cleanup
@Stateless
public class PollingService {
    @Resource
    private TimerService timerService;

    public void startPolling(String jobId) {
        // Creates a NEW timer every time called — old ones never cancelled!
        timerService.createIntervalTimer(0, 60000,
            new TimerConfig(jobId, false));
    }
}
```

FIX CODE:
```java
// ✅ Cancel existing timer before creating new one
@Stateless
public class PollingService {
    @Resource
    private TimerService timerService;

    public void startPolling(String jobId) {
        // Cancel any existing timer for this job
        for (Timer timer : timerService.getTimers()) {
            if (jobId.equals(timer.getInfo())) {
                timer.cancel();
            }
        }
        timerService.createIntervalTimer(0, 60000,
            new TimerConfig(jobId, false));
    }

    @PreDestroy
    public void cleanup() {
        // Cancel all timers on undeploy
        timerService.getTimers().forEach(Timer::cancel);
    }
}
```

#─── 10. JNDI LOOKUP CACHING ─────────────────────────────────────────────────

PATTERN: JNDI_LOOKUP_LEAK
SEVERITY: INFO
CLASSES: javax.naming.InitialContext, org.jboss.as.naming.context.NamespaceContextSelector
SYMPTOM: Excessive InitialContext instances, slow JNDI lookups

BAD CODE:
```java
// ❌ New InitialContext per call (expensive + potential leak)
public DataSource getDS() throws NamingException {
    InitialContext ctx = new InitialContext();  // Heavy object!
    return (DataSource) ctx.lookup("java:jboss/datasources/MyDS");
    // ctx never closed!
}
```

FIX CODE:
```java
// ✅ Use @Resource injection instead
@Stateless
public class MyService {
    @Resource(lookup = "java:jboss/datasources/MyDS")
    private DataSource dataSource;
    // Container handles everything. Zero JNDI code needed.
}
```
