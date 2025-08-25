### ACL module

- Engine: `modules/acl/engine.sh`
- Wrapper: `modules/acl/apply_acls.sh`
- Schema: `modules/acl/schema.json`
- Examples: `modules/acl/examples/*.json`

Usage:

```bash
bin/acl-apply -f modules/acl/examples/example_1.json --dry-run
```

Requirements (Linux/WSL): `jq`, `setfacl`. macOS is not supported for ACL application.

