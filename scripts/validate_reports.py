#!/usr/bin/env python3
"""Validate arxmodel's reports against their schemas.

usage: validate_reports.py --json REPORT.json --sarif REPORT.sarif SARIF_SCHEMA.json
                           --junit REPORT.xml JUNIT.xsd

The JSON report is checked against docs/report.schema.json (arxmodel's own). The SARIF schema
(OASIS sarif-schema-2.1.0.json) and the JUnit XSD are fetched by the caller, never committed.
Needs the jsonschema and lxml packages.
"""
import argparse
import json
import pathlib
import sys

import jsonschema
from lxml import etree

HERE = pathlib.Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--json', action='append', default=[])
    ap.add_argument('--sarif', nargs=2, action='append', default=[], metavar=('REPORT', 'SCHEMA'))
    ap.add_argument('--junit', nargs=2, action='append', default=[], metavar=('REPORT', 'XSD'))
    a = ap.parse_args()
    ours = json.loads((HERE / 'docs' / 'report.schema.json').read_text())
    bad = 0
    for path in a.json:
        bad += check_json(path, ours)
    for path, schema in a.sarif:
        bad += check_json(path, json.loads(pathlib.Path(schema).read_text()))
    for path, xsd in a.junit:
        s = etree.XMLSchema(etree.parse(xsd))
        if s.validate(etree.parse(path)):
            print(f'{path}: valid')
        else:
            bad += 1
            for e in s.error_log:
                print(f'{path}:{e.line}: {e.message}')
    sys.exit(1 if bad else 0)


def check_json(path, schema):
    doc = json.loads(pathlib.Path(path).read_text(encoding='utf-8'))
    cls = jsonschema.validators.validator_for(schema)
    cls.check_schema(schema)
    v = cls(schema, format_checker=cls.FORMAT_CHECKER)
    errs = sorted(v.iter_errors(doc), key=lambda e: list(e.path))
    for e in errs:
        print(f'{path}: {"/".join(map(str, e.path))}: {e.message}')
    if not errs:
        print(f'{path}: valid')
    return 1 if errs else 0


if __name__ == '__main__':
    main()
