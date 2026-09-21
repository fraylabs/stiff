# Compatibility and upgrades

Stiff 0.2.0 is an experimental native framework release. The supported compiler
is Bend 2.0.20, source `a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc`.
Server builds also pin the experimental libevent 2.2.2-alpha source; see
[dependency policy](dependencies.md). The public API consists of the documented Bend modules and `stiff-run` CLI;
generated C layouts and native effect internals are private. Applications compile
against an exact Stiff Git revision or [BendHub content hash](bendhub.md), with
separately pinned native build tooling.

Before 1.0, a minor release may change a public API; patch releases preserve the
documented API unless correcting behavior that violates its security/bounds
contract. Pin revisions, read the changelog and run application tests before
upgrading. Never replace a live binary simply because a newer compiler exists.

From the earlier unversioned baseline, existing Request, Response, Config and
Incoming constructors and ordinary `Server.reply` behavior remain intact.
Response streams, parameter routes, schemas, SQLite storage and the process
supervisor are opt-in additions. Sanitizer builds now apply the documented narrow
Clang calling-convention mitigation automatically; normal builds keep Bend's ABI.
Transport error bodies move to the shared JSON envelope; applications must inspect
status/code rather than compare legacy plain-text messages.

Upgrade procedure:

1. Save the current revision, binary, configuration and a consistent store backup.
2. Build the new pinned revision on each target platform using its native libraries.
3. Run `make test`, `make test-sanitize`, your application journeys and a workload
   representative of your limits. Check the exact CI revision/platform results.
4. Rehearse start, drain, cancellation, store reopen and rollback in an isolated
   environment. Reconcile uncertain external operations before any retry.
5. Stop admissions and drain/stop the old process, then start one new owner.
   Keep the old binary/configuration until acceptance; never run dual store writers
   as a migration experiment without an explicit data contract.

The SQLite schema has its own checked version; incompatible existing databases
must fail rather than silently reinterpret data. See [store contract](store.md).
Native executables dynamically link system curl/JSON/SQLite libraries as needed
and statically include the pinned libevent for servers. A compiled artifact is
specific to OS/architecture and dependency versions. Rebuild when those change;
no static-binary or universal-binary claim is made.

Linux and macOS arm64/x64 are CI targets. A configured matrix is not evidence of
a passing run: consult the result linked in [the checklist](checklist.md).
Only Linux deployments with an OS/cgroup memory boundary provide the documented
hard resident-memory limit. CPU, cancellation and logging contracts are described
in [execution.md](execution.md).

Release packaging rejects sanitizer builds: those can depend on a compiler-specific
ASan runtime and are for verification, not the normal distribution. The package
manifest distinguishes each binary's instrumentation, statically included libevent,
and runtime shared dependencies. `test_package.py` checks a normal release archive
even when the rest of the suite is running instrumented programs.
