# arxmodel

Loads AUTOSAR models (ARXML) the way AUTOSAR tools see them: many files, one model. Elements
split across files are merged by the AUTOSAR merge model, edits go back to the files they came
from, and every element and value points back to its file and line.

Built on [flatxml](https://github.com/MartenH/flatxml), which parses, shares names across files,
and gives a merged view over many documents by rules its caller supplies. arxmodel supplies the
AUTOSAR rules.

## No AUTOSAR material here

No AUTOSAR schema (XSD), no ARXML file and no table generated from either is committed: not as
code, not as test data, not in a comment. The merge rules (split keys, which aggregations may be
split, which are ordered, how many children each allows) are read at load time from the AUTOSAR
schema the user has, the one the files declare. Tests use synthetic schemas and documents
written here. Runs against real schemas and files happen locally, and record numbers only.

See [docs/plan.md](docs/plan.md).

## Three layers

A merge is made of three things, kept apart:

1. **Rules derived from the schema** (split keys, splittable, ordered, most, XML shape): read from
   the AUTOSAR XSD the files declare, on the user's machine. `arxmodel rules --emit FILE` writes
   them as flatxml rule text (`*.rules.txt`, ignored by git), and `check --rules FILE` merges by
   that file instead of compiling the schema. Such a file is derived from the AUTOSAR schema, so it
   is **never committed**.
2. **Policy** ([policy.toml](policy.toml), committed): every choice that is arxmodel's and not the
   schema's, in TOML. The default follows the AUTOSAR specification (Generic Structure Template
   R24-11); [automat.policy.toml](automat.policy.toml) is automat's behaviour (`--policy
   automat`), and `--policy FILE` reads one's own. Each setting has a comment saying why and the
   specification item it concerns: `[merge]` absent keys, the case of keys, attributes that may
   differ, items and primitive values named by their role alone, non-splittable repetitions,
   items of several types, ECUC values by definition, repeated-choice content, structured
   comments; `[schema]` which release governs, splittability; `[references]` the package element;
   `[severity]` each finding's severity. Every setting must be given, with a value of its type
   this build supports; an unknown table, key or value is refused by name.
   [policy.schema.json](policy.schema.json) is its JSON Schema (draft-07, generated from the code's
   one list of settings by `arxmodel policy --schema`; a test holds the committed file to it), which
   editors read through the files' first line, `#:schema ./policy.schema.json` (Taplo, Even Better
   TOML). `arxmodel policy` prints every setting with the values it takes, its value and its
   specification item; `arxmodel policy --diff automat` how two policies differ. Command-line flags
   (`--case-sensitive`, `--check-attr`, `--ignore-attr`) override it.
3. **Mechanics** (the code): reading annotations, resolving keys, scoping rules by parent path,
   merging on flatxml's view. It holds no choice of its own.

## Use

```sh
arxmodel load <file|dir>...                        # every .arxml below the paths, one set
arxmodel rules --schema-dir DIR <file|dir>...      # and the merge rules of the schemas they declare
arxmodel rules --schema-dir DIR --problems --dump rules.tsv <file|dir>...
arxmodel rules --schema-dir DIR --emit autosar.rules.txt <file|dir>...           # the merge rules, as a file
arxmodel check --schema-dir DIR [--all] [--ignore-attr NAME]... <file|dir>...   # merge, and what the rules forbid
arxmodel check --rules autosar.rules.txt <file|dir>...                         # the same, by the rules file
arxmodel check --schema-dir DIR --format sarif <file|dir>... > check.sarif      # or json, junit: for machines
arxmodel get --schema-dir DIR /Pkg/Name <file|dir>...      # the merged element at an AUTOSAR path
arxmodel list --schema-dir DIR ECUC-MODULE-DEF <file|dir>... # the paths of every element of a name
arxmodel merge --schema-dir DIR [--force] -o model.arxml <file|dir>...          # the merged model, as one ARXML
arxmodel diff A B                                   # what changed, by AUTOSAR path (no schema needed)
arxmodel merge3 BASE OURS THEIRS -o OUT             # a three-way merge (no schema needed)
arxmodel git-setup [REPO]                           # git's merge and diff drivers for *.arxml
```

