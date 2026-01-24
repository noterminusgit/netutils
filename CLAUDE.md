# Network Utils - Architecture & Development Guide

This document provides architectural guidelines and patterns for maintaining and extending the netutils repository.

## Repository Structure

Each utility script in this repository follows a **subdirectory-per-script** pattern for better organization and maintainability.

### Directory Layout

```
netutils/
├── README.md                    # Main repository documentation
├── CLAUDE.md                    # This file - architecture guide
├── LICENSE
├── .gitignore
│
├── cisco_ap_finder/             # Cisco AP Finder utility
│   ├── cisco_ap_finder.exs      # Main script
│   ├── switches.txt             # Input data file
│   ├── aps.csv                  # Output file (generated, not tracked)
│   └── logs/                    # Log directory (generated, not tracked)
│
└── [future_script]/             # Future utility scripts follow same pattern
    ├── [future_script].exs      # Main script
    ├── [config/input files]     # Script-specific files
    └── [output directories]     # Generated files (not tracked)
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
└── logs/                  # Output (git-ignored)
```

### 2. File Organization Within Script Directories

Each script directory should contain:

- **Main script file**: Named identically to the directory (e.g., `cisco_ap_finder.exs`)
- **Input files**: Configuration files, data files, or templates (e.g., `switches.txt`)
- **Documentation**: Optional README.md for complex scripts with detailed usage
- **Output directories**: Generated at runtime, excluded from git (e.g., `logs/`, `*.csv`)

### 3. Git Ignore Patterns

Generated files should be ignored:
```gitignore
# Generated output files
*.csv
logs/
output/
```

Add script-specific patterns to `.gitignore` as needed.

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

# Add any configuration or input files
touch config.txt  # or other relevant files
```

### Step 3: Update .gitignore

Add any generated output patterns to the root `.gitignore`:
```gitignore
# [Script Name] generated files
[script_name]/*.csv
[script_name]/logs/
[script_name]/output/
```

### Step 4: Update Root README.md

Add a section to the main README.md documenting the new script:
```markdown
## [Script Name]

Brief description of what the script does.

### Usage

```bash
cd [script_name]
./[script_name].exs
```

See `[script_name]/README.md` for detailed documentation.
```

### Step 5: Create Script-Specific Documentation (Optional)

For complex scripts, create `[script_name]/README.md` with detailed usage, examples, and troubleshooting.

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
   - Reference: `cisco_ap_finder/cisco_ap_finder.exs:177-237`
   - Support both modern (IOS-XE 17.9+) and legacy algorithms
   - Order algorithms by security preference (modern first, legacy last)

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
- Set reasonable `max_concurrency` (default: 10 concurrent connections)
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
- `claude/add-[feature]-[session-id]` for new features
- `claude/fix-[issue]-[session-id]` for bug fixes

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
git push -u origin claude/[feature-name]-[session-id]
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

Update CLAUDE.md when:
- Adding new architectural patterns or conventions
- Changing directory structure
- Establishing new best practices
- Learning from issues or improvements

### Version History

- 2026-01-24: Initial version - Documented subdirectory-per-script pattern and SSH best practices
