from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from hashlib import sha256
from html import escape
from pathlib import Path


FOLDER_NAMES = ["recovery_3", "recovery_4", "recovery_5", "recovery_6", "recovery_7"]
DISPLAY_NAMES = {
    "recovery_3": "first recovery",
    "recovery_4": "second recovery",
    "recovery_5": "live_files",
    "recovery_6": "third recovery",
    "recovery_7": "fourth recovery",
}
OUTPUT_FILE_NAME = "recovery_folder_diff_report.html"


@dataclass(frozen=True)
class FileEntry:
    name: str
    size: int
    digest: str


def display_name(folder_name: str) -> str:
    return DISPLAY_NAMES[folder_name]


def hash_file(path: Path) -> str:
    hasher = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def load_folder(folder: Path) -> list[FileEntry]:
    return sorted(
        (
            FileEntry(
                name=path.name,
                size=path.stat().st_size,
                digest=hash_file(path),
            )
            for path in folder.iterdir()
            if path.is_file()
        ),
        key=lambda entry: entry.name.lower(),
    )


def build_casefold_index(folder_files: dict[str, list[FileEntry]]) -> dict[str, dict[str, list[FileEntry]]]:
    index: dict[str, dict[str, list[FileEntry]]] = {}
    for folder_name, entries in folder_files.items():
        variants: dict[str, list[FileEntry]] = {}
        for entry in entries:
            variants.setdefault(entry.name.lower(), []).append(entry)
        index[folder_name] = variants
    return index


def build_hash_index(folder_files: dict[str, list[FileEntry]]) -> dict[str, dict[str, FileEntry]]:
    index: dict[str, dict[str, FileEntry]] = {}
    for folder_name, entries in folder_files.items():
        digest_map: dict[str, FileEntry] = {}
        for entry in entries:
            digest_map.setdefault(entry.digest, entry)
        index[folder_name] = digest_map
    return index


def normalized_display_name(normalized_name: str, index: dict[str, dict[str, list[FileEntry]]]) -> str:
    for folder_name in FOLDER_NAMES:
        variants = index[folder_name].get(normalized_name)
        if variants:
            return sorted(variant.name for variant in variants)[0]
    return normalized_name


def format_size(size: int) -> str:
    value = float(size)
    for unit in ["B", "KB", "MB", "GB"]:
        if value < 1024 or unit == "GB":
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def presence_cell(variants: list[FileEntry] | None, shared_count: int) -> str:
    if variants:
        symbol = "&#10003;"
        label = "Present"
        state = "present"
        variant_text = "<br>".join(
            f"{escape(entry.name)} <span class=\"dim\">({escape(format_size(entry.size))})</span>"
            for entry in sorted(variants, key=lambda entry: entry.name)
        )
    else:
        symbol = "&#10007;"
        label = "Missing"
        state = "missing"
        variant_text = ""

    if shared_count == 1:
        relation = "unique"
    elif shared_count == len(FOLDER_NAMES):
        relation = "shared-all"
    else:
        relation = "shared-some"

    details = f'<div class="variant">{variant_text}</div>' if variant_text else ""
    return (
        f'<td class="{state} {relation}" aria-label="{label}">'
        f'<span class="mark">{symbol}</span>{details}</td>'
    )


def summary_rows(folder_files: dict[str, list[FileEntry]], index: dict[str, dict[str, list[FileEntry]]]) -> str:
    normalized_sets = {name: set(variants) for name, variants in index.items()}
    union = set().union(*normalized_sets.values())
    shared_all = set.intersection(*(normalized_sets[name] for name in FOLDER_NAMES))

    rows = [
        ("Total files on disk", [str(len(folder_files[name])) for name in FOLDER_NAMES]),
        ("Unique normalized names", [str(len(normalized_sets[name])) for name in FOLDER_NAMES]),
        (
            "Names unique to this folder",
            [
                str(
                    len(
                        normalized_sets[name]
                        - set().union(*(normalized_sets[other] for other in FOLDER_NAMES if other != name))
                    )
                )
                for name in FOLDER_NAMES
            ],
        ),
        (
            "Names shared with at least one other folder",
            [
                str(
                    len(
                        normalized_sets[name]
                        & set().union(*(normalized_sets[other] for other in FOLDER_NAMES if other != name))
                    )
                )
                for name in FOLDER_NAMES
            ],
        ),
        (
            f"Names shared across all {len(FOLDER_NAMES)} folders",
            [str(len(shared_all)) for _ in FOLDER_NAMES],
        ),
    ]

    body = []
    for label, values in rows:
        cells = "".join(f"<td>{value}</td>" for value in values)
        body.append(f"<tr><th>{escape(label)}</th>{cells}</tr>")

    body.append(
        "<tr>"
        f'<th colspan="{len(FOLDER_NAMES) + 1}">Case-insensitive view: there are {len(union)} distinct normalized filenames in total across all {len(FOLDER_NAMES)} folders.</th>'
        "</tr>"
    )
    return "\n".join(body)