A rules file starts with a header giving its format's version (`# format:`; a file of another
format, or one made before the line existed, is refused: make it again), naming the schema it came from (name, namespace, path and
SHA-256), the arxmodel and flatxml versions, the policy settings the rules were made by
(`absent_keys`, `item_itself`, `governing`, `splittable`, `repeated_choice_as_mixed`), every pair
in conflict with the rules that disagree, then the merge settings (`!fold`, `!ignore` with the
policy's attribute names, and `# ignore-declarations`), then one rule a line in the order the merge
uses them. Nothing in it depends on the documents it was made from: the same schema and policy give
the same file from any of them, and two releases' files diff line by line. When merging from a
file, its settings are the merge's (the flags still override; the documents' own declaration
attributes are added then), and its conflicts are placed against the documents being checked, so
the output and the exit code are those of `--schema-dir` on them. `check --rules` refuses a file
for another namespace or another schema family than the documents declare, and warns when they
declare a newer release than the file was made from, and for every policy setting that differs
from the file's (the file's applies). The rule lines are written by flatxml's own `format_rules`, so `flatxml merge --rules` reads the
file and merges as arxmodel does; it then also compares `xsi:schemaLocation` between fragments,
since the documents' declaration attributes are added only by arxmodel (`ignore_declarations`).

`load` reads every file whose name ends in `.arxml` (any case) below the paths, in parallel, into
one flatxml document set with namespaces resolved, and lists the files that fail to parse and
the directories that cannot be read. A file reached by two paths (a directory and a file in it,
two spellings of one directory) is read once.

`rules` also reads the schema each file declares (`xsi:schemaLocation`, the location paired with
the root element's namespace), finds it in the schema directory (`DIR/<name>`, then
`DIR/<stem>/<name>`, then anywhere below `DIR`; a name differing only in case is accepted and
said), compiles each distinct schema once, in parallel, and prints per schema: the aggregations,
how many have a split key, are splittable or ordered, how many key paths resolved, and an account
of every annotation. `--problems` lists each annotation that could not be applied; `--dump` writes
the rules as tab-separated lines (`--dump -` to standard output, the summary then going to
standard error). Both commands exit 1 when a file could not be read, or a schema
was not declared, not found or did not compile; what could be done is still printed.

## Rules from the schema

An AUTOSAR schema describes each meta-class as an `xsd:group` and each role of the class as a
local element declaration in it, annotated with `xsd:appinfo` blocks: `source="tags"` holds
`key="value"` pairs separated by `;`, `source="stereotypes"` a comma-separated list. flatxml keeps
every appinfo with its owner; arxmodel reads them into one `Rule` per role (`arxmodel/rules.v`):

| annotation | on | rule |
|---|---|---|
| `mmt.qualifiedName="Class.role"` | element declaration | a role: `class`, `role`; its XML element is the declaration's name |
| `mmt.qualifiedName="Class"` (no role) | element declaration | the reference inside a conditional wrapper, named by the class it refers to: the role is the class name with a lower-case first letter |
| `atp.Splitkey="a, b.c"` | role | the split key, one path per part, resolved to XML (below) |
| stereotype `atpSplitable` | role | `splittable`: items with one key from several files are one item |
| `pureMM.isOrdered="true"` | role | `ordered`: the order of the items means something |
| `pureMM.maxOccurs`, `pureMM.minOccurs` | role | `max` (`-1` is no most), `min` |
| `xml.roleWrapperElement` | role | compared with the shape the schema gives the role |

