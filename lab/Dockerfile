# Lab: WildFly with a small app that leaks on purpose, to test wildfly-memdoctor.sh
# Build from the repo root:  docker build -f lab/Dockerfile -t memlab .
FROM quay.io/wildfly/wildfly:40.0.1.Final-jdk17
COPY --chown=jboss:0 lab/leak.war /opt/jboss/wildfly/standalone/deployments/leak.war
RUN touch /opt/jboss/wildfly/standalone/deployments/leak.war.dodeploy
COPY --chown=jboss:0 --chmod=755 wildfly-memdoctor.sh KNOWN_PATTERNS.md /opt/wildfly-memdoctor/
USER root
RUN chown jboss:0 /opt/wildfly-memdoctor
USER jboss
ENV JAVA_OPTS="-Xms64m -Xmx256m -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true -Djboss.modules.system.pkgs=org.jboss.byteman -Djava.awt.headless=true"
ENV WILDFLY_HOME=/opt/jboss/wildfly MEMDOCTOR_HOME=/opt/wildfly-memdoctor
