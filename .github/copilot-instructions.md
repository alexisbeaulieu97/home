# Environment Setup Repository

This is a modular, portable environment setup repository for installing and maintaining development/ops environments across Linux, macOS, and WSL. It emphasizes cross-platform portability, ACL management, and safer upgrades.

**ALWAYS follow these instructions first and fallback to additional search and context gathering only if the information in the instructions is incomplete or found to be in error.**

## Working Effectively

### Bootstrap the Environment
Run the bootstrap process to install dependencies:
```bash
make bootstrap
```
- **Timing**: Takes approximately 8-10 seconds on systems with package manager access
- **Dependencies installed**: `jq` (all platforms), `acl` utilities (Linux/WSL only)
- **Platform detection**: Automatically detects Linux, macOS, WSL and selects appropriate package manager
- **NEVER CANCEL**: Always let bootstrap complete, even if it appears slow

### Apply ACL Rules (Linux/WSL Only)
Use the ACL management system to apply filesystem access control rules:
```bash
# Apply ACL rules from configuration file
make acl CONFIG=modules/acl/examples/test.json ARGS="--dry-run"

# Apply specific example configurations
make acl CONFIG=modules/acl/examples/example_1.json ARGS="--dry-run"
make acl CONFIG=modules/acl/examples/example_2.json ARGS="--dry-run"
```
- **Timing**: Dry-run operations take 0.05-0.2 seconds depending on complexity
- **Linux/WSL only**: macOS does not support `setfacl` by default
- **Always use --dry-run first**: Validate configuration before applying changes
- **NEVER CANCEL**: ACL operations are quick but let them complete

### Upgrade Repository Safely
Run safe upgrades with automatic backup:
```bash
make upgrade
```
- **Timing**: Takes approximately 2-3 seconds plus bootstrap time
- **Safety**: Creates backup tags before pulling changes
- **Auto-recovery**: Instructions provided if rebase fails
- **NEVER CANCEL**: Let the full upgrade process complete

### Format Code (Placeholder)
```bash
make fmt
```
- **Current status**: No-op placeholder command
- **Purpose**: Future shell script formatting integration

## Validation

### Always Test ACL Changes
- **CRITICAL**: Always use `--dry-run` before applying ACL changes
- **Test with real paths**: Create test directories under `/tmp` to validate configurations
- **Example validation**:
  ```bash
  # Create test structure
  mkdir -p /tmp/test-acl/{srv/app,data/share}
  
  # Test configuration
  make acl CONFIG=modules/acl/examples/test.json ARGS="--dry-run"
  ```

### Verify Platform Dependencies
Always ensure required tools are available:
```bash
# Check dependencies
which jq setfacl
```

### JSON Configuration Validation
**CRITICAL**: All ACL JSON configurations must be valid JSON (no comments):
```bash
# Validate JSON syntax
jq . modules/acl/examples/example_1.json
```

## Common Tasks

### Repository Structure
```
.
├── .github/           # GitHub configuration
├── .gitignore        # Git ignore patterns
├── README.md         # Main documentation
├── Makefile          # Command entry points
├── bin/
│   ├── bootstrap     # Cross-platform dependency installer
│   └── acl-apply     # ACL engine wrapper
├── modules/
│   └── acl/
│       ├── engine.sh     # ACL management engine
│       ├── schema.json   # ACL configuration schema
│       ├── README.md     # ACL documentation
│       └── examples/     # Example configurations
│           ├── example_1.json  # Complex multi-rule example
│           ├── example_2.json  # Advanced patterns example
│           └── test.json       # Simple validation example
└── scripts/
    ├── lib/
    │   └── os.sh         # OS detection utilities
    └── upgrade.sh        # Safe upgrade mechanism
```

### Direct Command Usage
You can also use commands directly:

**Bootstrap directly**:
```bash
bin/bootstrap
```

