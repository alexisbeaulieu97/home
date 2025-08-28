### ACL engine: rule-based POSIX ACL application

- **Engine**: `modules/acl/engine.sh`
- **Wrapper**: `bin/acl-apply` (preferred) or `modules/acl/apply_acls.sh`
- **Schema**: `modules/acl/schema.json`
- **Examples**: `modules/acl/examples/*.json`

## What this is
Applies POSIX ACLs to files and directories based on a declarative JSON config. It supports recursion, include/exclude pattern matching (glob or regex), separate ACL for files vs directories, and default ACLs for inheritance.

## Requirements
- Linux or WSL. macOS is not supported for applying ACLs.
- Commands: `jq`, `setfacl`.
  - Debian/Ubuntu: `sudo apt-get install jq acl`
  - RHEL/CentOS/Fedora: `sudo yum install jq acl` or `sudo dnf install jq acl`

## Quick start
Run via the wrapper (paths are relative to the `home/` directory):
```bash
bin/acl-apply -f modules/acl/examples/example_1.json --dry-run
```

Run the engine directly:
```bash
modules/acl/engine.sh -f modules/acl/examples/example_1.json --dry-run
```

Remove `--dry-run` to actually apply ACLs (likely requires sudo):
```bash
sudo bin/acl-apply -f modules/acl/examples/example_1.json
```

## Command-line usage
```bash
Usage: engine.sh -f FILE [OPTIONS] [PATH...]

Apply POSIX ACLs to filesystem paths based on rule-based JSON configuration.
If PATHs are provided, only candidates under these paths are processed.

Required:
  -f, --file FILE     JSON file with ACL definitions

Options:
  --color MODE        Output colors: auto|always|never (default: auto)
  --no-color          Disable colors (equivalent to --color never)
  --mask VALUE        Mask handling: auto|skip|<rwx> (default: auto)
  --dry-run           Simulate without making changes
  -q, --quiet         Suppress informational output (errors still shown)
  -h, --help          Show this help message

Exit Codes:
  0 Success (may include skipped paths)
  1 General Error
  2 Invalid Arguments
  3 Missing Dependencies
  4 File Error
```

## JSON config (schema overview)
See `modules/acl/schema.json` for the full JSON Schema. A minimal example:
```json
{
  "version": "1.0",
  "apply_order": "shallow_to_deep",
  "rules": [
    {
      "id": "example",
      "roots": "/path",
      "recurse": true,
      "include_self": true,
      "match": {
        "types": ["file", "directory"],
        "pattern_syntax": "glob",
        "include": ["**/*"],
        "exclude": []
      },
      "acl": ["g:team:rw-", "o::r--"],
      "default_acl": ["g:team:rwx", "m::rwx"]
    }
  ]
}
```

- **apply_order**: `shallow_to_deep` (default) or `deep_to_shallow` controls traversal order across candidates.
- **rules[].roots**: list of starting paths (files or directories).
- **rules[].recurse**: if true, traverse descendants under each root.
- **rules[].include_self**: if true, also apply ACL to the root objects themselves.
- **rules[].match**: filter candidates beneath roots.
  - `types`: `file` and/or `directory`.
  - `pattern_syntax`: `glob` or `regex`.
  - `include` / `exclude`: pattern lists. With `glob`, `**/*` matches everything.
  - `match_base`: also match against basename.
  - `case_sensitive`: toggle case sensitivity.
- **rules[].acl**: ACL entries either as a shared array (applies to both types) or an object with `files` and/or `directories` arrays.
- **rules[].default_acl**: if present and non-empty, default ACLs are set on matched directories.

## ACL entries and permission mapping
Each entry can be in object form or short string form:
- Object: `{"kind":"user","name":"alice","mode":"rw-"}` → `u:alice:rw-`
- String: `"u:alice:rw-"`, `"g:devops:r-x"`, `"u::rw-"`, `"g::r-x"`, `"o::r--"`, `"m::r-x"`

`mode` (or the trailing part of the string) accepts `r`, `w`, `x`, `X`, `-`. `X` applies execute only to directories and files that already have execute for someone.

## Pattern matching tips
- Glob examples:
  - Include all: `"include": ["**/*"]`
  - Only directories named `config`: `"include": ["**/config"]`, set `types: ["directory"]`
  - Exclude dotfiles: `"exclude": ["**/.*"]`
- Regex examples:
  - Only `.sh` files under scripts: `"pattern_syntax": "regex", "include": ["^scripts/.+\\.sh$"]`

## Mask handling
`--mask` controls how the effective rights mask is handled when calling `setfacl`:
- `auto` (default): let `setfacl` recalculate the mask as needed.
- `skip`: do not recalculate mask (`-n`).
- explicit `rwx` (e.g. `--mask r-x`): apply a specific mask entry and skip recalculation.

## Scoping by PATH arguments
You can pass one or more `PATH` arguments to limit processing to candidates that are equal to or descend from those paths (string-prefix match on path segments). Examples:
```bash
# Only under /srv/app and /data/share
sudo bin/acl-apply -f rules.json /srv/app /data/share
```

## Practical examples
- **Dry run everything in a config**:
```bash
bin/acl-apply -f modules/acl/examples/example_1.json --dry-run
```

- **Apply with explicit mask and no color**:
```bash
sudo bin/acl-apply -f modules/acl/examples/example_1.json --mask r-x --no-color
```

- **Directories only, apply default ACLs** (in config):
```json
{
  "rules": [
    {
      "roots": ["/data/projects"],
      "recurse": true,
      "match": { "types": ["directory"], "include": ["**/*"] },
      "acl": { "directories": ["g:team:rwx"] },
      "default_acl": ["g:team:rwx"]
    }
  ]
}
```

## Troubleshooting
- **Missing required commands**: install `jq` and `acl` (`setfacl`). See Requirements above.
- **Permission denied**: applying ACLs typically requires elevated privileges. Use `sudo`.
- **Group/user not found**: ensure groups/users exist on the system. The engine warns if `getent` is available and cannot find the group.
- **Path does not exist**: non-existent roots are skipped with a warning.
- **Filesystem does not support ACLs**: ensure the filesystem and mount options support POSIX ACLs (e.g., mount with `acl`).
- **macOS**: not supported for applying ACLs. Use WSL or a Linux environment.

## Notes
- Traversal can be `shallow_to_deep` or `deep_to_shallow`. Later rules can refine or override earlier ones because ACL entries are applied per-candidate in the selected order.
- When `--dry-run` is set, no changes are made; a summary is still printed.

## Related files
- Engine: `modules/acl/engine.sh`
- Wrapper: `bin/acl-apply` and `modules/acl/apply_acls.sh`
- Schema: `modules/acl/schema.json`
- Examples: `modules/acl/examples/*.json`

