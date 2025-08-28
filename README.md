## Environment Setup Repository

This repository contains a modular, portable setup for installing and maintaining a development/ops environment across Linux, macOS, and WSL. It emphasizes clarity, portability, maintainability, and safer upgrades.

### Structure

```
bin/
  bootstrap           # One-shot bootstrap for dependencies and initial setup
  acl-apply           # Thin wrapper to apply ACL rules from a JSON file

modules/
  acl/
    engine.sh         # Production-ready ACL engine (Linux; requires setfacl, jq)
    schema.json       # JSON schema for ACL configuration
    test_*.sh         # Comprehensive test suite
    run_tests.sh      # Test runner
    README.md         # Complete usage documentation
    TESTING.md        # Testing guide

scripts/
  lib/
    os.sh             # OS and package manager detection helpers
  upgrade.sh          # Safer upgrade flow

Makefile              # Common entry points
```

### Quick start

- Prerequisites: bash, git. On Linux, the ACL engine requires `setfacl` and `jq`; the bootstrap installs them when possible.

1) Bootstrap the environment

```bash
make bootstrap
```

2) Apply ACL rules (Linux only)

```bash
# Test first (recommended)
cd modules/acl
./engine.sh -f config.json --dry-run

# Apply ACLs
./engine.sh -f config.json

# Run test suite
./run_tests.sh integration
```

3) Upgrade this repository safely

```bash
make upgrade
```

### Commands

- `bin/bootstrap`: Installs common dependencies based on OS.
- `modules/acl/engine.sh`: Production-ready ACL engine with comprehensive validation and testing
- `modules/acl/run_tests.sh`: Test suite runner for validation and integration testing
- `scripts/upgrade.sh`: Fetch/pull with a safety tag, then re-run bootstrap.

### Notes

- macOS does not provide `setfacl` by default; the ACL module targets Linux. The bootstrap will install `jq` on macOS and warn for ACL support.
- WSL is treated as Linux.
- See `modules/acl/README.md` for complete documentation and `modules/acl/TESTING.md` for testing guide.