def extension_rows(folder_files: dict[str, list[FileEntry]]) -> str:
    rows = []
    for name in FOLDER_NAMES:
        counts = Counter((Path(entry.name).suffix.lower() or "[no extension]") for entry in folder_files[name])
        top = ", ".join(f"{ext}: {count}" for ext, count in counts.most_common())
        rows.append(f"<tr><th>{escape(display_name(name))}</th><td>{escape(top)}</td></tr>")
    return "\n".join(rows)


def first_recovery_gap_rows(
    folder_files: dict[str, list[FileEntry]],
    casefold_index: dict[str, dict[str, list[FileEntry]]],
    hash_index: dict[str, dict[str, FileEntry]],
) -> str:
    first_entries = {entry.name.lower(): entry for entry in folder_files["recovery_3"]}
    live_names = set(casefold_index["recovery_5"])
    candidate_names = sorted(set(first_entries) - live_names)
    later_folders = [name for name in FOLDER_NAMES if name != "recovery_3"]

    rows = []
    for normalized_name in candidate_names:
        entry = first_entries[normalized_name]
        matches = []
        unresolved = True
        for folder_name in later_folders:
            match = hash_index[folder_name].get(entry.digest)
            if match:
                unresolved = False
                matches.append(
                    f'<div class="match found">{escape(display_name(folder_name))}: {escape(match.name)}</div>'
                )
            else:
                matches.append(
                    f'<div class="match missing">{escape(display_name(folder_name))}: no content match</div>'
                )
        row_class = "unresolved" if unresolved else "resolved"
        rows.append(
            "<tr>"
            f'<td class="filename {row_class}">'
            f"<div>{escape(entry.name)}</div>"
            f'<div class="normalized">size: {escape(format_size(entry.size))}</div>'
            "</td>"
            f'<td class="{row_class}">{"".join(matches)}</td>'
            "</tr>"
        )
    return "".join(rows)


def compare_bytes(earlier_file: Path, later_file: Path) -> str:
    earlier_bytes = earlier_file.read_bytes()
    later_bytes = later_file.read_bytes()
    if earlier_bytes == later_bytes:
        return "exact"
    if earlier_bytes.startswith(later_bytes):
        return "later is byte prefix of earlier"
    if later_bytes.startswith(earlier_bytes):
        return "later extends earlier"
    return "different payload"


def drift_rows(
    folder_files: dict[str, list[FileEntry]],
    earlier_folder: str,
    later_folder: str,
) -> tuple[str, str, str]:
    earlier_entries = {entry.name: entry for entry in folder_files[earlier_folder]}
    later_entries = {entry.name: entry for entry in folder_files[later_folder]}
    common_names = sorted(set(earlier_entries) & set(later_entries))

    changed_rows = []
    unchanged_count = 0
    prefix_count = 0

    base = Path.home() / "Downloads"
    for file_name in common_names:
        earlier_entry = earlier_entries[file_name]
        later_entry = later_entries[file_name]
        if earlier_entry.digest == later_entry.digest:
            unchanged_count += 1
            continue

        relation = compare_bytes(base / earlier_folder / file_name, base / later_folder / file_name)
        if relation == "later is byte prefix of earlier":
            prefix_count += 1
        changed_rows.append(
            "<tr>"
            f"<td class=\"filename\"><div>{escape(file_name)}</div></td>"
            f"<td>{escape(format_size(earlier_entry.size))}</td>"
            f"<td>{escape(format_size(later_entry.size))}</td>"
            f"<td>{escape(relation)}</td>"
            "</tr>"
        )

    removed_names = sorted(set(earlier_entries) - set(later_entries))
    added_names = sorted(set(later_entries) - set(earlier_entries))

    earlier_display = display_name(earlier_folder)
    later_display = display_name(later_folder)
    summary = (
        f"There are {len(common_names)} exact filename overlaps between the {earlier_display} and {later_display} runs. "
        f"{unchanged_count} are byte-identical, {len(changed_rows)} changed content under the same name, "
        f"{len(removed_names)} names disappeared, and {len(added_names)} new names appeared. "
        f"{prefix_count} of the changed files are exact byte prefixes of the earlier run's outputs."
    )

    extras = []
    if removed_names:
        extras.append(
            f"<p><strong>Only in {escape(earlier_display)}:</strong> "
            + ", ".join(f"<code>{escape(name)}</code>" for name in removed_names)
            + "</p>"
        )
    if added_names:
        extras.append(
            f"<p><strong>Only in {escape(later_display)}:</strong> "
            + ", ".join(f"<code>{escape(name)}</code>" for name in added_names)
            + "</p>"
        )

    return summary, "".join(extras), "".join(changed_rows)


