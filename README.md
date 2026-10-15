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

## Use

```sh
arxmodel load <file|dir>...                        # every .arxml below the paths, one set
arxmodel rules --schema-dir DIR <file|dir>...      # and the merge rules of the schemas they declare
arxmodel rules --schema-dir DIR --problems --dump rules.tsv <file|dir>...
```

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

## Build and test

V3 only; `.v-version` and `.vc-version` pin the V commit and its C bootstrap, as in flatxml. CI
builds them and runs the tests and the command on the synthetic model.

```sh
export V_MACOS_V3_NO_FALLBACK=1
v test .                                    # unit tests, on the synthetic schema in testdata/
v -prod -o bin/arxmodel cmd/arxmodel         # the command
```

flatxml is vendored in `flatxml/` (the library, without its tests) at the commit
`flatxml/VENDORED` names, by `scripts/vendor_flatxml.sh <full commit sha>`; the copy is never
edited.