**Shape.** A role element whose type is anonymous and holds only elements that are not roles
themselves *wraps* its items (`SHELVES` holding `SHELF` elements): the rule's `items` are those
elements, one per item kind, each with its type. An element of no role whose anonymous type holds
exactly one role element also wraps it (the role's tags then sit on the inner element). A role
declared `xml.roleWrapperElement="true"`, `xml.roleElement="false"`, `xml.typeElement="false"`
wraps its items' content with no element per item (`flat`). Otherwise the role element is itself
the item.

**Where a rule applies.** Every complex type's content model is walked through its sequences,
choices and the groups it references; each role element found there is held by that type. So a
class's roles apply to every type that includes its group, inheritance included, and
`rule_for(type, child element)` finds the rule for an element's child. `types_of` gives the
types an XML element name is declared with.

**Split keys.** Each part of `atp.Splitkey` is a path of meta-model roles. A leading part equal
to the role's own name is dropped; the role's name alone is the item itself. Each further role is found by its role name among the
roles of the type reached so far, and becomes that role's XML element: `shortName` becomes
`SHORT-NAME`, `variationPoint.shortLabel` becomes `VARIATION-POINT/SHORT-LABEL`. A role realised
as an XML attribute becomes `@NAME`. A role holding several values may end a path (its values in
order are the value, written `*`); one holding several items may not be passed through. A role
spelled with another case is matched and reported. Keys resolve per item kind, since several
kinds can sit in one aggregation. What cannot be resolved is reported with the part and the type
it was looked for in.

**The item itself as key.** A value (text, a reference) is its own key. An item with children is
identified by its single-valued element children (attributes do not count), in the order its type
writes them: each child role holding one value as text: not a wrapper, at most one by its rule
(which mixed content may raise), not splittable, its type simple or mixed. A role behind an
element of no role of its own is reached through that element. A child whose class has the
stereotype `instanceRef` (a reference to an instance, by context and target) counts by its own
such children, below it; other object children do not count. When the whole key comes out empty,
a single-valued role's fragments are the one item (a note, naming the type); for a multi-valued
role every item gets one key, which is reported.

**Counts.** `max` is the meta-model's. Where a class's content repeats its roles (mixed content:
text between the elements, or a content model that is a repeated choice of the roles), each
occurrence is one more element, so the XML schema's count is used, and the case counted;
occurrence counts are multiplied down the class's content model. The repetition of a wrapper's
anonymous type belongs to the wrapper's role, not to the roles inside it. Where `pureMM.maxOccurs`
is missing, a wrapper's most is the number of items its content model can hold (a sequence's
parts add up, a choice takes its largest alternative, both repeat). `min` is the meta-model's;
the XML schema makes most roles optional within a file.

**Every annotation is accounted for** (`Census`), by what the reader did with it: applied to a
rule (`used`), compared with the schema's structure (`checked`), a tag of a kind the reader uses
found where it does not read it (`not read`, by owner: a class name on a group or type, counts on
an attribute or on an element that is no role, tags on an attribute reference inside an attribute
group), every other tag, stereotype and appinfo source (`other`, counted per name as the user's
schema has it), and tag text that is not `key="value"` (`malformed`). The code names only the
annotations it applies; nothing is classified by a list of the schema's vocabulary, and nothing is
dropped without being counted.

## Releases

The files of one model may declare different releases of the schema. The **newest release the
files declare governs** the merged model: one rule set, by which files of older releases are
merged too. A release is read from the schema's file name, `<prefix>_<release>[_<qualifier>].xsd`:
the first part after the prefix that is one number (`_00049`) or numbers joined by `-` (`_4-2-2`);
a qualifier after it (`_STRICT`) does not change the rank, and case does not matter. Releases
rank only within one family (one prefix). Dotted releases order number by number
(`4-2-2 < 4-3-0 < 4-6-0`), and any numbered release is newer than any dotted one
(`4-6-0 < 00044 < 00046`). Where one namespace has several families, the one most documents
declare is ranked and the others are reported. A name with no release cannot be ordered and is
said; it governs only when it is the one schema that compiled. One release under two spellings
is one release: one that compiled stands for it.

When the newest declared schema is not in the schema directory, or does not compile, the newest
one that does governs, and `rules` says so. Against the governing schema it reports, per older
schema at hand, the roles that have no rule in it (`--problems` lists them), and the element names
the documents use that it does not declare, with counts, files and the first position.

