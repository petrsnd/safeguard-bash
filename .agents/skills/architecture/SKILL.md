---
name: architecture
description: >-
  Use when understanding how safeguard-bash is organized, how scripts share
  authentication and session state, how the utils library fits together, or how
  to add new commands safely.
---
# safeguard-bash Architecture
## 1. Entry point / public API surface (script layout)
The public surface is `src/`. Everything in `src/` except `src/utils/` is meant
to be an executable command.

The same scripts are exposed in two delivery paths:
- `install-local.sh` copies `src/*` into `$HOME/scripts`
- `docker/Dockerfile` copies `src/` into `/scripts`

The repo is therefore organized around shell commands first, with a small
sourced helper layer underneath.

### Script families
The current 77 top-level scripts are easiest to navigate by prefix.

| Family | Purpose | Examples |
|---|---|---|
| `connect-` / `disconnect-` | Session bootstrap and teardown | `connect-safeguard.sh`, `disconnect-safeguard.sh` |
| `invoke-` / `show-` | Generic API helpers and discovery | `invoke-safeguard-method.sh`, `show-safeguard-method.sh` |
| `get-` / `find-` | Read or search Safeguard resources | `get-platform.sh`, `find-event.sh`, `get-access-request.sh` |
| `new-` / `edit-` / `remove-` / `set-` / `clear-` | CRUD and value updates | `new-user.sh`, `edit-event-subscription.sh`, `set-account-password.sh` |
| `enable-` / `disable-` | Feature toggles | `enable-a2a-service.sh`, `disable-a2a-service.sh` |
| `listen-for-` / `handle-` | SignalR listeners and handler orchestration | `listen-for-event.sh`, `handle-a2a-password-event.sh` |
| `install-` / `uninstall-` | Certificate and license operations | `install-license.sh`, `uninstall-trusted-certificate.sh` |
| `start-` / `close-` | Workflow-specific actions | `start-access-request-ssh-session.sh`, `close-access-request.sh` |

### Domain groupings
File names also cluster by Safeguard feature area:
- **Session/core:** `connect-safeguard.sh`, `disconnect-safeguard.sh`,
  `get-logged-in-user.sh`, `invoke-safeguard-method.sh`
- **Users/assets/accounts:** `new-user.sh`, `remove-user.sh`, `new-asset.sh`,
  `new-asset-account.sh`, `get-linked-account.sh`
- **Access requests:** `new-access-request.sh`, `get-actionable-request.sh`,
  `get-access-request-password.sh`, `edit-access-request.sh`
- **A2A:** `new-a2a-registration.sh`, `get-a2a-password.sh`,
  `set-a2a-privatekey.sh`, `new-a2a-access-request.sh`
- **Events:** `get-event.sh`, `find-event.sh`, `new-event-subscription.sh`,
  `listen-for-event.sh`, `handle-event.sh`
- **Appliance/certificates:** `get-appliance-status.sh`,
  `install-trusted-certificate.sh`, `get-support-bundle.sh`

### Common script shape
Most scripts follow this sequence:
1. `print_usage()` first
2. `ScriptDir` from `${BASH_SOURCE[0]}`
3. initialize variables
4. source helpers from `src/utils/`
5. parse flags with `getopts`
6. call `require_login_args` or `require_connect_args`
7. make one API call or run one event loop

Representative examples:
- `new-user.sh` builds a body, POSTs to `Users`, then optionally does follow-up
  PUTs for password and description
- `new-event-subscription.sh` either accepts `-b` or builds the JSON payload
  from `-D`, `-e`, `-T`, and `-U`
- `get-appliance-status.sh` is an anonymous wrapper around
  `invoke-safeguard-method.sh -n`

## 2. Authentication strategy and flow (login scripts)
`connect-safeguard.sh` is the standard login entry point for normal REST work.
It supports three paths.

### Password flow
For non-certificate providers it POSTs to `/RSTS/oauth2/token` with:
- `grant_type: password`
- username/password
- `scope: rsts:sts:primaryproviderid:<provider>`

### Certificate flow
For `-i certificate` it calls `/RSTS/oauth2/token` with client certificate and
private key material, using `grant_type: client_credentials`.

If curl cannot complete client TLS auth, the script falls back to
`openssl s_client` and manually formulates the request.

### PKCE flow
With `-P`, the script simulates the browser-based PKCE flow:
1. generate verifier/challenge and CSRF token
2. initialize the rSTS login controller session
3. submit primary credentials
4. optionally complete secondary/MFA steps
5. generate claims and extract the authorization code
6. exchange the code for an rSTS token

This path is blocked for the certificate provider.

### Final token exchange
All successful standard login paths converge here:
1. obtain an rSTS access token
2. POST it to `/service/core/v<version>/Token/LoginResponse`
3. extract `UserToken`
4. use that Safeguard bearer token for normal REST calls

### Other auth entry points
`invoke-safeguard-method.sh` can run with:
- login-file auth (default)
- explicit bearer token via `-t` or `-T`
- anonymous auth via `-n`

A2A scripts use a separate model:
- client certificate + private key
- `Authorization: A2A <apikey>`
- `src/utils/a2a.sh` for the transport wrapper

## 3. Connection lifecycle (session file, token management)
Shared connection state lives in:

```bash
$HOME/.safeguard_login
```

`connect-safeguard.sh` creates the file with `umask 0077` and stores values such
as `Appliance`, `CABundleArg`, `Provider`, `AccessToken`, `Cert`, `PKey`, and
`Pkce=true` for PKCE sessions.

