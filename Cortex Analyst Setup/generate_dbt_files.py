"""
DBT YML + MD File Generator
Reads the Landing_to_Raw_Mapping Excel sheet and generates one .yml and one .md
file per target table found in the '2. PROPERTIES. RAW' sheet.

Usage:
    python generate_dbt_files.py <excel_file> [--table TABLE_NAME] [--out-dir OUTPUT_DIR]
"""

import pandas as pd
import os
import re
import argparse
import json

# ── DWH standard columns ─────────────────────────────────────────────────────
DWH_COLS = {
    "DWH_SOURCE_SYSTEM_CODE": {
        "doc_key": "dwh_source_system_code",
        "tests": ["not_null"],
        "accepted_values_from_excel": True,
    },
    "DWH_LATEST_DML_TYPE_CODE": {
        "doc_key": "dwh_latest_dml_type_code",
        "tests": ["not_null"],
        "accepted_values": ["I", "U", "D", "X"],
    },
    "DWH_EXTRACTION_TSTAMP": {
        "doc_key": "dwh_extraction_tstamp",
        "tests": ["not_null"],
    },
    "DWH_EXTRACTION_ID": {
        "doc_key": "dwh_extraction_id",
        "tests": ["not_null"],
    },
    "DWH_PROCESS_INSERT_ID": {
        "doc_key": "dwh_process_insert_id",
        "tests": ["not_null"],
    },
    "DWH_PROCESS_TSTAMP": {
        "doc_key": "dwh_process_tstamp",
        "tests": ["not_null"],
    },
}

FIXED_TAGS = ["zone_properties", "dpg_reference", "layer_raw", "source_stats_nz", "frequency_yearly"]


def read_excel(path: str) -> pd.DataFrame:
    df = pd.read_excel(path, sheet_name="2. PROPERTIES. RAW", header=9)
    df = df[df["Table Name"].notna() & df["ID"].notna()]
    return df


def get_table_meta(df: pd.DataFrame, table_name: str) -> dict:
    """Return the header row (no attribute) plus all attribute rows for a table."""
    grp = df[df["Table Name"] == table_name].copy()
    header = grp[grp["Attribute Name"].isna()].iloc[0] if not grp[grp["Attribute Name"].isna()].empty else None
    attrs = grp[grp["Attribute Name"].notna()]
    return {"header": header, "attrs": attrs}


def safe_str(val) -> str:
    if pd.isna(val):
        return ""
    return str(val).strip()


def doc_prefix(schema: str, table: str) -> str:
    return f"raw___{schema.lower()}___{table.lower()}"


def model_name(schema: str, table: str) -> str:
    return f"raw___{schema.lower()}___{table.lower()}"


def parse_accepted_values(raw: str) -> list:
    """Parse JSON-ish accepted values string like [\"STATS_NZ_FILE\"] into a list."""
    raw = raw.strip()
    try:
        vals = json.loads(raw)
        if isinstance(vals, list):
            return [str(v) for v in vals]
    except Exception:
        pass
    # fallback: strip brackets & split
    raw = raw.strip("[]")
    return [v.strip().strip('"').strip("'") for v in raw.split(",") if v.strip()]


# ── YML generator ─────────────────────────────────────────────────────────────

def indent(text: str, spaces: int) -> str:
    pad = " " * spaces
    return "\n".join(pad + line if line.strip() else line for line in text.splitlines())


