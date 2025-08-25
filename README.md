## Environment Setup Repository

This repository contains a modular, portable setup for installing and maintaining a development/ops environment across Linux, macOS, and WSL. It emphasizes clarity, portability, maintainability, and safer upgrades.

### Structure

```
bin/
  bootstrap           # One-shot bootstrap for dependencies and initial setup
  acl-apply           # Thin wrapper to apply ACL rules from a JSON file

modules/
  acl/
    apply_acls.sh     # ACL engine (Linux; requires setfacl)
    schema.json       # JSON schema for ACL configuration
    examples/         # Example ACL configs

scripts/
  lib/
    os.sh             # OS and package manager detection helpers
  upgrade.sh          # Safer upgrade flow

Makefile              # Common entry points
```

### Quick start

- Prerequisites: bash, git. On Linux, the ACL engine requires `setfacl`; the bootstrap installs it when possible.

1) Bootstrap the environment

```bash
make bootstrap
```

2) Apply ACL rules (Linux only)

```bash
# Use any JSON config; examples are under modules/acl/examples
make acl CONFIG=modules/acl/examples/example_1.json
```

3) Upgrade this repository safely

```bash
make upgrade
```

### Commands

- `bin/bootstrap`: Installs common dependencies based on OS.
- `bin/acl-apply`: Runs the ACL engine; pass `-f <config.json>` and optional flags.
- `scripts/upgrade.sh`: Fetch/pull with a safety tag, then re-run bootstrap.

### Notes

- macOS does not provide `setfacl` by default; the ACL module targets Linux. The bootstrap will install `jq` on macOS and warn for ACL support.
- WSL is treated as Linux.
- See `modules/acl/schema.json` for config schema and `modules/acl/examples` for samples.

