---
status: accepted
---

# Saba's JSX compiler is built on Kessel's syntax tree

Saba's JSX transform was a self-contained lexical scanner of about 900 lines with no dependencies. The current compiler parses each module with Kessel. Saba uses that tree for reactive expression emission, SVG, spread children and static extraction. Source maps and general linting remain future work.

## Considered options

- **Keep the scanner and decide reactivity at runtime**: rejected; every expression becomes a closure, a called signal silently stays static, and the analysis features remain unsolved.

## Consequences

Kessel supplies the syntax tree, source spans and optional early-error diagnostics. Saba owns JSX emission and any mapping from an identifier use to its declaration required for optimization. The checker reports errors such as duplicate bindings. Its result supplies neither a public use-to-declaration map nor type inference. [Tagged parse job](https://github.com/dvrd/kessel/blob/v0.4.1/src/parse_job.odin#L286-L315) · [Tagged checker](https://github.com/dvrd/kessel/blob/v0.4.1/src/checker.odin#L377-L402)

The first compiler milestone defines which expressions emit readers, which props emit getters, and how the runtime forwards them. Later template extraction makes a separate decision about which values the build can evaluate. [Emission and forwarding rules](0007-saba-reactive-props-and-bindings.md)

## First compiler milestone

The initial pairing is Kessel `v0.4.1` at `4fc1eaf42d9b000a53955de3d8e175d0ba34fb3f`. Its Krs installed-source digest is `cae24825a6d9ffebb523ead5543a7ef349d028e74df474314d53bd8b623172de`. The tagged package exposes `parse_job_open_inline`, `parse_job_run`, `job.program` and `checker_run_for_job`. Pass the original source and JSX filename, run the checker once, and consume the tree and diagnostics before closing the job. Borrowed source bytes must outlive the job. [Tagged JSX node definitions](https://github.com/dvrd/kessel/blob/v0.4.1/src/ast.odin#L95-L174) · [Distribution decision](0005-krs-package-distribution.md)

Use half-open byte offsets `[start, end)` from the original source. Emit each outermost JSX expression once and recurse into its JSX children and expression holes. Copy everything outside the replaced span verbatim. Generated imports and temporaries must avoid collisions with author bindings. For a name whose lexical binding Saba cannot establish, use the conservative reader or leave the value to browser code. Shadowed imports, a parameter with the same spelling as a module constant, or an opaque call give no license to execute code at build time. [Extraction contract](0004-saba-compile-time-html-no-request-rendering.md)

Start the forwarded-prop browser test and compiler implementation using the pinned Kessel version locally. Before merging the Kessel dependency, a clean Saba fixture must obtain that version through the project distribution path, compile an Odin caller of these APIs and pass the same browser test. The parser checks open a JSX module with multibyte text before nested JSX, verify that each span recovers the original text, and report a parser or checker error against its original filename and coordinates. Run the transformed module with an import name collision, a shadowed name, a tagged-template hole and a valid async-helper hole. Verify browser behavior and unchanged neighboring JavaScript. [Implementation sequence](../SABA_UI_ROADMAP.md#first-implementation-steps) · [Current Odin transform tests](../../tests/internal/jsx_test.odin) · [Project test entry point](../../Taskfile.yml)

## Namespace belongs to the rendered position

The compiler and runtime establish the effective namespace before creating each descendant. Deferred JSX construction lets the rendering position supply the namespace, including when children pass through a component. Components, fragments, forwarded JSX children and structural bindings carry that context. An explicitly supplied, already-created DOM node retains its own namespace. [Current element construction](../../src/modules/dom.js)

An HTML `svg` or `math` root enters SVG or MathML. Use `createElementNS` for foreign elements, preserve case in SVG names, and use namespace-aware setters for qualified attributes such as `xlink:href`. Apply the HTML foreign-content integration rules at child boundaries. In particular, `foreignObject` stays SVG, its `div` child is HTML, and an `svg` nested in that `div` re-enters SVG. A dynamic child switching between a fragment and an empty value keeps its insertion namespace.

Mount `<svg><Glyph/><foreignObject><Panel/></foreignObject></svg>`, with `Glyph` returning a fragment containing `path` and `Panel` returning an HTML `div` with an inner `svg`. Assert the actual `namespaceURI` of every element. Forward `<circle/>` as children to a component that inserts it into an SVG container, and check a retained namespaced attribute by namespace and local name. A MathML component returning `mi` must produce a MathML node. Repeat the fixtures against parsed static HTML and browser-created bindings when milestone 2 introduces templates.
