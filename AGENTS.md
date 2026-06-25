# Network Utils - Architecture & Development Guide

This document provides architectural guidelines and patterns for maintaining and extending the netutils repository.

## Repository Structure

Each utility script in this repository follows a **subdirectory-per-script** pattern for better organization and maintainability.

### Directory Layout

```
netutils/
├── README.md                    # Brief overview of each script (not detailed docs)
├── AGENTS.md                    # This file - architecture guide
├── LICENSE
├── .gitignore
│
├── cisco_ap_finder/             # Cisco AP Finder utility
│   ├── cisco_ap_finder.exs      # Main script
│   ├── README.md                # Detailed documentation for this script
│   ├── switches.txt             # Input data file
│   ├── output/                  # Output directory (generated, not tracked)
│   └── logs/                    # Log directory (generated, not tracked)
│
├── endpoint_finder/             # Endpoint Finder utility
│   ├── endpoint_finder.exs      # Main script
│   ├── README.md                # Detailed documentation for this script
│   ├── switches.txt             # Input data file
│   ├── output/                  # Output directory (generated, not tracked)
│   └── logs/                    # Log directory (generated, not tracked)
│
└── [future_script]/             # Future utility scripts follow same pattern
    ├── [future_script].exs      # Main script
    ├── README.md                # Detailed documentation for this script
    ├── devices.txt              # Input data file (canonical name for new scripts)
    ├── output/                  # Timestamped CSVs (generated, not tracked)
    └── logs/                    # Log directory (generated, not tracked)
```

## Architectural Principles

### 1. Subdirectory-Per-Script Organization

**Pattern:** Each utility script lives in its own subdirectory named after the script.

**Rationale:**
- **Isolation**: Each script's files are self-contained and don't clutter the root directory
- **Clarity**: Easy to see which files belong to which script
- **Scalability**: Repository can grow to include many utilities without becoming messy
- **Maintainability**: Updates to one script don't affect others

**Example:**
```
cisco_ap_finder/
├── cisco_ap_finder.exs    # The script itself
├── switches.txt           # Input configuration
├── output/                # CSV/log output (git-ignored)
└── logs/                  # Detailed per-switch logs (git-ignored)
```

### 2. File Organization Within Script Directories

Each script directory should contain:

- **Main script file**: Named identically to the directory (e.g., `cisco_ap_finder.exs`)
- **README.md**: Detailed documentation with description, features, prerequisites, setup, usage, example output, how it works, logging, and troubleshooting
- **Input file**: `devices.txt` — the canonical input filename for every script in this repo. One IP address or hostname per line; lines starting with `#` are comments. New scripts must default to reading `devices.txt`. (The two original scripts still ship a `switches.txt` sample for backwards compatibility, but new scripts should standardize on `devices.txt`.) See `endpoint_finder/switches.txt` for the expected line format.
- **Output CSV(s)**: Every script must write its CSV output to `output/<timestamp>-<name>.csv`, where `<timestamp>` is the run start time formatted as ISO-8601 with `:` and `.` replaced by `-` (e.g., `output/2026-04-14T10-30-45-qsfp_sfp_adapters.csv`). See `endpoint_finder/endpoint_finder.exs` (`run_time` / `file_timestamp` in `run/0` and the `write_*_csv` helpers) for the reference implementation. The `output/` directory is generated at runtime and excluded from git.
- **Logs directory**: `logs/<timestamp>/` — one log file per device, generated at runtime, excluded from git

### 3. Git Ignore Patterns

The root `.gitignore` uses global patterns to ignore all generated and working files:
```gitignore
*.csv
*.txt
logs/
```

**Important:** `*.txt` files (e.g., `switches.txt`) are intentionally ignored so that users' working device lists with real IPs/hostnames don't create git conflicts. Sample `switches.txt` files are committed once when a script is first added, then left ignored. Do **not** remove `*.txt` from `.gitignore` or add per-script negation patterns (`!script/switches.txt`) — this defeats the purpose.

To commit a new or updated `.txt` file despite the ignore rule, use `git add -f <path>`.

## Adding New Scripts

When adding a new network utility script to this repository, follow these steps:

### Step 1: Create Script Directory

```bash
mkdir [script_name]
cd [script_name]
```

### Step 2: Add Script and Configuration Files

```bash
# Create the main script
touch [script_name].exs
chmod +x [script_name].exs

# Create the canonical input file (every script in this repo reads devices.txt)
touch devices.txt
```

The script should read `devices.txt` by default (one IP address or hostname per line; lines starting with `#` are comments). Its CSV output must be written to `output/<timestamp>-<name>.csv` — see `endpoint_finder/endpoint_finder.exs` for the reference pattern (it computes a `file_timestamp` from `DateTime.utc_now/0` and prepends it to every CSV filename).

### Step 3: Commit Input Files

The root `.gitignore` globally ignores `*.csv`, `*.txt`, and `logs/`, so generated output is already covered. To commit a sample `devices.txt`, force-add it:
```bash
git add -f [script_name]/devices.txt
```

