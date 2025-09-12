# ACL Engine

Rule-based POSIX ACL application with pattern matching, type-specific permissions, and recursive operations.

## Quick Start

```bash
# Install dependencies
sudo apt-get install acl jq  # Ubuntu/Debian
sudo yum install acl jq      # RHEL/CentOS

# Apply ACLs (always test first!)
./engine.sh -f config.json --dry-run
./engine.sh -f config.json

# Apply to specific paths only
./engine.sh -f config.json /srv/app /data
```

## Usage

```bash
engine.sh -f FILE [OPTIONS] [PATH...]
```

**Options:**
- `-f, --file FILE` - JSON configuration file (required)
- `--dry-run` - Preview changes without applying
- `--quiet` - Suppress informational output
- `--mask auto|skip|rwx` - Mask handling (default: auto)
- `--color auto|always|never` - Color output (default: auto)
- `--help` - Show detailed help

## Configuration Format

```json
{
  "version": "1.0",
  "apply_order": "shallow_to_deep",
  "rules": [
    {
      "id": "app-permissions",
      "roots": ["/srv/app", "/data/shared"],
      "include_root": true,
      "depth": "infinite",
      "match": {
        "types": ["file", "directory"],
        "pattern_syntax": "glob",
        "include": ["**/*"],
        "exclude": ["*.tmp", ".git/**"]
      },
      "acl": {
        "files": [
          {"kind": "group", "name": "developers", "mode": "rw-"},
          {"kind": "other", "mode": "r--"}
        ],
        "directories": [
          {"kind": "group", "name": "developers", "mode": "rwx"},
          {"kind": "other", "mode": "r-x"}
        ]
      },
      "default_acl": [
        {"kind": "group", "name": "developers", "mode": "rwx"}
      ]
    }
  ]
}
```

## Configuration Reference

### Top Level
- `version` - Config version (default: "1.0")
- `apply_order` - `"shallow_to_deep"` or `"deep_to_shallow"` (default: shallow_to_deep)
- `rules` - Array of ACL rules (required)

### Rule Properties
- `id` - Rule identifier (optional)
- `roots` - Root path(s) - string or array (required)
- `include_root` - Apply to root paths (default: true)
- `depth` - 0=root only; 1=immediate children; N=N levels; "infinite"=full subtree (default: "infinite")
- `match` - Pattern-based filtering (optional)
- `acl` - ACL entries to apply (required)
- `default_acl` - Default ACL for directories (optional)

### Match Filtering
```json
"match": {
  "types": ["file", "directory"],     // Target types
  "pattern_syntax": "glob",           // "glob" or "regex"
  "include": ["**/*.py", "*.conf"],   // Include patterns
  "exclude": ["*.tmp", ".git/**"],    // Exclude patterns
  "case_sensitive": true,             // Case sensitivity (default: true)
  "match_base": true                  // Match basename too (default: true)
}
```

### ACL Entries

**Type-specific format (recommended):**
```json
"acl": {
  "files": [
    {"kind": "group", "name": "developers", "mode": "rw-"},
    {"kind": "other", "mode": "r--"}
  ],
  "directories": [
    {"kind": "group", "name": "developers", "mode": "rwx"},
    {"kind": "other", "mode": "r-x"}
  ]
}
```

**Shared format:**
```json
"acl": [
  {"kind": "group", "name": "developers", "mode": "rw-"},
  {"kind": "other", "mode": "r--"}
]
```

**String shorthand:**
```json
"acl": ["g:developers:rwx", "u:alice:rw-", "o::r--"]
```

### ACL Entry Types
- `"user"` - Named user (requires `name`)
- `"group"` - Named group (requires `name`)
- `"owner"` - File owner (`u::`)
- `"owning_group"` - File's group (`g::`)
- `"other"` - Others (`o::`)
- `"mask"` - Access mask (`m::`)

### Permission Modes
Standard POSIX: `rwx`, `rw-`, `r-x`, `r--`, `---`, etc.
Use `X` for conditional execute (directories and existing executables).

## Examples

### Simple File Permissions
```json
{
  "rules": [
    {
      "roots": "/shared/docs",
      "include_root": true,
      "depth": "infinite",
      "acl": {
        "files": ["g:editors:rw-", "o::r--"],
        "directories": ["g:editors:rwx", "o::r-x"]
      }
    }
  ]
}
```

### Pattern-Based Rules
```json
{
  "rules": [
    {
      "roots": "/project",
      "include_root": true,
      "depth": 0,
      "match": {
        "pattern_syntax": "glob",
        "include": ["**/*.py", "**/*.sh"],
        "exclude": ["**/test*", "**/.git/**"]
      },
      "acl": ["g:devs:rwx", "o::r-x"]
    }
  ]
}
```

### User-Specific Access
```json
{
  "rules": [
    {
      "roots": "/secure/data",
      "recurse": true,
      "acl": [
        {"kind": "user", "name": "alice", "mode": "rwx"},
        {"kind": "user", "name": "bob", "mode": "r-x"},
        {"kind": "other", "mode": "---"}
      ]
    }
  ]
}
```

## Testing

```bash
# Run all tests
./run_tests.sh

# Run integration tests (recommended)
./run_tests.sh integration

# Check dependencies
./run_tests.sh --check-deps
```

See [TESTING.md](TESTING.md) for detailed testing documentation.

## Best Practices

1. **Always test first**: Use `--dry-run` before applying
2. **Validate JSON**: Use `jq . config.json` to check syntax
3. **Check groups**: Ensure groups exist with `getent group groupname`
4. **Backup ACLs**: Use `getfacl -R /path > backup.acl` before changes
5. **Start simple**: Begin with basic rules, add complexity gradually
6. **Use patterns wisely**: Exclude temporary and version control files

## Troubleshooting

**Missing dependencies:**
```bash
which jq setfacl  # Check availability
```

**Invalid JSON:**
```bash
jq . config.json  # Validate syntax
```

**Group doesn't exist:**
```bash
getent group groupname  # Check existence
```

**Permission issues:**
```bash
ls -la /path/to/target  # Check access
```

## Exit Codes
- `0` - Success
- `1` - General error
- `2` - Invalid arguments
- `3` - Missing dependencies
- `4` - File error

## Directory Structure

```
modules/acl/
├── engine.sh              # Main ACL engine script
├── README.md              # This documentation
├── TESTING.md             # Testing documentation
├── run_tests.sh           # Test runner script
├── test_*.sh              # Unit and integration tests
├── schemas/               # JSON schema and format analysis
│   ├── schema.json        # JSON schema for validation
│   ├── format_analysis.md # Analysis of different format approaches
│   ├── format_comparison.json # Side-by-side format comparisons
│   ├── alternative_format.json # Alternative format proposals
│   └── README.md          # Schema documentation
└── examples/              # Working configuration examples
    ├── working_minimal.json # Simple working configuration
    ├── clean_example_1.json # Complex multi-rule example
    ├── minimal.json        # Minimal configuration template
    └── README.md           # Examples documentation
```

### Schema Validation

```bash
# Validate your configuration against the schema
jq -f schemas/schema.json your_config.json

# Basic JSON validation
jq . your_config.json
```

### Format Analysis

For detailed analysis of different configuration formats and alternative proposals, see the `schemas/` directory. This includes:
- Current format assessment and trade-offs
- Alternative format proposals
- Side-by-side comparisons
- Recommendations for different use cases