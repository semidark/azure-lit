#!/usr/bin/env python3
"""
Usage reporting CLI for AzureLIT.

Queries Log Analytics for per-key usage analytics.

Examples:
  # Daily summary
  python usage-report.py --date 2026-04-15

  # Date range
  python usage-report.py --from 2026-04-01 --to 2026-04-15

  # Per-model breakdown for a specific key
  python usage-report.py --date 2026-04-15 --group-by model --key-hash a3f7b2d9e4f1a9c2

  # Export to CSV
  python usage-report.py --from 2026-04-01 --to 2026-04-15 --format csv > usage.csv
"""

import argparse
import csv
import json
import os
import subprocess
import sys
from collections import defaultdict


def format_cost(value: float) -> str:
    """Render costs as fixed-point decimals instead of scientific notation."""
    if value >= 0.01:
        return f"${value:.4f}"
    if value >= 0.0001:
        return f"${value:.6f}"
    return f"${value:.8f}"


def _to_int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0


def _to_float(value) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _row_value(row, index: int, key: str):
    if isinstance(row, dict):
        return row.get(key)
    if isinstance(row, list) and len(row) > index:
        return row[index]
    return None


def resolve_workspace_id() -> str:
    """Discover the Log Analytics workspace ID via Azure CLI."""
    result = subprocess.run(
        [
            "az",
            "monitor",
            "log-analytics",
            "workspace",
            "show",
            "--workspace-name",
            "AzureLIT-POC-LA-2",
            "--resource-group",
            "AzureLIT-POC",
            "--query",
            "customerId",
            "--output",
            "tsv",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"az cli workspace lookup failed: {result.stderr.strip()}")
    workspace_id = result.stdout.strip()
    if not workspace_id:
        raise RuntimeError("az cli returned empty workspace ID")
    return workspace_id


def _run_query_via_az_cli(workspace_id: str, query: str):
    """Run KQL via Azure CLI as a dependency-light fallback."""
    result = subprocess.run(
        [
            "az",
            "monitor",
            "log-analytics",
            "query",
            "--workspace",
            workspace_id,
            "--analytics-query",
            query,
            "-o",
            "json",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Log Analytics query via az CLI failed: {result.stderr.strip()}"
        )

    payload = json.loads(result.stdout)

    # az can return either:
    # 1) {"tables": [{"columns": [...], "rows": [[...], ...]}]}
    # 2) [{"col_a": val, "col_b": val, ...}, ...]
    if isinstance(payload, dict):
        tables = payload.get("tables", [])
        if not tables:
            return []
        return tables[0].get("rows", [])

    if isinstance(payload, list):
        if not payload:
            return []

        first = payload[0]
        if isinstance(first, (list, dict)):
            return payload

    raise RuntimeError("Unexpected az monitor log-analytics query JSON format")


def run_log_analytics_query(workspace_id: str, query: str):
    """Run a KQL query against Log Analytics."""
    # Preferred path: direct REST query with Azure CLI token.
    # Fallback path: Azure CLI query command when Python deps are unavailable.
    if os.environ.get("AZURELIT_USAGE_REPORT_FORCE_AZCLI") == "1":
        return _run_query_via_az_cli(workspace_id, query)

    try:
        import requests
        from azure.identity import AzureCliCredential
    except ModuleNotFoundError:
        return _run_query_via_az_cli(workspace_id, query)

    url = f"https://api.loganalytics.io/v1/workspaces/{workspace_id}/query"

    headers = {"Accept": "application/json"}

    # Try Azure CLI auth first
    try:
        credential = AzureCliCredential()
        token = credential.get_token("https://api.loganalytics.io/.default")
        headers["Authorization"] = f"Bearer {token.token}"
    except Exception:
        # If token acquisition fails, fallback to az CLI query path.
        return _run_query_via_az_cli(workspace_id, query)

    response = requests.get(url, headers=headers, params={"query": query})
    if response.status_code != 200:
        # Keep CLI fallback to tolerate local Python env differences.
        return _run_query_via_az_cli(workspace_id, query)

    data = response.json()
    return data["tables"][0]["rows"]  # Assume single table result


def build_query(
    date_from: str,
    date_to: str = None,
    key_hash: str = None,
    group_by: str = "key",
    status: str = "all",
):
    """Build KQL query for usage data."""
    query = f"""
LiteLLMUsage_CL
| where TimeGenerated > ago(7d)
"""

    if date_from and date_to:
        query = f"""
LiteLLMUsage_CL
| where TimeGenerated between (datetime({date_from}T00:00:00Z) .. datetime({date_to}T23:59:59Z))
"""
    elif date_from:
        query = f"""
LiteLLMUsage_CL
| where TimeGenerated between (datetime({date_from}T00:00:00Z) .. datetime({date_from}T23:59:59Z))
"""

    query += """
| extend
    KeyHashNorm = tostring(coalesce(column_ifexists("KeyHash_s", ""), column_ifexists("KeyHash_s_s", ""))),
    ModelNorm = tostring(coalesce(column_ifexists("Model_s", ""), column_ifexists("Model_s_s", ""))),
    StatusNorm = tostring(coalesce(column_ifexists("Status_s", ""), column_ifexists("Status_s_s", ""))),
    TokensInNorm = todouble(coalesce(column_ifexists("TokensIn_d", real(null)), column_ifexists("TokensIn_i_d", real(null)), 0.0)),
    TokensOutNorm = todouble(coalesce(column_ifexists("TokensOut_d", real(null)), column_ifexists("TokensOut_i_d", real(null)), 0.0)),
    CostNorm = todouble(coalesce(column_ifexists("Cost_d", real(null)), column_ifexists("Cost_d_d", real(null)), 0.0))
"""

    if status in ("success", "failure"):
        query += f"| where StatusNorm == '{status}'\n"

    if key_hash:
        query += f"| where KeyHashNorm == '{key_hash}'\n"

    if group_by == "model":
        query += """
| summarize
    Requests = count(),
    TokensIn = sum(TokensInNorm),
    TokensOut = sum(TokensOutNorm),
    Cost = sum(CostNorm)
    by ModelNorm
| order by Requests desc
"""
    else:
        query += """
| summarize
    Requests = count(),
    Failures = countif(StatusNorm == "failure"),
    TokensIn = sum(TokensInNorm),
    TokensOut = sum(TokensOutNorm),
    Cost = sum(CostNorm),
    Models = make_set(ModelNorm)
    by KeyHashNorm
| order by Requests desc
"""

    return query


def format_table(data, headers):
    """Simple table formatter."""
    if not data:
        return "No data found."

    widths = [len(h) for h in headers]
    for row in data:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))

    lines = []
    separator = "+".join("-" * (w + 2) for w in widths)
    lines.append(f"+{separator}+")

    header_row = "|".join(f" {headers[i]:{widths[i]}} " for i in range(len(headers)))
    lines.append(f"|{header_row}|")
    lines.append(f"+{separator}+")

    for row in data:
        row_str = "|".join(f" {str(row[i]):{widths[i]}} " for i in range(len(row)))
        lines.append(f"|{row_str}|")

    lines.append(f"+{separator}+")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="AzureLIT Usage Report")
    parser.add_argument("--workspace-id", help="Log Analytics workspace ID")
    parser.add_argument("--date", help="Single date (YYYY-MM-DD)")
    parser.add_argument("--from", dest="date_from", help="Start date (YYYY-MM-DD)")
    parser.add_argument("--to", help="End date (YYYY-MM-DD)")
    parser.add_argument("--key-hash", help="Filter to specific key")
    parser.add_argument(
        "--group-by", choices=["key", "model"], default="key", help="Aggregation level"
    )
    parser.add_argument(
        "--status",
        choices=["all", "success", "failure"],
        default="all",
        help="Filter by request status before aggregation",
    )
    parser.add_argument("--format", choices=["table", "csv", "json"], default="table")

    args = parser.parse_args()

    workspace_id = args.workspace_id or os.environ.get("LOG_ANALYTICS_WORKSPACE_ID")
    if not workspace_id:
        try:
            workspace_id = resolve_workspace_id()
        except RuntimeError as e:
            print(
                f"Error: could not resolve workspace ID automatically: {e}",
                file=sys.stderr,
            )
            print(
                "Set --workspace-id or LOG_ANALYTICS_WORKSPACE_ID to override.",
                file=sys.stderr,
            )
            sys.exit(1)

    # Determine date range
    date_from = args.date_from or args.date
    date_to = args.to

    # Build and run query
    query = build_query(date_from, date_to, args.key_hash, args.group_by, args.status)
    print(f"Running query:\n{query}\n", file=sys.stderr)

    try:
        rows = run_log_analytics_query(workspace_id, query)
    except Exception as e:
        print(f"Error running query: {e}", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print("No usage data found for the specified period.")
        return

    # Parse results (Log Analytics returns rows as lists)
    # Column order follows summarize projection in build_query().

    if args.group_by == "model":
        headers = ["Model", "Requests", "Tokens In", "Tokens Out", "Cost"]
        # Group by model
        stats = defaultdict(
            lambda: {"requests": 0, "tokens_in": 0, "tokens_out": 0, "cost": 0.0}
        )
        for row in rows:
            model = _row_value(row, 0, "ModelNorm") or "unknown"
            stats[model]["requests"] += _to_int(_row_value(row, 1, "Requests"))
            stats[model]["tokens_in"] += _to_int(_row_value(row, 2, "TokensIn"))
            stats[model]["tokens_out"] += _to_int(_row_value(row, 3, "TokensOut"))
            stats[model]["cost"] += _to_float(_row_value(row, 4, "Cost"))

        data = [
            [k, v["requests"], v["tokens_in"], v["tokens_out"], format_cost(v["cost"])]
            for k, v in sorted(
                stats.items(), key=lambda x: x[1]["requests"], reverse=True
            )
        ]
    else:
        headers = [
            "Key Hash",
            "Requests",
            "Failures",
            "Tokens In",
            "Tokens Out",
            "Cost",
            "Models",
        ]
        # Group by key
        stats = defaultdict(
            lambda: {
                "requests": 0,
                "failures": 0,
                "tokens_in": 0,
                "tokens_out": 0,
                "cost": 0.0,
                "models": set(),
            }
        )
        for row in rows:
            key = _row_value(row, 0, "KeyHashNorm") or "unknown"
            stats[key]["requests"] += _to_int(_row_value(row, 1, "Requests"))
            stats[key]["failures"] += _to_int(_row_value(row, 2, "Failures"))
            stats[key]["tokens_in"] += _to_int(_row_value(row, 3, "TokensIn"))
            stats[key]["tokens_out"] += _to_int(_row_value(row, 4, "TokensOut"))
            stats[key]["cost"] += _to_float(_row_value(row, 5, "Cost"))
            models_value = _row_value(row, 6, "Models")
            if models_value:
                if isinstance(models_value, list):
                    for model in models_value:
                        if model:
                            stats[key]["models"].add(str(model))
                elif isinstance(models_value, str):
                    parsed = None
                    try:
                        parsed = json.loads(models_value)
                    except Exception:
                        parsed = None

                    if isinstance(parsed, list):
                        for model in parsed:
                            if model:
                                stats[key]["models"].add(str(model))
                    elif models_value.strip():
                        stats[key]["models"].add(models_value.strip())

        data = [
            [
                k[:16] + "...",
                v["requests"],
                v["failures"],
                v["tokens_in"],
                v["tokens_out"],
                format_cost(v["cost"]),
                ", ".join(sorted(v["models"])),
            ]
            for k, v in sorted(
                stats.items(), key=lambda x: x[1]["requests"], reverse=True
            )
        ]

    # Output
    if args.format == "csv":
        writer = csv.writer(sys.stdout)
        writer.writerow(headers)
        writer.writerows(data)
    elif args.format == "json":
        print(json.dumps([dict(zip(headers, row)) for row in data], indent=2))
    else:
        print(f"\nUsage Report: {date_from or 'last 7 days'} to {date_to or 'now'}")
        if args.status != "all":
            print(f"Status Filter: {args.status}")
        print(f"Result Groups: {len(rows)}")
        print()
        print(format_table(data, headers))


if __name__ == "__main__":
    main()