## Checking (`check`)

`check` merges every file into one model by the rules of the governing schema, on flatxml's
merged view (`flatxml/merge.v`), and checks it in four layers, each finding with one shape
(`Finding`: layer, kind, severity, element path, every file:line it involves). The element path
is an AUTOSAR path: the SHORT-NAMEs of the referrable elements above it (`/Pkg/Sub/Name`; a
variation point is not referrable and adds nothing), then `#` and the elements below the nearest
referrable one, each with its merge key where it has one
(`/Pkg/C#PARAMETER-VALUES/ECUC-NUMERICAL-PARAM-VALUE[<key>]/DEFINITION-REF`), or `#` and the
elements from the root where none is referrable. An element is referrable when its type, in the
governing schema, is a kind of the class whose own content declares SHORT-NAME (a class being a
named model group the type's content uses); merging from a rules file, with no schema, when it
has a SHORT-NAME. Every referrable element is indexed by its path, compared ignoring ASCII case
when the merge compares keys so (`key_case`); a path held by several elements the merge keeps
apart (two variants told apart by their variation points, or two definitions whose keys differ)
keeps every one, in document order.

- **merge**: what the merge rules forbid: one key twice where the role is not splittable, a key
  used in its scope already, an ordered role in two files, too many children, two fragments whose
  text or an attribute differ, one key under two names, a pair whose holders' rules no path tells
  apart;
- **xml_schema**: each file against the XML schema it declares (the governing one where its own is
  not at hand, said): every partial model must be valid on its own ([TPS_GST_00423]);
- **multiplicity**: each role's count in the merged model against the meta-model's
  pureMM.minOccurs and maxOccurs ([constr_2502]). The XML schema makes lower bounds 0 so a model
  may be split, so a role below its fewest can only be found after merging (`below_min`); a role
  that is one alternative of a choice in its holder's content (mixed content) has no fewest of its
  own there. What the merge already reported on a role (too many, a collision) is not said again.
  A wrapper holding its items' content has no element per item to count: such roles are not
  checked, and `check` says how many occurrences that left out.
- **reference**: every reference resolved against the path index. An element is a reference when
  its declaration, under its holder's type, has a type carrying a `DEST` attribute; the values
  that attribute's type enumerates are the DESTs it may give (an element of the same name declared
  elsewhere as plain text is not a reference). A reference resolves when any element at its path
  is the DEST element or a kind of it (an element is a kind of every class whose group its type's
  content uses, so a DEST naming an abstract class accepts its concrete subclasses). Otherwise:
  `empty` (no path); `relative` (a `BASE` attribute, or a path not starting at `/`: resolving it
  needs the REFERENCE-BASEs of its package, which this does not read, so it is reported, not
  guessed); `wrong_kind` (a DEST the reference may not give, or no element at the path of that
  kind); `case_mismatch` (the path found only by ignoring case); and, nothing being at the path,
  `external` when its nearest existing ancestor is a package (the policy's `package_element`) or
  nothing of it exists, which is a definition not loaded, else `unresolved`, a target missing from
  an element whose content is loaded. `--refs-from <file|dir>` loads more files (standard or
  vendor definitions) only to resolve references against: merged on their own, never reported.
  A path held by several elements is itself a finding, `duplicate_path`. `check` prints the
  external and unresolved references by the top-level package they point into.
**ECUC values by their definition.** The schema's split key for an ECUC parameter or reference
value is the item itself (with its variation point's label). Copied, as the specification's
`item_itself` has it, two files giving one parameter a value would give it two values; keyed by
its single-valued children, as automat's has it, the value is part of the identity, and two files
giving it different values would again be two values, two sides of a merge changing it keeping
both. The policy's `item_identity` names the roles whose
items are identified by one role of theirs instead (ECUC values by `definition`, and their
variation point's label); a definition given more than once under one container in the documents
read takes several values, which are a set told apart by content, as with the built-in rules. A
rules file records these roles (`# identity:`), since rule text cannot say a set; likewise the
repeated roles (`# repeat:`) and the elements not compared (`# ignore-content:`).

Each finding's severity comes from the policy's `[severity]` table (`"error"`, `"warning"`,
`"ignore"`; keyed by layer, `"layer.kind"` or `"layer.kind:element"` / `"layer.kind:@attribute"`,
the most specific winning; a key naming an unknown layer or kind is refused). The defaults for
references: `unresolved`, `wrong_kind`, `empty` and `duplicate_path` are errors; `external`,
`case_mismatch` and `relative` warnings. A merge problem on an element pair in conflict keeps its
kind, marked `(in conflict)`: a key for its kind applies to it, else `merge.in_conflict`. No XML schema
finding is dropped past a count; `--jobs` sets that layer's threads. `check` prints the
counts by severity, layer and kind, then the errors and warnings (the first 20 of each kind,
`--all` for every one), and exits 1 on errors only (0 clean, 1 errors, files not read or
declaring no schema, 2 when it cannot run, for every command). `--format json|sarif|junit`
writes the report for machines instead (arxmodel's own JSON with a versioned schema, SARIF
2.1.0, JUnit XML; [docs/report.md](docs/report.md)) to standard output, what was read going to
standard error. `--skip-xml`, `--skip-multiplicity` and
`--skip-references` leave a layer out; merging from a rules file has no schema, so it checks the
merge layer only (the path index is still built). `get` and `list` merge the same way and read
the index: `get` prints the element's name, how many elements it is merged from and where each
is (every one, for a path several hold), `list` the path of every referrable element of a name.
`--jobs` sets their loading threads. Without `--jobs`, loading and the XML schema layer use one
thread per CPU, at most 8, leaving room for what shares the machine.

flatxml names an aggregation by its parent (an element name, or a path of ancestor names) and its
children's element names; the schema by the parent's type and the role. So each rule becomes
flatxml rules per element name its holding type is declared with (`arxmodel/merge.v`):

- a role element that wraps its items is a single child of its holder, merged across fragments;
  its items are keyed by the split key and merged when the role is splittable, else one child
  each, ordered and limited as the role is; the item kinds of one role are one flatxml rule with
  several children, so ordered and the most hold across them;
- a role element that is itself the item is keyed or one child each in the same way;
- a role of one item is a single, merged child whatever its key and splittability: its element is
  in every fragment of the object that holds it, and fragments that disagree are reported as
  differing values;
- a wrapper of item content holds its content one child each, at most its most items times as
  often as one item holds each element;
- a split key with a part that did not resolve is not used: one child each (the rules report the
  part);
- keys are flatxml key paths: '' for the item's own text, `@NAME` for an attribute, a final `+`
  for a part whose element repeats (every occurrence, in order); an item whose parts are all
  absent is the one with the empty key (`keyless: empty`), which every such item of the
  aggregation shares, so their fragments merge and what differs is reported. No key is computed
  by arxmodel.

Where roles of different holder types give one element pair different rules (a `CONTAINERS` keyed
under one class and not under another), the pair's first rule stays the rule by name, and each
holder whose rule differs gets its role's rules, every item kind of it together, under a parent
path: `ECUC-MODULE-DEF/CONTAINERS` for a wrapper's items (the holder above the wrapper), and for a
role written directly in its holder, `PARENT/HOLDER`, PARENT being an element that holds an
element of the holder's type. A path that still names holders with different rules, or a holder no
path names (the root), is a conflict: it is reported with its occurrences, one rule is applied, and
the problems on it are marked as the conflict's rather than counted as violations; `check` exits 1
when the documents use one.

flatxml puts a node's children in the order of the rules that name them, and those no rule names
after them. So the rules of one parent are listed in the order its type's content model gives their
children (where an element name is declared with several types, one order all of them keep), each
scoped rule beside its unscoped counterpart, and a child element no role names, under a parent that
has rules, gets a rule of the kind no rule gives (each its own) for its place. A merged model is
then written in the order its schema requires.

## Export (`merge`)

`merge` merges and checks the files as `check` does, with the same options, the summary going to
standard error, and writes the merged model as one ARXML (`-o OUT`, `-o -` for standard output), by
flatxml's writer of a merged view: each element once; what came from one file and was not merged
into is copied byte for byte, comments and indentation included; an element made of several
fragments is written from its first, with the attributes only the others have, its merged children
in the schema's order, each with the indentation and comments it had; values that differ are the
first fragment's, as the merged view has them (the policy's severities say whether that is an
error). An element read where other namespace bindings were in scope is given the declarations that
restore them. The prolog and root are the first file's; in the root's `xsi:schemaLocation`, the
pair for the model's namespace is replaced by the location the first file declaring the governing
release gives (the schema's release, or with `--rules` the release the rules were made from), the
other pairs kept. A relative location that names a file beside that file is written relative to
the output; one that does not is kept as written, and said. An output that is one of the inputs, or
inside an input directory, is refused. Nothing is written where `check` would exit 1
(findings the policy calls errors, files that could not be read or declare no schema), unless
`--force`; `merge` says so.

### The specification's merge, and the automat profile: differences

The default policy merges as the AUTOSAR FO TPS Generic Structure Template, R24-11, has it; what
flatxml's merge does not do by itself is done here:

- an item whose split key parts are all absent stays an item of its own ([TPS_GST_00417]); such
  items are counted as `merge.missing_key`, ignored by default;
- keys are compared as written ([TPS_GST_00021]), and keys of one aggregation that differ only in
  case are reported, `merge.case_only` ([constr_2508]);
- the items of a multi-valued role whose split key is the role alone are copied, never merged
  ([TPS_GST_00417]), and so are primitive values, duplicates kept ([TPS_GST_00449]);
- a non-splittable multi-valued role in several fragments must repeat identically ([constr_2524],
  [TPS_GST_00447]): identical repetitions are one (unkeyed items keyed by their content, a
  document's own duplicates kept apart), and documents that give it differently are reported,
  `merge.repeated_differs`, as are two items of one key in one document;
- a structured comment (atpStructuredComment, FILE-INFO-COMMENT) is not compared
  ([TPS_GST_00382]);
- the items of a role of several item types are keyed by the union of their types' key parts
  ([TPS_GST_00416]).

The automat profile ([automat.policy.toml](automat.policy.toml), `--policy automat`) differs from
it in each of those, as automat does (`arxmodel policy --diff automat` lists them):

1. **Items with every key part absent** share one empty key and merge (`absent_keys = "empty"`).
2. **A split key naming only the role itself, on a multi-valued role**: items are keyed by their
   single-valued element children and merged by that key (`item_itself = "single_values"`).
3. **Case of keys**: compared ignoring ASCII case (`key_case = "ignore"`).
4. **Multi-valued primitive values**: identical values merge into one
   (`primitive_values = "merge_identical"`).
5. **Non-splittable collections repeated across fragments**: an unkeyed one keeps each
   occurrence, a keyed one reports a key met twice as a collision; nothing checks that
   repetitions are identical (`repeated_content = "copy"`).
6. **FILE-INFO-COMMENT** is compared like any other content (`file_info_comment = "compare"`).
7. **Abstract item types**: each item kind is keyed by its own type's key
   (`abstract_items = "per_kind"`).

Both identify ECUC parameter and reference values by their definition (`item_identity`, below):
the schema's split key for them is the item itself, which neither copying (two values for one
parameter given by two files) nor single values (the value part of the identity) keys usefully.

## Which rules (schema, rules file, or built-in)

Every command that merges says on one line which rules it read by (`rules: built-in identity
rules (...)`, `rules: schema AUTOSAR_xxxxx from DIR (...)`, `rules: rules file ...`), so a CI log
and a local run can be compared. The rules are, in order: `--no-schema` forces the built-in ones;
`--rules FILE`; `--schema-dir DIR`; the schema directory of the environment
(`ARXMODEL_SCHEMA_DIR`) or of the user's configuration (`schema_dir = "DIR"` in
`~/.config/arxmodel/config.toml`, `$XDG_CONFIG_HOME` respected); else the **built-in identity
rules** ([identity.toml](identity.toml), committed and built in), which need no schema, so CI and
git merges never need the AUTOSAR XSD:

- an element with a SHORT-NAME child is named by it (and by its VARIATION-POINT's SHORT-LABEL);
- ECUC values (`*-PARAM-VALUE`, `*-REFERENCE-VALUE`, `ECUC-CONTAINER-VALUE`) by their
  DEFINITION-REF and variation point label (a container by its SHORT-NAME too); a definition given
  more than once under one parent, in any version read, takes several values: those are a set,
  each value told apart by its content, so two sides adding values merge, while two sides
  changing a single value conflict;
- an element name some version holds with only named children (AR-PACKAGES, ELEMENTS, ...) is a
  list, one with its namesakes under a parent (an emptied one too), so the lists of several files
  merge;
- anything else is matched by its name and its place, and its order counts (a reorder is
  reported); the order of named elements does not.

They are hand-written conventions of the format, not read from a schema; a schema or a rules file
replaces them with the exact rules. Without a schema, `check` runs the merge layer and the
references (an element with a DEST attribute, resolved by path, any kind fitting); the XML schema
and multiplicity layers need the schema.

## Comparing and merging versions (`diff`, `merge3`, git)

`diff A B` compares two versions (files, or directories of files) as models: both are merged by
the same rules (the built-in ones, or the schema of the newest release either declares), and
flatxml's diff is read by AUTOSAR path. Where an element is written, the order of items whose
order means nothing, and the attributes the merge lets differ (UUID, namespace declarations, xsi:
attributes) are not changes. One line a change: `- removed`, `+ added`, `> moved`, `~ text`,
`@ attribute`, each with its positions. Exit 0 when the versions are the same model, 1 when they
differ.

`merge3 BASE OURS THEIRS [-o OUT]` merges two changed versions on their base with flatxml's
three-way merge: every byte no change touched stays as the base has it. Where the sides change one
node differently, ours is taken and the conflict is printed by AUTOSAR path on standard error. The
result is checked (by the same rules: the merge and references, or every layer with a schema) and
what that finds is printed; the exit code says whether the merge was clean (0) or had conflicts
(1). On directories it writes every file of the base to OUT, as merged; a file new on one side is
merged into the base's files rather than written as a new one. Exit 2, for any command, when
something kept it from answering.

`git-setup [REPO]` adds `*.arxml merge=arxml diff=arxml` to the repository's `.gitattributes` and
configures the drivers there: `merge3 %O %A %B -o %A` as the merge driver (a conflict leaves the
file unmerged, holding ours, with the conflicts named) and `git-diff` as the diff driver. The rules
options given are recorded in the drivers; with none, they read by what is configured where they
run, so CI uses the built-in rules. `scripts/git_driver_test.sh` runs real merges with no schema
anywhere.

## Build and test

V3 only; `.v-version` and `.vc-version` pin the V commit and its C bootstrap, as in flatxml. CI
builds them and runs the tests and the command on the synthetic model.

```sh
export V_MACOS_V3_NO_FALLBACK=1
v test .                                    # unit tests, on the synthetic schema in testdata/
v -prod -o bin/arxmodel cmd/arxmodel         # the command
```

A release is cut by pushing a tag equal to v.mod's version (`v0.1.0`) on a commit of main:
`.github/workflows/release.yml` builds the command with `-prod` for Linux (statically linked, on
ubuntu-22.04) and for Windows (cross-built with mingw-w64, then run on a Windows runner), and
attaches both with their SHA-256 sums to the GitHub release. `arxmodel version` prints the
version.

flatxml is vendored in `flatxml/` (the library, without its tests) at the commit
`flatxml/VENDORED` names, by `scripts/vendor_flatxml.sh <full commit sha>`; the copy is never
edited.
