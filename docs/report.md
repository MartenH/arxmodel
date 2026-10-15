# Reports

`arxmodel check --format FORMAT` writes what the check found to standard output, and what it read
(files loaded, the governing schema) to standard error. `text` is the default and the format
people read; the others are for machines:

| format  | what |
|---------|------|
| `json`  | arxmodel's own report, below; every finding, every severity |
| `sarif` | SARIF 2.1.0, for code-scanning tools |
| `junit` | JUnit XML, for CI test reports |

The three are written from one `Report` (`arxmodel/report.v`), so a command that finds things
fills a Report and gets all three.

## Exit codes

`check` (and `merge`, which checks before it writes):

| code | meaning |
|------|---------|
| 0 | nothing the policy calls an error |
| 1 | errors found: a finding the policy calls an error, a file that could not be read or declares no schema, a model no schema governs, a rules file made for other documents |
| 2 | the command could not run: usage, a rules or policy file that cannot be read or is not one |

Warnings and ignored findings never change the exit code. With `--format`, a run that exits 1 still
writes its report; one that exits 2 writes none. (`diff` and `merge3` exit 1 for a difference and a
conflict; 2 is the same for every command.)

## JSON

Schema: [report.schema.json](report.schema.json) (JSON Schema draft-07). `version` is the format's
version, now 1: a field removed or changed in meaning raises it; a field added does not, so a
reader ignores fields it does not know.

```json
{
  "version": 1,
  "tool": {"name": "arxmodel", "version": "0.1.0"},
  "command": "check",
  "governing": "AUTOSAR_00052.xsd",
  "summary": {
    "files": 2, "loaded": 2, "elements": 19, "nodes": 12, "merged": 7,
    "layers": ["merge", "xml_schema", "multiplicity", "reference"],
    "errors": 2, "warnings": 0, "ignored": 0, "inputs": 0, "took_ms": 2.6
  },
  "inputs": [
    {"kind": "not_read", "file": "m/bad.arxml", "line": 2, "column": 49,
     "message": "m/bad.arxml:2:49: end tag ..."}
  ],
  "findings": [
    {
      "layer": "merge", "kind": "value_differs", "rule": "merge.value_differs",
      "severity": "error", "what": "SHORT-NAME", "in_conflict": false,
      "path": "/Fiction#SHORT-NAME", "message": "SHORT-NAME differs",
      "locations": [
        {"file": "m/x.arxml", "line": 6, "column": 7},
        {"file": "m/y.arxml", "line": 6, "column": 7}
      ]
    }
  ]
}
```

- `governing`: the schema whose rules merged the model (with `--rules`, the one the rules file
  was made from).
- `summary.files` is the files found, `loaded` those read; `elements` are in the files read,
  `nodes` the merged model's, `merged` the nodes made of more than one element; `layers` the
  layers that ran; `inputs` counts the entries of `inputs`; `took_ms` the time the layers took.
- `inputs`: what kept files from being checked, each making the run fail: `not_read` (a file
  did not parse, or a directory could not be read; `line` and `column` where the parser
  stopped, 0 where it does not say), `undeclared` (a file declares no schema) and `ungoverned`
  (no schema governs the model: no namespace, or several, or none of the declared schemas at
  hand; `file` is the model's first file, and nothing else is checked, so `findings` is empty).
- All text is UTF-8: a file name or message with bytes that are not is written with U+FFFD in
  their place.
- `findings`: in the order check finds them. `rule` is `layer.kind`; `severity` is the policy's
  (`error`, `warning`, `ignore`); `what` the element or `@attribute` concerned, where the kind has
  one; `in_conflict` marks a merge finding on an element pair whose holders the rules cannot tell
  apart; `path` the element's AUTOSAR path, with merge keys below it; `locations` every place in
  the files the finding involves, line and column from 1 (0 where not known).

## SARIF

One run; the driver lists one rule per `layer.kind` found, plus `input.not_read`,
`input.undeclared` and `input.ungoverned` where there are such problems. One result per finding of severity error
(`level: error`) or warning (`level: warning`) and one per file not checked (`error`); ignored
findings are left out. Each result has a physical location per place in the files (relative
paths as given, absolute ones as `file:` URIs, a UNC path as `file://host/share/...`), the file
it concerns where it names no place (a model-level finding: the model's first file), and the
element's path as its logical location.
Checked against the OASIS schema in CI (`scripts/check_reports.sh`).

## JUnit

One test suite, `arxmodel.check`. One test case per `layer.kind` found and per kind of file not
checked, named so, failing (one `<failure>`, every finding in its text) where any is an error,
its warnings as `<system-out>`; one passing test case per layer that ran and found nothing.
Ignored findings are left out. Checked against the Jenkins xunit plugin's `junit-10.xsd` in CI.
