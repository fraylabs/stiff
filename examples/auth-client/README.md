# Standalone authenticated client

Copy this directory outside Stiff to start an independent Bend application.
It imports a Git-pinned Stiff checkout under `deps/stiff`; there is no hub,
registry account, Node runtime or cross-repository symlink.

Install Git and Stiff's native build prerequisites from the main README, then:

```sh
make setup build
```

`stiff.rev` fixes the exact Stiff commit. Setup fetches that revision directly
from GitHub and installs its checksum-verified Bend compiler locally. Build
checks the dependency revision and refuses tracked edits. Nothing tracks `main`
automatically. To upgrade, review a new commit, update `stiff.rev`, and move the
old `deps/stiff` aside before setup. Keep `stiff.rev` in your application's Git.

Set `STIFF_TOKEN` through your shell or secret manager, then run:

```sh
./build/auth-client https://your-api.example/resource
```

The token comes from the environment, not command-line arguments or source.
The program sends an Authorization bearer header and a custom User-Agent, prints
the response status and JSON `message` field, and exits nonzero for HTTP failures.
The URL is yours to choose; use HTTPS with actual credentials. Redirects are not
followed. Token acquisition/refresh and provider-specific response fields belong
to the application.

Stiff's tests build this example outside its checkout and call a local HTTPS API
using synthetic credentials, including an unauthorized response. Runtime needs
libcurl/json-c and a CA store; it needs no compiler or Python.