def build_yml(schema: str, table: str, attrs: pd.DataFrame) -> str:
    mname = model_name(schema, table)
    dprefix = doc_prefix(schema, table)
    tags_str = "[" + ", ".join(f"'{t}'" for t in FIXED_TAGS) + "]"

    lines = [
        "---",
        "version: 1",
        "models:",
        f"  - name: {mname}",
        "    config:",
        f"      tags: {tags_str}",
        f'    description: \'{{% doc("{dprefix}") %}}\'',
        "    tests:",
        "      - test_unique_columns:",
        "          columns : ['MESHBLOCK_CODE', 'DWH_EXTRACTION_TSTAMP']",
        "    columns:",
    ]

    for _, row in attrs.iterrows():
        attr = safe_str(row["Attribute Name"])
        if not attr:
            continue

        col_key = f"{dprefix}___{attr.lower()}"

        if attr in DWH_COLS:
            meta = DWH_COLS[attr]
            doc_key = meta["doc_key"]
            lines.append(f"      - name: {attr}")
            lines.append(f'        description: \'{{% doc("{doc_key}") %}}\'')
            tests = list(meta.get("tests", []))

            # Accepted values: prefer fixed list, else parse from excel
            if "accepted_values" in meta:
                av = meta["accepted_values"]
            elif meta.get("accepted_values_from_excel"):
                raw_av = safe_str(row.get("Accepted Values", ""))
                av = parse_accepted_values(raw_av) if raw_av else []
            else:
                av = []

            if tests or av:
                lines.append("        tests: ")
                for t in tests:
                    lines.append(f"          - {t}")
                if av:
                    vals_str = "[" + ", ".join(str(v) for v in av) + "]"
                    lines.append("          - accepted_values:")
                    lines.append(f"              values: {vals_str}")
        else:
            lines.append(f"      - name: {attr}")
            lines.append(f'        description: \'{{% doc("{col_key}") %}}\'')
            # not_null test for non-nullable columns that are not DWH
            if safe_str(row.get("Nullable", "Y")).upper() == "N":
                lines.append("        tests: ")
                lines.append("          - not_null")

    return "\n".join(lines) + "\n"


# ── MD generator ──────────────────────────────────────────────────────────────

def build_md(schema: str, table: str, title: str, attrs: pd.DataFrame) -> str:
    dprefix = doc_prefix(schema, table)
    table_title = title if title else table.replace("_", " ").title()
    table_lower = table.replace("_", " ").lower()

    # Table-level doc block (AI-generated placeholder)
    blocks = [
        f"{{% docs {dprefix} %}}",
        f"(AI‑Generated) This raw table contains the mapping of New Zealand meshblocks to {table_lower} classifications, "
        f"sourced from the Stats NZ Aria site Concordances file. "
        f"Renamed to {table} for ingestion.",
        "{% enddocs %}",
    ]

    for _, row in attrs.iterrows():
        attr = safe_str(row["Attribute Name"])
        if not attr or attr in DWH_COLS:
            continue

        desc = safe_str(row.get("Description", ""))
        if not desc:
            desc = attr.replace("_", " ").title()

        col_key = f"{dprefix}___{attr.lower()}"
        blocks.append(f"{{% docs {col_key} %}}")
        blocks.append(desc)
        blocks.append("{% enddocs %}")

    return "\n".join(blocks) + "\n"


# ── Main ──────────────────────────────────────────────────────────────────────

def generate(excel_path: str, target_table: str | None, out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    df = read_excel(excel_path)

    all_tables = df["Table Name"].dropna().unique().tolist()
    tables_to_process = [target_table] if target_table else all_tables

    generated = []
    for table in tables_to_process:
        if table not in all_tables:
            print(f"[WARN] Table '{table}' not found in sheet. Skipping.")
            continue

        meta = get_table_meta(df, table)
        attrs = meta["attrs"]
        header = meta["header"]

        schema = safe_str(header["Schema"]) if header is not None else "PROPERTIES_FILE"
        title = safe_str(header["Title"]) if header is not None else ""

        yml_content = build_yml(schema, table, attrs)
        md_content = build_md(schema, table, title, attrs)

        base_name = model_name(schema, table)
        yml_path = os.path.join(out_dir, f"{base_name}.yml")
        md_path = os.path.join(out_dir, f"{base_name}.md")

        with open(yml_path, "w", encoding="utf-8") as f:
            f.write(yml_content)
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(md_content)

        generated.append((table, yml_path, md_path))
        print(f"[OK] {table} → {os.path.basename(yml_path)}, {os.path.basename(md_path)}")

    print(f"\nDone. {len(generated)} table(s) processed → {out_dir}")
    return generated


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate dbt YML + MD files from Excel mapping sheet.")
    parser.add_argument("excel", help="Path to the Excel mapping file")
    parser.add_argument("--table", default=None, help="Generate files for a specific table only (default: all)")
    parser.add_argument("--out-dir", default="dbt_generated", help="Output directory (default: dbt_generated)")
    args = parser.parse_args()
    generate(args.excel, args.table, args.out_dir)
