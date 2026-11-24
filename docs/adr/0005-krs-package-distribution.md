---
status: accepted
---

# Libraries are distributed into `shared/` by krs, from semantic-version tags

The Webtools libraries were nested Git repositories inside `shared/`, edited in place, with no record of which commit a consumer was built against; applications such as Mesa held hand-copied versions that drifted. We are moving each library to its own repository outside `shared/` with its public code under `src/`, and a tool called krs installs tagged releases of that code into the `shared/` of an Odin root. `shared/` becomes generated output that nobody edits.

Dependencies are discovered from `shared:` imports, so no dependency list is written by hand. An Odin root holds one version of each package. A project records what it needs in `.krs/packages.json`; a root records what it holds in `shared/.krs/manifest.json`.

## Considered options

- **Keep nested repositories and hand-copying**: rejected; it is the source of the drift.
- **A per-project dependency directory** (as odpkg and most managers do): rejected; a shared collection is how Odin already resolves `shared:`, plain `odin build` keeps working without flags, and a second version is available by building against another Odin root.
- **Version ranges and a solver**: rejected; results would depend on the day of the install. Exact tags are recorded, compatible differences take the higher version, and breaking ones are decided by the user.
- **A registry**: rejected; packages are found in local source directories first, then under trusted GitHub owners, and a global search only offers a list to choose from.

## Consequences

Every library is restructured and tagged before krs can manage it; until then its directory in `shared/` is unmanaged and ignored by krs. An update or a link changes `shared/` for every project on that root. The full rules are in `shared/AGENTS.md` under Package distribution.
