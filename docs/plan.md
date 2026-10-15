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
2. Paths and references.
3. `diff`, `merge`, `check` as commands.
4. Edits and writing back.
5. Used by blobly_net's ARXML import, which today reads one file through a reader of its own.

## Verification

- Synthetic schemas carrying the same kind of annotations, and synthetic split models, written
  here: one test per rule and per problem.
- Locally: the real-world files against the real schemas, numbers only. A model split into files
  and merged back equals the model.