**ACL engine directly**:
```bash
bin/acl-apply -f modules/acl/examples/test.json --dry-run
# Or with full path to engine:
modules/acl/engine.sh -f modules/acl/examples/test.json --help
```

**Upgrade directly**:
```bash
scripts/upgrade.sh
```

### Platform-Specific Notes

**Linux/WSL**:
- Full functionality available
- ACL support via `setfacl` command
- Package management via `apt-get`, `dnf`, `yum`, `zypper`, or `pacman`

**macOS**:
- Bootstrap installs `jq` via Homebrew
- ACL functionality not available (setfacl not supported)
- Warning displayed during bootstrap about ACL limitations

**Cross-platform**:
- OS detection handled automatically by `scripts/lib/os.sh`
- Platform-appropriate package managers detected and used

## Timing Expectations and Timeouts

**NEVER CANCEL any of these operations - they are designed to be reliable:**

- **Bootstrap**: 8-10 seconds (includes package manager updates)
  - Set timeout to 60+ seconds minimum
  - May take longer on slow networks or first-time package installs
  
- **ACL operations**: 0.05-0.2 seconds for dry-run, up to 2 seconds for complex real applications
  - Set timeout to 30+ seconds for safety
  - Complex configurations with many rules may take longer
  
- **Upgrade**: 2-3 seconds plus bootstrap time (10-15 seconds total)
  - Set timeout to 120+ seconds minimum
  - Depends on git fetch and rebase operations

## Error Handling and Recovery

### Common Error Scenarios

**Missing JSON file**:
```
ERROR: Cannot read definitions file 'filename.json'. Check file exists and has read permissions.
```
- **Solution**: Verify file path and permissions

**Invalid JSON syntax**:
```
ERROR: Invalid JSON syntax in 'filename.json'. Use 'jq .' to validate JSON format.
```
- **Solution**: Remove comments, fix JSON syntax, validate with `jq .`

**Missing dependencies**:
```
Missing required commands: setfacl. Try: apt-get install acl (Ubuntu/Debian)
```
- **Solution**: Run `make bootstrap` or install missing packages manually

**Upgrade conflicts**:
```
Rebase failed. You can rollback with: git reset --hard pre-upgrade-TIMESTAMP
```
- **Solution**: Use provided rollback command and resolve conflicts manually

## ACL Configuration Reference

### Example ACL Targets
The ACL system can manage permissions for:
- Application directories (`/srv/app`)
- Log directories (`/srv/app/logs`) 
- Script directories (`/srv/app/scripts`)
- Data directories (`/data/share`)
- Custom paths as defined in JSON configurations

### ACL Entry Types
- `user`: Named user permissions
- `group`: Named group permissions  
- `owner`: File/directory owner permissions
- `owning_group`: File/directory group permissions
- `other`: Other users permissions
- `mask`: Maximum effective permissions

### Permission Strings
- Format: `rwx`, `r-x`, `r--`, `---` etc.
- `r`: Read permission
- `w`: Write permission  
- `x`: Execute permission
- `X`: Execute only if directory or already executable
- `-`: No permission

## Files That Should Never Be Modified

**CRITICAL**: Do not modify these without understanding their purpose:
- `bin/bootstrap` - Cross-platform dependency installer
- `bin/acl-apply` - Thin wrapper for ACL engine
- `modules/acl/engine.sh` - Complex ACL management engine
- `scripts/lib/os.sh` - OS detection library
- `scripts/upgrade.sh` - Safe upgrade mechanism

## Repository Maintenance

### Adding New ACL Rules
1. Create JSON configuration following `modules/acl/schema.json`
2. Test with `--dry-run` first
3. Validate JSON syntax with `jq .`
4. Test with real filesystem paths

### Updating Dependencies
- Run `make upgrade` for safe repository updates
- Dependencies are managed automatically by bootstrap process
- Manual package installation rarely needed

### Cross-Platform Testing
- Test bootstrap on different OS families when possible
- Verify OS detection works correctly
- Validate package manager selection