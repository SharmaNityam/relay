# Relay implementation plan

Working name Relay. Separate checkout from Specimen. First release supports Codex and Claude Code only. Repro means the original bug-report → generated failing test → unchanged-test fix verification workflow.

## Product modules

1. Sessions: suggested purpose-based project/role/task names, original title retained, parent-child trees, stable IDs, editable persistent local aliases. Explicit optional Codex name sync uses supported app-server RPC; no source database writes. Claude aliases remain local with a native rename command offered.
2. Activity: native macOS status-item app plus local dashboard. Running/waiting/completed/failed/interrupted/stale/unknown, tool/model/project/current task/last activity and reported tokens. Every state has provenance; stale logs are not completion. Missing source data is unknown. Monitoring makes no model/network calls and never reads auth stores.
3. Repro: Python/pytest scoped. Issue + repository → generated test → actual isolated execution → failure classification → unchanged test rerun after fix. Docker-only execution for arbitrary generated code; bounded copied source workspace; no edits to user's checkout. Configurable Claude Code or OpenAI-compatible generation. Clearly labelled deterministic bundled demo when no provider is used.

## Architecture and ownership

- contracts.py: Session/Snapshot dataclasses, shared API model (parent).
- adapters.py, naming.py, store.py: read-only known-path Codex SQLite/JSONL and Claude JSONL adapters, bounded reads/caching, local alias state (cheap agent).
- web/: vanilla responsive dashboard with real APIs, session tree/provider/status filters, detail drawer, local alias and Repro workflow (cheap agent).
- native/, scripts/: Swift/AppKit menu-bar shell with polling and WebKit dashboard window, launches local Python service; local macOS build script (same UI agent).
- server.py, cli.py, repro.py: loopback API, state aggregation, explicit native rename adapter, bounded Repro model/execution jobs, Docker fixture and independent tests (cheap integration agent).
- Parent: integration, acceptance, documentation and packaging.
- Stronger agent: independent parser/status/privacy/repro verification after integration, no feature implementation.

## API

GET /api/health -> {status,version,docker_available,providers:[...]}
GET /api/sessions?demo=1 -> Snapshot dict with sessions/providers/counts/updated_at/total.
Session keys: provider,id,key,parent_id,parent_key,title,display_name,suggested_name,task,cwd,project,role,model,status,status_source,last_event_at,last_activity,tokens,alias(optional).
PATCH /api/sessions/{provider}/{id}/name JSON {name} -> session alias result. Empty name clears alias. Provider/id validated against collected sessions except labelled demo IDs.
POST /api/sessions/{provider}/{id}/sync-name JSON {name} -> explicit Codex supported RPC only; local alias independent.
POST /api/repro JSON {provider:'demo'|'claude'|'openai',repo_path?,issue?} -> {id,status}.
GET /api/repro/{id} -> {id,status,phase,events:[{type,message}],test_code,baseline,verification,error,demo,download_available}.
POST /api/repro/{id}/verify -> rerun same immutable test on refreshed source snapshot.
POST /api/repro/{id}/demo-fix -> patch only the disposable bundled demo, then rerun unchanged test.
GET /api/repro/{id}/download -> evidence ZIP (no source workspace or credentials).

## Boundaries

Read only known session paths. Do not scan credentials/browser cookies. Never display tool command arguments or complete transcripts. Summaries bounded and obvious secrets redacted. Keep original source files untouched. Session display-name edits are local unless explicit native sync is requested. Do not claim inferred states are exact. Recent file mtime alone is not running evidence. App-server notifications apply to loaded threads in that server, so do not launch a separate server and claim it observes all live clients.

Local API binds 127.0.0.1. Validate Host/Origin and content types, reject cross-site mutations, no permissive CORS, no-store and frame restrictions. No public deployment of local session contents. Model code generation sends selected repository snippets only after explicit user action; communicate this in UI. Docker runner stages bounded source, no network/read-only/nonroot/resources/timeouts and explicit cleanup. No silent host fallback.

## Tests

Synthetic parser fixtures: malformed/truncated JSONL, duplicate titles, missing IDs, nested agents, status transitions, stale state, unsupported DB schema, invalid timestamps and total limits. Alias persistence, collision-safe names and no source DB writes. API: provider isolation, malformed Origin/Host, invalid paths/IDs, alias persistence, no secret/tool-argument leakage. Swift build and actual native app. Browser desktop/mobile, filters/name edits/tree/Repro states. Repro: broken generated test vs reported failure, changed test rejection, baseline passing, setup failure, timeout, unchanged-test fix verification and archive allowlist. Real Codex/Claude metadata adapter smoke; explicitly report unavailable sources.

## Cost and delivery

Use inexpensive model builders with independent file ownership. Stronger model only for review. Claude Code available for bounded fallback implementation if usage constrained. No model calls for background monitoring. Persist changes in Git and retry transient failures with backoff. Build locally; no new remote repository destination supplied. README, build log, architecture and short demo storyboard required.