Do **not** add per-script negation patterns to `.gitignore` — the global `*.txt` ignore prevents users' working device lists from causing git conflicts.

### Step 4: Create Script-Specific Documentation

Create `[script_name]/README.md` with detailed documentation including: description, features, prerequisites, setup, usage, example output, how it works, logging, and troubleshooting. This is the primary documentation for the script.

### Step 5: Update Root README.md

Add a **brief** entry to the root `README.md`. The root README is an overview/index only — keep each script's entry to a short description paragraph and a usage command. Link to the script's own README for details:
```markdown
## [Script Name]

Brief description of what the script does.

```bash
cd [script_name]
elixir [script_name].exs
```

See [`[script_name]/README.md`]([script_name]/README.md) for detailed documentation.
```

**Do not** put detailed features, setup, examples, or troubleshooting in the root README.

## Development Guidelines

### Script Structure

All scripts should follow these conventions:

1. **Shebang line**: Include `#!/usr/bin/env elixir` for Elixir scripts
2. **Documentation**: Include module-level documentation explaining purpose
3. **Error handling**: Gracefully handle failures, provide helpful error messages
4. **Logging**: Create detailed logs for troubleshooting (see cisco_ap_finder example)
5. **Configuration**: Use external config files rather than hardcoding values

### SSH Connection Best Practices

For scripts that connect to Cisco network devices via SSH:

1. **Algorithm Support**: Include comprehensive cipher and key exchange support
   - Reference: `endpoint_finder/endpoint_finder.exs` `@desired_algorithms` and `algorithm_options/0`
   - List all desired algorithms (modern first, legacy last) in a module attribute
   - **Re-add legacy algorithms at runtime** — OTP 26+ removed SHA-1 key exchange from defaults but still supports it. Use `preferred_algorithms` for ordering algorithms already in defaults, and `modify_algorithms: [{:append, [...]}]` to re-enable legacy algorithms that OTP dropped. See `algorithm_options/0` in existing scripts.

2. **Algorithm Lists** (based on Cisco IOS-XE 17.9 specification):
   - **KEX**: curve25519-sha256@libssh.org, ECDH variants, DH groups
   - **Ciphers**: chacha20-poly1305@openssh.com, AES-GCM, AES-CTR, AES-CBC, 3DES
   - **MACs**: HMAC-SHA2 with ETM variants, SHA1/MD5 for legacy
   - **Public Keys**: rsa-sha2-512, rsa-sha2-256, ECDSA, ED25519, DSS

3. **Connection Options**:
   ```elixir
   opts = [
     {:user, username_charlist},
     {:password, password_charlist},
     {:silently_accept_hosts, true},
     {:user_interaction, false},
     {:connect_timeout, 10000},
     {:preferred_algorithms, [...]}
   ]
   ```

### Credential Handling

- **Never hardcode credentials** in scripts
- **Interactive input**: Prompt for username/password at runtime
- **Secure input**: Hide password input on Unix/Linux/macOS systems
- **Environment variables**: Support credential passing via env vars for automation

### Parallel Processing

For scripts that process multiple devices:

- Use Elixir's `Task.async_stream/3` for concurrent processing
- Set reasonable `max_concurrency` (default: 500 concurrent connections)
- Include timeout handling for slow devices
- Continue processing even if individual devices fail

## Testing Changes

Before committing changes:

1. **Test locally**: Run the script with real devices or test environment
2. **Verify outputs**: Check that generated files have correct format
3. **Review logs**: Ensure logging is detailed and helpful
4. **Check documentation**: Update README.md and inline documentation

## Git Workflow

### Branch Naming

Use descriptive branch names:
- `agent/add-[feature]-[session-id]` for new features
- `agent/fix-[issue]-[session-id]` for bug fixes

### Commit Messages

Write clear, descriptive commit messages:
```
[Summary line - what changed]

[Detailed explanation]
- Bullet points for specific changes
- Include rationale for changes
- Reference documentation sources

Fixes: [issue description]
```

### Pushing Changes

Always push to feature branches:
```bash
git push -u origin agent/[feature-name]-[session-id]
```

## References

### Cisco Documentation

- [Catalyst 9200 IOS-XE 17.9 SSH Algorithms](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst9200/software/release/17-9/configuration_guide/sec/b_179_sec_9200_cg/ssh_algorithms_for_common_criteria_certification.html)
- Cisco IOS-XE Security Configuration Guides (17.x series)

### Elixir Documentation

- [Elixir SSH Module](https://www.erlang.org/doc/man/ssh.html)
- [Task and Async Processing](https://hexdocs.pm/elixir/Task.html)

## Maintenance Notes

### When to Update This Guide

Update AGENTS.md when:
- Adding new architectural patterns or conventions
- Changing directory structure
- Establishing new best practices
- Learning from issues or improvements

### Version History

- 2026-01-24: Initial version - Documented subdirectory-per-script pattern and SSH best practices
