# Plan

## What it does

1. **Load.** Every `.arxml` below the paths given, in parallel, into one flatxml document set.
   The schema each file declares (`xsi:schemaLocation`) is found in a schema directory the user
   gives, compiled once per release, and its annotations read into merge rules.
2. **Merge model.** One merged view over all files, by the schema's rules: per aggregation, its
   split key (the SHORT-NAME, a definition reference, a variation point; one or more paths of
   text below the child), whether children of one key from several files merge, whether its
   order matters (and so must come from one file), and its most children. What the rules forbid
   is reported with every file and line: one key from two files where the aggregation is not
   splittable, an ordered list in two files, too many children, two fragments whose values differ,
   an element of an unexpected kind.
3. **Paths and references.** Each identifiable element's AUTOSAR path, an index from path to
   merged element, and every reference (`*-REF` with `DEST`) resolved, or reported with its
   position when it does not resolve or names the wrong kind.
4. **Edits.** Set a value, add or remove an element, through the merged model; the change lands in
   the files that hold it (a value split across files changes in each, a new element goes to the
   file the caller names), and each changed file is written back with everything untouched kept
   byte for byte.
5. **Tools.** `diff` (two models, by path and content), `merge` (many files into one), `check`
   (merge problems and unresolved references), `get` and `list`.

## Steps

Each step needs the matching part of flatxml first (its `docs/documents.md`):

