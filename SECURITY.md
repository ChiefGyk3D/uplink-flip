# Security policy

## Reporting a vulnerability

Please report security problems privately. Use GitHub's "Report a
vulnerability" button on the Security tab of this repository (private
vulnerability reporting). Do not open a public issue or pull request for a
vulnerability, and do not include exploit detail in a public place.

Include the version (`uplink-flip --version`), what you did, what you expected
and what happened. Say which NetworkManager version you run.

You can expect an acknowledgement within a few days. Fixes land on the default
branch and are noted in the release notes after the report is resolved.

## Scope and design notes

uplink-flip runs as your own user and never calls `sudo`. It changes only
NetworkManager connection profiles you are allowed to modify, through `nmcli`.
It does not use `eval`, reads its config file as plain `KEY=VALUE` data (never
sourced), validates every value it reads from `nmcli`, and keeps its state in a
mode 700 directory with a mode 600 file. Issues in any of those areas are in
scope.