def payload_relationship_rows(
    folder_files: dict[str, list[FileEntry]],
    reference_folder: str,
    candidate_folder: str,
) -> tuple[str, str]:
    base = Path.home() / "Downloads"
    reference_files = {entry.name: base / reference_folder / entry.name for entry in folder_files[reference_folder]}
    candidate_files = {entry.name: base / candidate_folder / entry.name for entry in folder_files[candidate_folder]}
    reference_bytes = {name: path.read_bytes() for name, path in reference_files.items()}

    rows = []
    exact_count = 0
    prefix_count = 0
    unmatched_count = 0

    for candidate_name, candidate_path in candidate_files.items():
        candidate_payload = candidate_path.read_bytes()
        exact_matches = [name for name, payload in reference_bytes.items() if payload == candidate_payload]
        prefix_matches = [
            name
            for name, payload in reference_bytes.items()
            if payload.startswith(candidate_payload) and payload != candidate_payload
        ]

        if exact_matches:
            relation = "exact payload match"
            counterpart_names = exact_matches
            row_class = "resolved"
            exact_count += 1
        elif prefix_matches:
            relation = f"byte prefix of {display_name(reference_folder)} payload"
            counterpart_names = prefix_matches
            row_class = "resolved"
            prefix_count += 1
        else:
            relation = f"no exact or prefix match in {display_name(reference_folder)}"
            counterpart_names = []
            row_class = "unresolved"
            unmatched_count += 1

        counterpart_text = ", ".join(f"<code>{escape(name)}</code>" for name in counterpart_names) if counterpart_names else "none"
        rows.append(
            "<tr>"
            f'<td class="filename {row_class}"><div>{escape(candidate_name)}</div><div class="normalized">size: {escape(format_size(candidate_path.stat().st_size))}</div></td>'
            f'<td class="{row_class}">{escape(relation)}</td>'
            f'<td class="{row_class}">{counterpart_text}</td>'
            "</tr>"
        )

    reference_display = display_name(reference_folder)
    candidate_display = display_name(candidate_folder)
    summary = (
        f"Across the {len(candidate_files)} {candidate_display} files, {exact_count} are exact payload matches to {reference_display} files, "
        f"{prefix_count} are strict byte prefixes of {reference_display} payloads, and {unmatched_count} have no exact or prefix match in the {reference_display} set."
    )
    return summary, "".join(rows)


def matrix_rows(index: dict[str, dict[str, list[FileEntry]]]) -> str:
    all_normalized = sorted(set().union(*(set(index[name]) for name in FOLDER_NAMES)))
    rows = []
    for normalized_name in all_normalized:
        shared_count = sum(normalized_name in index[name] for name in FOLDER_NAMES)
        row_class = "row-unique" if shared_count == 1 else "row-shared"
        canonical_name = normalized_display_name(normalized_name, index)
        variant_summary = []
        for folder_name in FOLDER_NAMES:
            variants = index[folder_name].get(normalized_name)
            if variants:
                variant_summary.extend(sorted(entry.name for entry in variants))
        variant_summary = sorted(dict.fromkeys(variant_summary))
        variants_text = ", ".join(variant_summary)

        cells = "".join(presence_cell(index[folder_name].get(normalized_name), shared_count) for folder_name in FOLDER_NAMES)
        rows.append(
            "<tr>"
            f'<td class="filename {row_class}">'
            f"<div>{escape(canonical_name)}</div>"
            f'<div class="normalized">normalized: {escape(normalized_name)}</div>'
            f'<div class="normalized">variants: {escape(variants_text)}</div>'
            "</td>"
            f"{cells}"
            "</tr>"
        )
    return "".join(rows)


