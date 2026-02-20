# MongoDB Atlas Alert Automation

Automates creation of MongoDB Atlas alerts from an Excel configuration file using the Atlas CLI.

## Prerequisites

- Python 3.8+
- MongoDB Atlas CLI (`brew install mongodb-atlas-cli`)
- Atlas API Key with **Project Owner** role

## Quick Start

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Authenticate Atlas CLI
atlas auth login

# 3. Run the script
./run_alerts.sh --project-id YOUR_PROJECT_ID
```

---

## Script Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SCRIPT EXECUTION FLOW                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. PARSE ARGS                                                              │
│     └── --project-id, --dry-run, --excel-file, etc.                        │
│                                                                             │
│  2. CHECK ATLAS CLI                                                         │
│     └── Is `atlas` installed? Is it authenticated?                         │
│                                                                             │
│  3. READ EXCEL FILE                                                         │
│     └── atlas_alert_configurations.xlsx                                     │
│         └── Extract: name, low_threshold, high_threshold                   │
│                                                                             │
│  4. FOR EACH ALERT:                                                         │
│     │                                                                       │
│     ├── Look up in ALERT_MAPPINGS                                          │
│     │   └── Get: event_type, metric_name, units                            │
│     │                                                                       │
│     ├── Parse threshold string                                              │
│     │   └── "> 75% for 5 minutes" → {operator: GT, threshold: 75, dur: 5}  │
│     │                                                                       │
│     ├── Create alert config JSON                                            │
│     │   └── {eventTypeName, metricThreshold, notifications, ...}           │
│     │                                                                       │
│     └── Write to alerts/XX_alert_name.json                                 │
│                                                                             │
│  5. FOR EACH JSON FILE:                                                     │
│     │                                                                       │
│     └── Run: atlas alerts settings create --file X.json --projectId Y      │
│         │                                                                   │
│         ├── SUCCESS → Track alert ID in .automation_alert_ids.json         │
│         └── FAILURE → Log error, continue to next                          │
│                                                                             │
│  6. PRINT SUMMARY                                                           │
│     └── Total: 33, Success: 33, Failed: 0                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## How `create_atlas_alerts.py` Works

### Overview

The script reads alert definitions from an Excel file and creates them in MongoDB Atlas via the CLI. It generates JSON configuration files in the `alerts/` folder before deploying them.

### Step-by-Step Breakdown

#### Step 1: Parse Command Line Arguments (Lines 808-870)

```python
parser.add_argument("--project-id", required=True)
parser.add_argument("--dry-run", action="store_true")
parser.add_argument("--excel-file", default="atlas_alert_configurations.xlsx")
parser.add_argument("--delete-existing", action="store_true")
```

| Argument | Description |
|----------|-------------|
| `--project-id` | MongoDB Atlas Project ID (required) |
| `--dry-run` | Generate JSON files only, don't create alerts |
| `--excel-file` | Path to Excel config file |
| `--delete-existing` | Delete previously created alerts |
| `--delete-all` | Delete ALL alerts (including defaults) |

#### Step 2: Check Atlas CLI (Lines 549-585)

```python
def check_atlas_cli(logger):
    # Check if atlas CLI is installed
    subprocess.run(["atlas", "--version"])
    
    # Check if authenticated
    subprocess.run(["atlas", "config", "list"])
```

Verifies:
- Atlas CLI is installed
- CLI is authenticated (has valid credentials)

#### Step 3: Read Excel File (Lines 398-426)

```python
def read_excel_file(excel_path, logger):
    wb = openpyxl.load_workbook(excel_path)
    sheet = wb.active
    
    for row in sheet.iter_rows(min_row=2, values_only=True):
        alert = {
            "name": row[0],           # e.g., "System: CPU (User) %"
            "category": row[1],       # e.g., "Host"
            "low_threshold": row[2],  # e.g., "> 75% for 5 minutes"
            "high_threshold": row[3], # e.g., "> 95% for 5 minutes"
        }
```

Reads each row from the Excel file and extracts:
- Alert name (must match a key in `ALERT_MAPPINGS`)
- Low priority threshold
- High priority threshold

#### Step 4: Look Up Alert Mapping (Lines 42-149)

```python
ALERT_MAPPINGS = {
    "System: CPU (User) %": {
        "event_type": "OUTSIDE_METRIC_THRESHOLD",
        "metric_name": "NORMALIZED_SYSTEM_CPU_USER",
        "units": "RAW",
    },
    "Host is Down": {
        "event_type": "HOST_DOWN",
        "metric_name": None,
        "uses_threshold": True,
    },
    # ... 18 more alert types
}
```

This dictionary maps human-readable alert names to Atlas API parameters:
- `event_type` → The Atlas `eventTypeName`
- `metric_name` → For metric-based alerts
- `units` → BYTES, MILLISECONDS, SECONDS, HOURS, or RAW
- `uses_threshold` → For event-based alerts with thresholds

#### Step 5: Parse Threshold String (Lines 181-299)

```python
def parse_threshold(threshold_str):
    # Input: "> 75% for 5 minutes"
    # Output: {
    #     "operator": "GREATER_THAN",
    #     "threshold": 75,
    #     "units": "RAW",
    #     "duration_minutes": 5
    # }