### Resolution chain
`src/utils/loginfile.sh` owns the lifecycle helpers:
- `handle_ca_bundle_arg` resolves `--cacert` vs insecure `-k`
- `use_login_file` reads the file or auto-runs `connect-safeguard.sh`
- `require_login_args` fills in appliance/token state for normal scripts
- `require_connect_args` prompts for provider, user, cert, key, and password

Typical flow:
1. initialize `Appliance`, `AccessToken`, `CABundle`
2. source `utils/loginfile.sh`
3. call `require_login_args`
4. read from the login file if possible
5. if still missing, run `connect-safeguard.sh -X` to mint a token

### Teardown and refresh
`disconnect-safeguard.sh` deletes the login file and calls
`/service/core/v<version>/Token/Logout`.

Short-lived CRUD commands assume the current token is good for the life of the
process. Long-running handlers do more work:
- `handle-event.sh` checks `LoginMessage`
- it reads `X-TokenLifetimeRemaining`
- it reconnects before expiry when it owns the credentials
- raw bearer-token mode can continue only while that token stays valid

## 4. Key abstractions and their relationships (utils library)
`src/utils/` is the internal helper layer. It is sourced, not invoked as the
main CLI surface.

### `loginfile.sh`
Responsibilities:
- login-file location and parsing
- prompting for missing auth inputs
- provider discovery through `AuthenticationProviders`
- CA bundle normalization
- token bootstrap via `connect-safeguard.sh`

Most authenticated scripts depend on this file directly.

### `common.sh`
This file is intentionally tiny. It only provides:
- `backoff_wait`
- `reset_backoff_wait`

Those helpers are used by reconnecting event handlers such as `handle-event.sh`
and the `handle-a2a-*` scripts.

### `a2a.sh`
`invoke_a2a_method` wraps:
- certificate/key usage
- A2A authorization headers
- optional JSON bodies
- curl first
- `openssl s_client` fallback for TLS client-auth problems

Representative consumers include `get-a2a-password.sh`,
`get-a2a-privatekey.sh`, `set-a2a-password.sh`, and
`new-a2a-access-request.sh`.

### Cert/test utility scripts
The other files in `src/utils/` are support tooling for samples and manual
workflows:
- `convert-pfx-to-pem.sh`
- `add-pem-password.sh`
- `remove-pem-password.sh`
- `new-test-ca.sh`
- `new-test-cert.sh`

### Relationship model
```text
business script
  -> loginfile.sh for auth/session state
  -> invoke-safeguard-method.sh for normal REST
  -> a2a.sh for mTLS + A2A REST
  -> common.sh only if it owns a reconnect loop
```

## 5. Event system (if applicable)
There are two related event stacks.

### Standard Safeguard events
Files involved:
- `listen-for-event.sh`
- `handle-event.sh`
- `new/get/find/edit/remove-event-subscription.sh`
- `get-event.sh`, `find-event.sh`, `get-event-name.sh`,
  `get-event-category.sh`, `get-event-property.sh`

`listen-for-event.sh` does the low-level SignalR work:
1. call `/service/event/signalr/negotiate?negotiateVersion=1`
2. extract `connectionToken`
3. POST the JSON protocol handshake body
4. open the streaming connection
5. strip keepalive/blank lines and pretty-print payloads

`handle-event.sh` is the resilient wrapper around that transport. It validates
prereqs (`jq`, `coproc`, executable handler), refreshes tokens, runs the
listener as a coprocess, filters events with `jq --unbuffered`, and invokes the
handler with four stdin lines: appliance, access token, CA bundle path, and the
event JSON.

### A2A events
Files involved:
- `listen-for-a2a-event.sh`
- `handle-a2a-password-event.sh`
- `handle-a2a-privatekey-event.sh`
- `handle-a2a-apikeysecret-event.sh`

This stack listens to `/service/a2a/signalr` and authenticates with client
certs + API key instead of a bearer token.

The specialized `handle-a2a-*` scripts all follow the same pattern:
1. fetch the current secret once at startup
2. call the handler immediately with that initial value
3. listen for matching A2A events
4. refetch the secret after each event
5. invoke the handler with the refreshed material

That refetch-after-event design is deliberate: the event is only a trigger.

## 6. Extension points (how to add new scripts)
### Normal REST commands
Use this path unless the feature is truly special-case:
1. add `src/<verb>-<resource>.sh`
2. source `utils/loginfile.sh`
3. call `require_login_args`
4. build the relative URL and JSON body
5. delegate the HTTP call to `invoke-safeguard-method.sh`
6. check `.Code` and return JSON consistently

`new-user.sh` and `new-event-subscription.sh` are good modern examples.

### Anonymous commands
Follow `get-appliance-status.sh` and call `invoke-safeguard-method.sh -n`.

### A2A commands
Follow `get-a2a-password.sh` or `set-a2a-privatekey.sh`:
- source `utils/a2a.sh`
- gather appliance/cert/key/password/API key inputs
- call `invoke_a2a_method`
- only bypass it for streaming or handshake-only cases

### Event consumers
Keep the current split:
- low-level connection logic in `listen-for-*.sh`
- reconnection/filtering in `handle-*.sh`
- business logic in the external handler script passed by `-S`

### Tests and packaging
When you add a public command:
- add or extend an integration suite under `test/suites/`
- use `test/framework.sh` helpers instead of ad hoc assertions
- do not change the main Dockerfile unless packaging behavior itself changed;
  it already copies the entire `src/`, `samples/`, and `test/` trees

For turnkey demos, follow the sample pattern in `samples/certificate-login/` or
`samples/event-handling/`: derive from the main image and copy only the extra
script(s) and assets.
