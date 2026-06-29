# MAC Address Differ

A lightweight Elixir utility script to compare two MAC address lists (from CSV files), normalize all MAC inputs across various standard formats, difference the sets, and export the unique MAC addresses found in each list to a formatted CSV file.

## Features

- **Flexible Input Formats**: Automatically handles MAC addresses formatted with colons (`00:11:22:33:44:55`), hyphens (`00-11-22-33-44-55`), periods (`0011.2233.4455`), or raw hex strings (`001122334455`).
- **Case-Insensitive Normalization**: Accepts upper, lower, or mixed-case hex values and normalizes them into standard Cisco dot notation (`aabb.ccdd.eeff`).
- **Set Differencing**: Performs fast set difference comparisons to identify MACs present in List 1 but not List 2, and vice-versa.
- **Timestamped Export**: Outputs comparison results into an organized CSV in the `output/` directory formatted as `output/<timestamp>-mac_differ.csv`.
- **Comments and Clean Up**: Gracefully ignores blank lines, comments (lines starting with `#`), and CSV headers.

## Prerequisites

- **Elixir**: Version 1.12 or later recommended.

## Setup

No compilation or external dependencies required. Simply clone the repository and navigate to the `mac_differ` directory:

```bash
cd mac_differ
```

## Usage

### Default Execution

Place your MAC lists in `list1.csv` and `list2.csv` within the `mac_differ` directory, then run:

```bash
elixir mac_differ.exs
```

### Specifying Custom Files

You can pass custom CSV filenames directly as command-line arguments:

```bash
elixir mac_differ.exs custom_list1.csv custom_list2.csv
```

Alternatively, running `elixir mac_differ.exs` without arguments will prompt you to enter filenames interactively (pressing Enter selects the defaults `list1.csv` and `list2.csv`).

## Input Format

Each input CSV file should contain one MAC address per line. Header lines, empty lines, and comments starting with `#` are automatically skipped.

Example `list1.csv`:
```csv
# Production Switch MACs
00:11:22:33:44:55
aabb.ccdd.ee01
AA-BB-CC-DD-EE-02
```

Example `list2.csv`:
```csv
# Inventory MACs
0011.2233.4455
AABBCCDDEE01
11:22:33:44:55:66
```

## Output Format

The script writes results to `output/<timestamp>-mac_differ.csv` with two columns: `list1-uniques` and `list2-uniques`.

Example Output CSV (`output/2026-06-29T13-45-00-mac_differ.csv`):
```csv
list1-uniques,list2-uniques
aabb.ccdd.ee02,1122.3344.5566
0011.2233.4466,aabb.ccdd.ee03
```

## How It Works

1. **Extraction & Sanitization**: Strips quotation marks and non-hexadecimal characters from each line.
2. **Normalization**: Validates that 12 hex digits exist and formats them into standard Cisco 4-digit dot segments (`aabb.ccdd.eeff`).
3. **Set Differencing**: Constructs Elixir `MapSet` collections and calculates `MapSet.difference/2` in both directions.
4. **CSV Export**: Writes sorted results side-by-side into a timestamped CSV file.
