# RemoteAI Mac Agent

The Agent binds to `127.0.0.1:8787` by default and exposes an authenticated,
versioned protocol. `mock-agent` is a deterministic localhost-only harness for
pairing and catalog tests; run `scripts/agent-e2e-simulator.sh` from the
workspace to exercise it.

Cloudflare Tunnel should be configured externally to forward WSS/HTTPS to this
localhost listener. A Named Tunnel provides a stable development hostname; a
Quick Tunnel is suitable only for temporary testing. The Agent never creates a
Cloudflare account or domain and never stores tunnel credentials.

File transfers are explicit user actions only. There are no file watchers,
scheduled jobs, lifecycle-triggered transfers, or automatic synchronization.
