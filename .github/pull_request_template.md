## What

## Why

## Testing

<!--
What you ran, and what you did not.
- `mix test --only integration` for any SAP field you added or renamed (it checks them against `$metadata`).
- `mix test --only integration_write` creates a real sales order in the sandbox; say so if you ran it.
-->

## Host apps

This library is a dependency of other apps. Merging does not deploy anything; each app picks the change up when it updates the dependency.

- [ ] No breaking change for host apps, or the break and the upgrade steps are described above
- [ ] `usage-rules.md` and the skills under `usage-rules/skills/` match any change to public behaviour
- [ ] A write still cannot be sent twice (no new retries; the non-GET rule in `Sap.HTTP.ReqAdapter` is intact)
