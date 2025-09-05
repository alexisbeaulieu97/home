# JSON Output Format Documentation

The ACL engine supports JSON output format using the `-o json` or `--output-format json` option.

## Usage

```bash
# Get JSON output instead of human-readable text
./engine.sh -f rules.json --output-format json

# Short form
./engine.sh -f rules.json -o json

# With dry-run
./engine.sh -f rules.json -o json --dry-run
```

## JSON Schema

The JSON output contains the following top-level fields:

### `run` - Execution Metadata
```json
{
  "run": {
    "timestamp": "2025-09-05T19:40:43+00:00",
    "duration_seconds": 1,
    "exit_code": 0,
    "mode": "dry_run"
  }
}
```

- `timestamp`: ISO 8601 formatted timestamp of when the run started
- `duration_seconds`: Total execution time in seconds
- `exit_code`: Process exit code (0=success, 1=error, 2=invalid args, etc.)
- `mode`: Either "apply" or "dry_run"

### `config` - Configuration Used
```json
{
  "config": {
    "definitions_file": "rules.json",
    "color_mode": "auto",
    "mask_setting": "auto",
    "mask_explicit": "",
    "dry_run": true,
    "quiet": false,
    "find_optimization": true,
    "recursive_optimization": true,
    "output_format": "json"
  }
}
```

Contains all configuration options that were active during the run.

### `metrics` - Performance and Result Metrics
```json
{
  "metrics": {
    "paths": {
      "applied": 5,
      "failed": 0,
      "skipped": 2
    },
    "entries": {
      "ok": 15,
      "failed": 0,
      "attempted": 15,
      "success_percentage": 100
    },
    "performance": {
      "cache_hits": 8,
      "optimized_rules": 2
    }
  }
}
```

- `paths`: Counts of filesystem paths processed
- `entries`: Counts of individual ACL entries processed
- `performance`: Performance optimization metrics

### `rules` - Per-Rule Details
```json
{
  "rules": []
}
```

Currently empty - placeholder for future per-rule execution details.

### `warnings` and `errors` - Issues Encountered
```json
{
  "warnings": [
    "Groups not found on system: testgroup"
  ],
  "errors": []
}
```

Arrays of warning and error messages encountered during execution.

## Notes

- In JSON mode, all human-readable output is suppressed
- Errors are still sent to stderr for debugging purposes
- The JSON is written to stdout as a single document at the end of execution
- All strings are properly escaped for JSON compliance
- Numbers are unquoted integers where appropriate

## Example Complete Output

```json
{
  "run": {
    "timestamp": "2025-09-05T19:40:43+00:00",
    "duration_seconds": 1,
    "exit_code": 0,
    "mode": "dry_run"
  },
  "config": {
    "definitions_file": "rules.json",
    "color_mode": "auto",
    "mask_setting": "auto",
    "mask_explicit": "",
    "dry_run": true,
    "quiet": false,
    "find_optimization": true,
    "recursive_optimization": true,
    "output_format": "json"
  },
  "metrics": {
    "paths": {
      "applied": 1,
      "failed": 0,
      "skipped": 0
    },
    "entries": {
      "ok": 1,
      "failed": 0,
      "attempted": 1,
      "success_percentage": 100
    },
    "performance": {
      "cache_hits": 0,
      "optimized_rules": 0
    }
  },
  "rules": [],
  "warnings": [
    "Groups not found on system: testgroup"
  ],
  "errors": []
}
```