def build_html(folder_files: dict[str, list[FileEntry]]) -> str:
    casefold_index = build_casefold_index(folder_files)
    hash_index = build_hash_index(folder_files)
    generated_from = "\n".join(
        f"<li><code>{escape(str(Path.home() / 'Downloads' / name))}</code> &rarr; {escape(display_name(name))}</li>"
        for name in FOLDER_NAMES
    )
    second_to_third_summary, second_to_third_extras, second_to_third_table = drift_rows(
        folder_files,
        "recovery_4",
        "recovery_6",
    )
    third_to_fourth_summary, third_to_fourth_extras, third_to_fourth_table = drift_rows(
        folder_files,
        "recovery_6",
        "recovery_7",
    )
    fourth_to_second_summary, fourth_to_second_table = payload_relationship_rows(
        folder_files,
        "recovery_4",
        "recovery_7",
    )

    headers = "".join(f"<th>{escape(display_name(folder_name))}</th>" for folder_name in FOLDER_NAMES)

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Recovery Folder Differences</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f5f0e7;
      --panel: #fffdf9;
      --line: #d8cfc2;
      --text: #211c16;
      --muted: #6d6257;
      --head: #ede2cf;
      --present: #173f2f;
      --missing: #7e2d2d;
      --unique-bg: #fde9c9;
      --shared-some-bg: #e6f4ea;
      --shared-all-bg: #d4eadc;
      --missing-bg: #f7e3e3;
      --resolved-bg: #e7f4ea;
      --unresolved-bg: #fce4d6;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(198, 171, 128, 0.20), transparent 30%),
        linear-gradient(180deg, #fcfaf6 0%, var(--bg) 100%);
    }}
    main {{
      max-width: 1520px;
      margin: 0 auto;
      padding: 40px 24px 56px;
    }}
    h1, h2 {{ margin: 0 0 12px; }}
    p {{ margin: 0 0 14px; color: var(--muted); }}
    .card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 20px;
      box-shadow: 0 12px 30px rgba(47, 39, 28, 0.06);
      margin-bottom: 20px;
    }}
    ul {{ margin: 0; padding-left: 20px; }}
    table {{
      width: 100%;
      border-collapse: collapse;
      background: white;
    }}
    th, td {{
      border: 1px solid var(--line);
      padding: 10px 12px;
      text-align: center;
      vertical-align: top;
    }}
    th {{
      background: var(--head);
      font-weight: 600;
    }}
    td.filename, th.filename {{
      text-align: left;
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      word-break: break-word;
      min-width: 320px;
    }}
    .normalized, .dim {{
      color: var(--muted);
      font-size: 12px;
      margin-top: 4px;
    }}
    td.present, td.missing {{
      min-width: 180px;
      font-weight: 700;
    }}
    td.present.unique {{ background: var(--unique-bg); color: var(--present); }}
    td.present.shared-some {{ background: var(--shared-some-bg); color: var(--present); }}
    td.present.shared-all {{ background: var(--shared-all-bg); color: var(--present); }}
    td.missing {{ background: var(--missing-bg); color: var(--missing); }}
    td.resolved {{ background: var(--resolved-bg); }}
    td.unresolved, td.filename.unresolved {{ background: var(--unresolved-bg); }}
    .match {{
      margin-bottom: 6px;
      padding: 6px 8px;
      border-radius: 8px;
      text-align: left;
      font-weight: 500;
    }}
    .match.found {{ background: var(--resolved-bg); color: var(--present); }}
    .match.missing {{ background: var(--missing-bg); color: var(--missing); }}
    .mark {{
      display: block;
      font-size: 18px;
      line-height: 1;
      margin-bottom: 8px;
    }}
    .variant {{
      font-size: 12px;
      font-weight: 500;
      line-height: 1.35;
    }}
    .legend {{
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 12px;
    }}
    .legend span {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: #fff;
    }}
    .swatch {{
      width: 12px;
      height: 12px;
      border-radius: 999px;
      display: inline-block;
    }}
    .table-wrap {{
      overflow: auto;
      max-height: 70vh;
      border: 1px solid var(--line);
      border-radius: 14px;
    }}
    .note {{
      font-size: 13px;
    }}
    code {{
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      background: rgba(83, 66, 37, 0.08);
      padding: 2px 6px;
      border-radius: 6px;
    }}
  </style>