1. Load and merge model (flatxml document sets, rules, merged view): the merge problems and the
   element counts of real-world files.
   - **Done: load and rules.** `arxmodel load` reads every `.arxml` into one document set;
     `arxmodel rules` finds and compiles each declared schema once and reads its annotations into
     a rule per aggregation (key paths in XML, splittable, ordered, most), with every annotation
     counted (README, *Rules from the schema*). Locally: 697 real files (184 MB) load in about
     95 ms; four of the thirteen declared schemas are at hand, and each compiles and gives its
     rules in 0.1–0.4 s.
   - **Done: decisions.** A split key naming the item itself identifies an item with children by
     its single-valued children; the newest release declared governs, falling back to the newest
     at hand (README, *Releases*).
   - **Done: the merged view** (`arxmodel check`): the governing schema's rules as flatxml's
     (one per parent and child element name), the documents settling pairs that holders of
     different types give different rules, and every problem with its positions. What
     flatxml's rule model cannot say yet is listed as requests in the PR (rules scoped by the
     parent's type, a key of every occurrence, a key whose parts are all absent).
   - **Done: flatxml's rule extensions.** Each holder its own rule by a parent path (no conflict
     left in the local files: ECUC container definitions are keyed and merged under their
     module definition), keys of every occurrence (`+`) and the empty key for keyless items
     from flatxml; no key computed here. The known differences from the AUTOSAR specification
     are in the README.
   - **Done: rules files and policy.** The schema-derived rules as a generated file
     (`rules --emit`, `check --rules`, never committed), arxmodel's choices in a committed
     policy (`policy.toml`), the code left with the mechanics.
   - **Done: severity and validation.** Severities in the policy (error, warning, ignore;
     `check` fails on errors only); one `Finding` (layer, kind, severity, element path, every
     file:line) for the merge, the XML schema of each file ([TPS_GST_00423]) and the merged
     model's multiplicities ([constr_2502]; below the fewest its own kind).
   - **Done: references.** AUTOSAR paths for every referrable element (by the schema's
     classes) and an index from path to every merged node holding it (finding paths are
     AUTOSAR paths with merge keys below); every reference (a declaration whose type has a DEST
     attribute) resolved: `unresolved`, `external` (definitions not loaded; `--refs-from` loads
     them only to resolve against), `wrong_kind`, `case_mismatch`, `empty`, `relative` (BASE,
     not resolved), `duplicate_path`; `get`, `list`.
   - **Done: export** (`arxmodel merge -o model.arxml`): the merged view written as one ARXML by
     flatxml's writer (vendored at 57da97a, which sets the root's attributes as it writes), what was
     not merged into byte for byte, values that differ the first fragment's, the root's schema
     location for the model's namespace that of the release whose rules merged it;
     nothing written on errors unless `--force`. A parent's rules now follow its content model, and
     a child no role names gets a rule for its place, so the merged model is written in the
     schema's order (before this, children went in the order of the roles across the whole schema:
     173,610 elements out of place in the real model). Locally, the 697 files (184 MB, 1,853,442
     elements, 1,475 errors as `check` finds them: 324 of the merge and XML schema layers, 1,151
     unresolved or ambiguous references; so written with `--force`) write as one 171 MB ARXML in
     0.8–0.9 s (4.3–4.4 s with loading, merging and all four layers, 0.77 GB at most; by the rules
     file made from the schema, 1.5 s and 0.59 GB, the same bytes); read alone it is valid against
     AUTOSAR_00052 (no XML schema finding; the inputs' 2, an element out of 00052's order in a file
     declaring a later release, are in its order now), has nothing to merge, the same 110
     multiplicity warnings and the same 1,151 reference errors, and its 1,709,633 elements have,
     one for one and in order, the merged paths of the inputs' merged view.
   - **Done: the policy in TOML.** `policy.toml` (tables `[merge]`, `[schema]`, `[references]`,
     `[severity]`), read by vlib's `toml`; every setting required and typed, anything unknown
     refused by name.
   - **Next, in this order** (arxmodel is used in ordinary flows elsewhere too: merging .arxml
     files in CI and in git merges):
     1. *CI and git:*
        - (a) `arxmodel diff A B`: a semantic diff by AUTOSAR path on flatxml's diff with the
          AUTOSAR rules; file boundaries and the order of unordered roles are not changes.
        - (b) `arxmodel merge3 BASE OURS THEIRS [-o OUT]` on flatxml's merge3 with the AUTOSAR
          rules, conflicts reported by AUTOSAR path; on single files (git merges per file) and on
          sets of files.
        - (c) git integration: a merge driver and a diff driver (`.gitattributes`:
          `*.arxml merge=arxml diff=arxml`), set up by `arxmodel git-setup`.
        - (d) machine-readable output: JSON for check, diff and merge3; SARIF (code-scanning
          annotations); JUnit; stable exit codes.
        - (e) release binaries (Linux, Windows) on GitHub releases.
        - (f) the schema in CI: none needed. Built-in identity rules, hand-written conventions
          committed here (a SHORT-NAME names an element, ECUC values are named by their
          DEFINITION-REF, a list of named elements is one list, anything else by place), are the
          default for `diff`, `merge3` and the git drivers, so CI and git merges never need the
          AUTOSAR XSD. Locally the schema may be used: `ARXMODEL_SCHEMA_DIR` or `schema_dir` in
          the user's configuration, `--schema-dir` over both, `--no-schema` forcing the built-in
          rules; every command says which rules it read by. A user's own XSD, or a rules file
          generated in their infrastructure, is never shipped by us.
     2. *Verification of a complete model* (g): a `--profile complete` severity profile in
        policy.toml (a missing required role an error instead of a warning, and the like), and
        semantic checks (hand-written [constr_xxxx], ECUC first): values against their
        definitions (multiplicity, range, enumeration literal); shortName uniqueness ignoring
        case ([constr_2508]). All reported through the same `Finding` and CI outputs.
     3. *Editing by AUTOSAR path* (h), on flatxml's merged-view edits (each change lands in its
        source file, untouched bytes kept): `arxmodel set <path>#ELEM value`, `add` and `remove`
        (a new element goes to a named file or beside its siblings), `rename <path> <new>`
        rewriting every reference to it across all files, and edit scripts (a TOML or JSON list
        of operations) for CI. The model is checked after editing, and nothing is written if the
        edit introduces errors (unless `--force`).
     4. *ECU flat extract* (System Template, ECU flat view): from the merged, validated system
        model, the elements one ECU needs with their reference closure, the software
        composition flattened to one root composition with its connectors rerouted, and a
        FlatMap (FlatInstanceDescriptor) recording the original instance paths. Checked against
        the System Template before building (read locally, item ids only).
2. Paths and references.
3. `diff`, `merge`, `check` as commands.
4. Edits and writing back.
5. Used by blobly_net's ARXML import, which today reads one file through a reader of its own.

## End goal: blobly_net's ARXML import on the merged model

blobly_net's ARXML importer moves onto arxmodel's merged model: a system is scattered over many
files (network management in a file of its own, for one), which a one-file reader cannot see
whole. The steps come after the roadmap above, or between its steps as each becomes ready:

1. *A mode with no XSD.* A single file needs no merge rules; several files fall back to keying
   every element that has a SHORT-NAME by it, a general convention rather than one read from the
   schema.
2. *A communication extraction layer:* clusters, frames, PDUs, I-signals, compu methods, E2E and
   SecOC, senders and receivers, producing what blobly_net's candb needs, with blobly_net's
   existing extraction rules ported onto arxmodel's handles.
3. *A parity test* against blobly_net's current importer and cantools.
4. *arxmodel public* (the user confirms then).
5. *The switch:* blobly_net imports through arxmodel.

## Verification

- Synthetic schemas carrying the same kind of annotations, and synthetic split models, written
  here: one test per rule and per problem.
- Locally: the real-world files against the real schemas, numbers only. A model split into files
  and merged back equals the model.
