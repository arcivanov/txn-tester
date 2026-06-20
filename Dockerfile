# syntax=docker/dockerfile:1
#
# txn-tester: one image bundling three DBMS transaction/isolation bug-detection
# tools (TROC, Fucci, APTrans), each built FROM SOURCE. All three connect to a
# REMOTE DBMS supplied via environment variables at `docker run`; this image does
# not build or start a database.
#
# Build:
#   docker build -t txn-tester .
#
# Run (examples):
#   docker run --rm -e TOOL=troc    -e DB_HOST=10.0.0.5 -e DB_PORT=3306 \
#       -e DB_USER=root -e DB_PASSWORD=secret -e DURATION=120 txn-tester
#   docker run --rm -e TOOL=aptrans -e DB_HOST=10.0.0.5 -e DB_PORT=3306 \
#       -e DB_USER=root -e DB_PASSWORD=secret -e ISOLATION=all txn-tester
#
# JDK 21 is used on purpose: TROC/Fucci rely on Lombok annotation processing,
# which modern javac (JDK 23+) no longer runs by default from the classpath.

# Pinned upstream commits (immutable).
ARG TROC_REPO=https://github.com/tcse-iscas/Troc
ARG TROC_SHA=a6d50e3f596b356137d2f8c3c8b31a61bf7fe2c5
ARG FUCCI_REPO=https://github.com/Reverie4u/Fucci
ARG FUCCI_SHA=1ab278ee890a3f0fd5ac179346002a107365755d
ARG APTRANS_REPO=https://github.com/Paper-code-sigmod/APTrans
ARG APTRANS_SHA=e9786513c2d78b3ed6a7d3925eeda4346633814c
# Lombok in TROC/Fucci (1.18.22) predates JDK 21 support; bump to a JDK21-capable
# release so annotation processing generates getters/@Slf4j `log`.
ARG LOMBOK_VERSION=1.18.42

# ---------------------------------------------------------------------------
# Builder: JDK 21 + Maven, compiles all three tools from source.
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS builder

ARG TROC_REPO TROC_SHA FUCCI_REPO FUCCI_SHA APTRANS_REPO APTRANS_SHA LOMBOK_VERSION

WORKDIR /opt/tools

# TROC
RUN git clone "$TROC_REPO" troc \
    && git -C troc checkout "$TROC_SHA" \
    && sed -i "s#<version>1.18.22</version>#<version>${LOMBOK_VERSION}</version>#" troc/pom.xml \
    && mvn -B -f troc/pom.xml package -Dmaven.test.skip=true

# Fucci (same build as TROC). Upstream also has a manifest bug: its package is
# `fucci` but pom declares mainClass `Fucci.Main`, so `java -jar` can't find the
# class. Fix the case alongside the Lombok bump.
RUN git clone "$FUCCI_REPO" fucci \
    && git -C fucci checkout "$FUCCI_SHA" \
    && sed -i "s#<version>1.18.22</version>#<version>${LOMBOK_VERSION}</version>#" fucci/pom.xml \
    && sed -i "s#<mainClass>Fucci.Main</mainClass>#<mainClass>fucci.Main</mainClass>#" fucci/pom.xml \
    && mvn -B -f fucci/pom.xml package -Dmaven.test.skip=true

# APTrans: ships a committed unresolved three-way merge; accept the "theirs"
# (APTrans core) side across all conflicted files, then build the generator jar.
RUN git clone "$APTRANS_REPO" aptrans \
    && git -C aptrans checkout "$APTRANS_SHA"
COPY scripts/accept-theirs.sh scripts/patch-aptrans.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/accept-theirs.sh /usr/local/bin/patch-aptrans.sh \
    && accept-theirs.sh /opt/tools/aptrans \
    && patch-aptrans.sh /opt/tools/aptrans \
    && mvn -B -f aptrans/sqlancer/pom.xml package -DskipTests

# ---------------------------------------------------------------------------
# Runtime: JRE 21 + Python 3 for the APTrans executor. No build tooling.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre AS runtime

# APTrans executor is Python; install its libraries from the distro (no pip,
# avoids PEP 668). pymysql -> MySQL/MariaDB driver; psycopg2 only used by the
# postgres path but imported transitively; pandas/numpy/sklearn used by checker.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pymysql \
        python3-psycopg2 \
        python3-pandas \
        python3-numpy \
        python3-sklearn \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/tools /opt/tools
COPY scripts/start.sh scripts/run-jcommander-tool.sh scripts/run-aptrans.sh \
     /opt/txn-tester/

# This image is designed to run as an ARBITRARY uid/gid (e.g.
# `docker run --user "$(id -u):$(id -g)" -v "$PWD/out:/output" ...`) so that
# evacuated output is owned by the caller, not root. An arbitrary uid has no
# entry in /etc/passwd and owns none of these paths, so every directory the
# runtime writes must be world-writable:
#   * /opt/tools  — the tools write their logs/cases/check into their own trees
#   * /output     — default output dir when no host dir is mounted
# HOME=/tmp gives any uid a writable home (some Java/tooling touches user.home).
# USER/LOGNAME give an arbitrary uid (which has no /etc/passwd entry) a username:
# pymysql calls getpass.getuser() at import, which fails otherwise.
# Drop the base image's default uid-1000 user ("ubuntu" on Noble): it serves no
# purpose here and would mask arbitrary-uid issues whenever the caller's uid
# happens to be 1000 (it would resolve via /etc/passwd instead of needing the
# USER env below).
RUN userdel -r ubuntu 2>/dev/null || true \
    && chmod -R a+rwX /opt/tools \
    && chmod a+rx /opt/txn-tester/*.sh \
    && mkdir -p /output \
    && chmod 1777 /output

ENV OUTPUT_DIR=/output \
    HOME=/tmp \
    USER=txntester \
    LOGNAME=txntester
VOLUME /output

WORKDIR /opt/tools

ENTRYPOINT ["/opt/txn-tester/start.sh"]
