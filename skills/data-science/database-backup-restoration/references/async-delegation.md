# Async Delegation Pattern for Long Restores

When a backup is large (500MB+), the restore can take 10–60 minutes.
Do NOT block waiting — delegate the work to a subagent using `delegate_task`.

## Pattern

```python
result = delegate_task(
    context="""... all necessary context: file paths, credentials, SGBD, steps ...""",
    goal="""1. Extract/convert the backup
2. Start the restore in Docker
3. Monitor progress and report every 30s
4. Validate with a query
5. Notify the user
6. Clean up staging""",
)
```

## Live Transcript Monitoring

Each delegated task produces a live transcript file. Give the path to the user:

```bash
tail -f /home/hermes/.hermes/cache/delegation/live/<delegation_id>/task-0.log
```

The subagent streams its reasoning, tool calls, and results there in real time.
This lets the user watch progress without the main agent blocking.

## What Context to Include

The subagent has NO memory of the current conversation. Pass everything:

- Exact file path and size
- SGBD and credentials
- Docker container names and compose file path
- SQL filter scripts for table-only imports
- Credentials for Telegram notification (bot token, chat ID)
- All edge cases and pitfalls (e.g., "the tar is NOT gzipped despite extension")
- Expected duration and what to do on failure

## When to Delegate vs Block

| Scenario | Approach |
|----------|----------|
| File < 100MB, fast restore | Blocking call, process inline |
| File 100MB–5GB | Delegate to subagent, give user live transcript path |
| File > 5GB | Delegate + set terminal background + notify_on_complete for restore command itself |
| User explicitly asked to be notified later | Delegate and return control immediately |

## Cleanup

The subagent should clean up staging, temp dirs, and extracted files.
The main agent does NOT need to monitor — the result re-enters the conversation
when the subagent finishes.