```

Parses various threshold formats:

| Input | Parsed Output |
|-------|---------------|
| `> 4000 for 2 minutes` | `{operator: GT, threshold: 4000, duration: 2}` |
| `< 24h for 5 minutes` | `{operator: LT, threshold: 86400s, duration: 5}` |
| `> 50ms for 5 minutes` | `{operator: GT, threshold: 50, units: MS, duration: 5}` |
| `> 2GB for 15 minutes` | `{operator: GT, threshold: 2147483648, units: BYTES}` |
| `Any occurrence` | `{is_event: true}` |

#### Step 6: Create Alert Config JSON (Lines 302-395)

```python
def create_alert_config(alert_name, threshold_info, priority, mapping, ...):
    config = {
        "eventTypeName": mapping["event_type"],
        "enabled": True,
        "notifications": [{
            "typeName": "GROUP",
            "intervalMin": 60,
            "delayMin": threshold_info["duration_minutes"],
            "emailEnabled": True,
            "roles": ["GROUP_OWNER"],
        }],
    }
    
    # For metric-based alerts
    if mapping.get("metric_name"):
        config["metricThreshold"] = {
            "metricName": mapping["metric_name"],
            "operator": threshold_info["operator"],
            "threshold": threshold_info["threshold"],
        }
```

Builds the JSON structure that Atlas API expects.

#### Step 7: Write JSON Files to `alerts/` Folder (Lines 429-546)

```python
def generate_json_files(alerts, output_dir, ...):
    # Clean up old JSON files
    for f in output_dir.glob("*.json"):
        f.unlink()
    
    # Generate new JSON files
    for alert in alerts:
        filename = f"{index:02d}_{alert_name}_low.json"
        filepath = output_dir / filename
        
        with open(filepath, "w") as f:
            json.dump(config, f, indent=2)
```

**Yes, it creates JSON files in `alerts/` folder:**
- `01_oplog_window_low.json`
- `02_oplog_window_high.json`
- `03_disk_read_iops_on_data_partition_low.json`
- etc.

#### Step 8: Create Alerts via Atlas CLI (Lines 588-659)

```python
def create_alerts(generated_files, project_id, dry_run, ...):
    for file_info in generated_files:
        result = subprocess.run([
            "atlas", "alerts", "settings", "create",
            "--file", str(filepath),
            "--projectId", project_id,
            "--output", "json",
        ])
        
        if result.returncode == 0:
            # Extract alert ID from response
            response = json.loads(result.stdout)
            alert_id = response.get("id")
            created_alert_ids.append(alert_id)
```

For each JSON file:
1. Runs `atlas alerts settings create --file X.json`
2. Captures the alert ID from the response
3. Tracks successful alert IDs in `.automation_alert_ids.json`

#### Step 9: Track Alert IDs (Lines 676-696)

```python
def save_tracked_alerts(script_dir, project_id, alert_ids):
    # Save to .automation_alert_ids.json
    data[project_id] = list(existing.union(alert_ids))
    with open(tracking_file, "w") as f:
        json.dump(data, f, indent=2)
```

Stores created alert IDs so they can be deleted later with `--delete-existing`.

---

## Directory Structure

```
atlas-alerts-creation/
├── create_atlas_alerts.py          # Main Python script
├── run_alerts.sh                   # Bash wrapper script
├── atlas_alert_configurations.xlsx # Excel config (your thresholds)
├── requirements.txt                # Python dependencies
├── .env.local                      # Local credentials (gitignored)
├── .automation_alert_ids.json      # Tracks created alert IDs (gitignored)
├── alerts/                         # Generated JSON files (gitignored)
│   ├── 01_oplog_window_low.json
│   ├── 02_oplog_window_high.json
│   └── ...
└── logs/                           # Execution logs (gitignored)
```

---

## Usage Examples

```bash
# Basic usage
./run_alerts.sh --project-id YOUR_PROJECT_ID

# Dry run (generate JSON only, don't create alerts)
./run_alerts.sh --project-id YOUR_PROJECT_ID --dry-run

# With custom notification email
./run_alerts.sh --project-id YOUR_PROJECT_ID --notification-email alerts@company.com

# Delete automation-created alerts only
./run_alerts.sh --project-id YOUR_PROJECT_ID --delete-existing

# Delete ALL alerts (including defaults)
./run_alerts.sh --project-id YOUR_PROJECT_ID --delete-all
```

---

## Alert Notification Timing

The `delayMin` parameter controls when you receive an email:

| Threshold | delayMin | Meaning |
|-----------|----------|---------|
| `> 75% for 5 minutes` | 5 | Email sent after condition persists 5 min |
| `> 95% for 0 minutes` | 0 | Email sent immediately |
| `Any occurrence` | 0 | Email sent immediately |

**Important:** If the condition resolves before `delayMin`, no email is sent.

---

## Adding New Alert Types

1. Add entry to `ALERT_MAPPINGS` in `create_atlas_alerts.py`:

```python
"Your Alert Name": {
    "event_type": "OUTSIDE_METRIC_THRESHOLD",
    "metric_name": "YOUR_METRIC_NAME",
    "units": "RAW",
}
```

2. Add row to `atlas_alert_configurations.xlsx` with matching alert name

3. Run: `./run_alerts.sh --project-id YOUR_PROJECT_ID`

---

## Reference

- [Atlas CLI Documentation](https://www.mongodb.com/docs/atlas/cli/current/)
- [Alert Conditions Reference](https://www.mongodb.com/docs/atlas/reference/alert-conditions/)
- [Recommended Alert Configurations](https://www.mongodb.com/docs/atlas/architecture/current/monitoring-alerts/)