</head>
<body>
  <main>
    <section class="card">
      <h1>Recovery Folder Differences</h1>
      <p>This report compares filenames case-insensitively across five folders. A row represents one normalized filename, so names like <code>PIC00804.jpg</code> and <code>PIC00804.JPG</code> are treated as the same file entry.</p>
      <ul>
        {generated_from}
      </ul>
      <div class="legend">
        <span><i class="swatch" style="background: var(--unique-bg);"></i>Present and unique to one folder</span>
        <span><i class="swatch" style="background: var(--shared-some-bg);"></i>Present and shared with some folders</span>
        <span><i class="swatch" style="background: var(--shared-all-bg);"></i>Present in all folders</span>
        <span><i class="swatch" style="background: var(--missing-bg);"></i>Missing from this folder</span>
      </div>
    </section>

    <section class="card">
      <h2>Summary</h2>
      <table>
        <thead>
          <tr>
            <th></th>
            {headers}
          </tr>
        </thead>
        <tbody>
          {summary_rows(folder_files, casefold_index)}
        </tbody>
      </table>
    </section>

    <section class="card">
      <h2>Extension Breakdown</h2>
      <table>
        <thead>
          <tr><th>Folder</th><th>Files by extension</th></tr>
        </thead>
        <tbody>
          {extension_rows(folder_files)}
        </tbody>
      </table>
    </section>

    <section class="card">
      <h2>First Recovery Names Not In Live Files</h2>
      <p class="note">These are the case-insensitive filename gaps between the original <code>main</code> recovery and the live backup. The second column checks whether the same content hash appears in the later runs or the live set. Orange rows are still unresolved everywhere else by content.</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="filename">First recovery file</th>
              <th>Content match in later sets</th>
            </tr>
          </thead>
          <tbody>
            {first_recovery_gap_rows(folder_files, casefold_index, hash_index)}
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>Second Recovery vs Third Recovery Drift</h2>
      <p class="note">{escape(second_to_third_summary)}</p>
      {second_to_third_extras}
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="filename">Exact filename present in both runs</th>
              <th>Second recovery size</th>
              <th>Third recovery size</th>
              <th>Relationship</th>
            </tr>
          </thead>
          <tbody>
            {second_to_third_table}
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>Third Recovery vs Fourth Recovery Drift</h2>
      <p class="note">{escape(third_to_fourth_summary)}</p>
      {third_to_fourth_extras}
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="filename">Exact filename present in both runs</th>
              <th>Third recovery size</th>
              <th>Fourth recovery size</th>
              <th>Relationship</th>
            </tr>
          </thead>
          <tbody>
            {third_to_fourth_table}
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>Fourth Recovery Payload Relationship To Second Recovery</h2>
      <p class="note">{escape(fourth_to_second_summary)}</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="filename">Fourth recovery file</th>
              <th>Relationship to second recovery</th>
              <th>Matching second recovery file(s)</th>
            </tr>
          </thead>
          <tbody>
            {fourth_to_second_table}
          </tbody>
        </table>
      </div>
    </section>

    <section class="card">
      <h2>Case-Insensitive Filename Matrix</h2>
      <p class="note">Each row shows the normalized lowercase name plus the exact filename variants found in the folders. Cell background color shows whether a present file is unique or shared.</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="filename">Normalized file entry</th>
              {headers}
            </tr>
          </thead>
          <tbody>
            {matrix_rows(casefold_index)}
          </tbody>
        </table>
      </div>
    </section>
  </main>
</body>
</html>
"""


def main() -> None:
    base = Path.home() / "Downloads"
    folder_files = {}
    for folder_name in FOLDER_NAMES:
        folder = base / folder_name
        if not folder.is_dir():
            raise SystemExit(f"Missing folder: {folder}")
        folder_files[folder_name] = load_folder(folder)

    output = Path.cwd() / OUTPUT_FILE_NAME
    output.write_text(build_html(folder_files), encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
