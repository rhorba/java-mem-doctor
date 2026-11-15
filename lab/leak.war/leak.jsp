<%@ page import="java.util.*,java.util.concurrent.*" %>
<%!
  // Demo leak 1: a static cache that is never evicted
  static class CachedSession { final String id; final byte[] payload; final Date created = new Date();
    CachedSession(String id, int kb) { this.id = id; this.payload = new byte[kb * 1024]; } }
  static final Map<String, CachedSession> SESSION_CACHE = new ConcurrentHashMap<>();
  // Demo leak 2: an executor created per request and never shut down
  static final List<ExecutorService> POOLS = new ArrayList<>();
%>
<%
  int n = Integer.parseInt(request.getParameter("n") == null ? "50" : request.getParameter("n"));
  int kb = Integer.parseInt(request.getParameter("kb") == null ? "64" : request.getParameter("kb"));
  for (int i = 0; i < n; i++) { String id = UUID.randomUUID().toString(); SESSION_CACHE.put(id, new CachedSession(id, kb)); }
  if ("1".equals(request.getParameter("threads"))) {
    ExecutorService ex = Executors.newFixedThreadPool(4, r -> { Thread t = new Thread(r, "report-export-worker-" + System.nanoTime()); t.setDaemon(true); return t; });
    for (int i = 0; i < 4; i++) ex.submit(() -> { try { Thread.sleep(Long.MAX_VALUE); } catch (InterruptedException e) {} });
    synchronized (POOLS) { POOLS.add(ex); }
  }
%>
cached=<%= SESSION_CACHE.size() %> pools=<%= POOLS.size() %>
