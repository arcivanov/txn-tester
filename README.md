# txn-tester

A single Docker image bundling three DBMS **transaction / isolation bug-detection
tools**, each built from source:

| Tool | Upstream | What it does |
|------|----------|--------------|
| [TROC](https://github.com/tcse-iscas/Troc) | `tcse-iscas/Troc` | Transaction Oracle Construction — MVCC-based isolation oracle (ICSE 2023) |
| [Fucci](https://github.com/Reverie4u/Fucci) | `Reverie4u/Fucci` | Random Conflict Construction + multilevel constraint solving (VLDB 2025) |
| [APTrans](https://github.com/Paper-code-sigmod/APTrans) | `Paper-code-sigmod/APTrans` | Anomaly-pattern-guided transaction bug testing |

All three connect to a **remote DBMS supplied via environment variables**. This
image never builds or starts a database; point it at a running MariaDB/MySQL.

## Build

```bash
docker build -t txn-tester .
```

JDK 21 is used deliberately (TROC/Fucci depend on Lombok annotation processing,
which modern javac no longer runs by default). Upstream commits are pinned via
`ARG`s in the `Dockerfile`.

### Prebuilt image (GHCR)

CI builds and publishes the image to this repo's GitHub Container Registry on
every push to `main` and on `v*` tags:

```bash
docker pull ghcr.io/arcivanov/txn-tester:latest
TXN_TESTER_IMAGE=ghcr.io/arcivanov/txn-tester:latest TOOL=troc \
  DB_HOST=10.0.0.5 DB_USER=root DB_PASSWORD=secret ./run.sh
```

The bundled tool versions are pinned in `.github/workflows/docker-publish.yml`
(the `env:` block) and passed to the Dockerfile's `*_SHA` / `LOMBOK_VERSION`
build-args — bump a tool by editing that workflow, no Dockerfile change needed.

### CI

Every push and pull request **builds the image and runs the smoke test**
(`test/smoke-test.sh`). Pull requests build + test but **do not publish**; pushes
to `main` and `v*` tags build + test + publish to GHCR.

Run the smoke test locally against a built image:

```bash
docker build -t txn-tester .
./test/smoke-test.sh
```

It starts a throwaway MariaDB and runs each tool in `verify` mode, asserting a
clean exit and that each evacuates its artifact to the per-tool output subdir.

## Run

### Recommended: the `run.sh` wrapper

`run.sh` runs the container **as the current user** and mounts a host output
directory, so results are owned by you (not root). Configuration is passed via
environment variables; any extra arguments are forwarded to `docker run`.

```bash
# TROC, 120s fuzz loop against a remote MariaDB; results in ./output
TOOL=troc DURATION=120 \
  DB_HOST=10.0.0.5 DB_USER=root DB_PASSWORD=secret \
  ./run.sh

# APTrans across all isolation levels, 50 cases each; custom output dir
OUTPUT_DIR=./results TOOL=aptrans ISOLATION=all SAMPLE_NUM=50 \
  DB_HOST=10.0.0.5 DB_USER=root DB_PASSWORD=secret \
  ./run.sh

# Quick smoke test; forward a docker flag (--network) to reach a DB by name
TOOL=fucci MODE=verify DB_HOST=mydb DB_USER=root DB_PASSWORD=secret \
  ./run.sh --network mynet
```

`OUTPUT_DIR` for the wrapper is a **host path** (default `./output`); it is
mounted into the container at `/output`. The wrapper supplies
`--user "$(id -u):$(id -g)"` and `-v "$OUTPUT_DIR:/output"` for you.

### Raw `docker run`

The image is arbitrary-uid-safe, so you can invoke it directly. To get
caller-owned output, pass `--user` and mount a writable dir yourself:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" -v "$PWD/output:/output" \
  -e TOOL=troc -e DB_HOST=10.0.0.5 -e DB_USER=root -e DB_PASSWORD=secret \
  txn-tester
```

Without `--user`, the container runs as root and any output it writes to a
mounted host dir is root-owned.

## Environment variables

### Connection (discrete only — no JDBC URL)

| Var | Default | Notes |
|-----|---------|-------|
| `DB_HOST` | `127.0.0.1` | |
| `DB_PORT` | `3306` | |
| `DB_USER` | `root` | |
| `DB_PASSWORD` | *(empty)* | |
| `DB_NAME` | per tool: `txntest_troc` / `txntest_fucci`; `test` otherwise | **TROC/Fucci `DROP DATABASE` and recreate this** — use a throwaway name. APTrans ignores it (uses `test_<isolation>`). |
| `DB_DBMS` | `mariadb` | target flavor: `mariadb` or `mysql` |
| `DB_TABLE` | `t` | TROC/Fucci only |

### Run control

| Var | Default | Notes |
|-----|---------|-------|
| `TOOL` | *(required)* | `troc` \| `fucci` \| `aptrans` |
| `MODE` | `full` | `full` or `verify` (fast smoke) |
| `DURATION` | `60` (`15` in verify) | TROC/Fucci fuzz seconds |
| `SAMPLE_NUM` | `50` (`2` in verify) | APTrans cases per isolation |
| `ISOLATION` | `all` (`serializable` in verify) | APTrans: `serializable` \| `repeatable_read` \| `read_committed` \| `all`. TROC/Fucci ignore it (randomized internally). |
| `OUTPUT_DIR` | container `/output`; wrapper host `./output` | Full logs/artifacts are evacuated here under a per-tool subdir. With `run.sh` this is a host path mounted to `/output`. |

## Output

The full, **unparsed** logs and artifacts are copied out of the container into a
per-tool subdirectory of `OUTPUT_DIR`. With `run.sh`, `OUTPUT_DIR` is a host path
(default `./output`) and results are owned by the current user:

```bash
OUTPUT_DIR=./results TOOL=troc \
  DB_HOST=10.0.0.5 DB_USER=root DB_PASSWORD=secret ./run.sh
```

Layout (one subdir per tool, exact casing):

```
$OUTPUT_DIR/
  troc/      troc.log                 # full log4j log (also streamed to stdout)
  fucci/     Fucci.log                # full log4j log (also streamed to stdout)
  APTrans/   aptrans-console.log      # full run trace (APTrans has no log file)
             cases/                   # generated test cases
             check/                   # anomaly artifacts (one .txt per finding)
```

No normalization is performed — the artifacts are exactly what each tool emits
(TROC/Fucci: log4j text with inline `BUG REPORT` blocks; APTrans: one labeled
`.txt` per anomaly under `check/`).

## Exit codes

None of the upstream tools signal a discovered violation through their own exit
code — TROC/Fucci run an unbounded loop that only *logs* a `BUG REPORT` /
`Error: Inconsistent …` block before being killed by `timeout`, and APTrans only
*writes* artifacts under `check/` then exits `0`. The image therefore inspects
each tool's output and maps a finding onto an **exotic, easily-detected exit
code** so any caller can act on `$?`:

| Exit code | Meaning |
|-----------|---------|
| `0` | Ran cleanly — no anomaly/inconsistency detected |
| `100` | **A transaction anomaly/inconsistency was found** (TROC/Fucci logged a `BUG REPORT`/`Error: Inconsistent …`, or APTrans wrote a `check/` artifact) |
| any other non-zero | Infrastructural/execution failure (e.g. classpath error, connection refused, crash) — **not** a finding |

`100` is chosen so a real finding cannot be confused with a clean run (`0`), a
tool/infrastructure error, or a `timeout` kill (`124`/`143`). Detection runs only
after an otherwise-clean completion, so an infrastructural failure keeps its own
exit code rather than being reported as a finding. The detection logic lives in
`scripts/detect-findings.sh` and is unit-tested by `test/detect-findings-test.sh`.

## Running all three in parallel

One instance each of TROC, Fucci, and APTrans can run concurrently against a
single MariaDB and user. Two requirements, both handled by default:

- **Distinct databases.** All three tools `DROP`/`CREATE` their own database, so
  they must not share one (a distinct table is not enough — the whole database is
  recreated). The default `DB_NAME`s (`txntest_troc`, `txntest_fucci`, and
  APTrans's `test_<isolation>`) keep them separate; only override `DB_NAME` if you
  give each instance a different throwaway name.
- **No server-global side effects.** APTrans's upstream `SET GLOBAL` lock-timeout
  statements are patched to session scope at build time, so a running APTrans no
  longer changes lock-wait behavior for the concurrent TROC/Fucci sessions.

Note: MariaDB has no per-user or per-database variable defaults (only `GLOBAL`
and `SESSION` scopes), which is why session-scoping APTrans's timeouts is the
correct fix rather than confining them to its database.

## Notes on the upstream tools

- **TROC / Fucci** run an unbounded generate-and-check loop with no native
  time/iteration limit, so the container bounds them with `timeout $DURATION`;
  a `timeout`-killed run is a normal completion.
- **APTrans** ships with a committed, unresolved three-way merge (conflict
  markers baked into its single `main` commit) plus hardcoded credentials/ports
  and `screen`-based wrapper scripts. At build time we resolve the conflicts
  (`scripts/accept-theirs.sh`, accepting the APTrans-core side) and at run time
  we drive its SQLancer generator jar and Python executor directly, bypassing
  the stock `generate.sh` / `test.sh`.

## License

This project's own scripts and packaging are licensed under the Apache License
2.0 — see [LICENSE](LICENSE). The bundled tools (TROC, Fucci, APTrans) are built
from their upstream sources and remain under their respective upstream licenses.
