---
status: accepted
---

# Saba's JSX compiler is built on Kessel's syntax tree

Saba's JSX transform was a self-contained lexical scanner of about 900 lines with no dependencies. The current compiler parses each module with Kessel. Saba uses that tree for reactive expression emission, SVG, spread children and static extraction. The transform can return a version 3 source map structure to an Odin caller that asks for one. In development, a module compiled from JSX ends with a `//# sourceMappingURL` comment naming `<module>.js.map` beside it, and that route compiles the source again to answer with the map. The map names its file and source relative to its own URL, so no filesystem path reaches the browser, and embeds the JSX source because the module route never serves `.jsx`. Production never serves or advertises a map, and compiled page templates and their build generations have no maps yet. General linting remains future work. [Mapping](../../src/jsx/map.odin) · [Development map route](../../src/modules/modules.odin)

## Considered options

- **Keep the scanner and decide reactivity at runtime**: rejected; every expression becomes a closure, a called signal silently stays static, and the analysis features remain unsolved.

## Consequences

Kessel supplies the syntax tree, source spans and optional early-error diagnostics. Saba owns JSX emission and any mapping from an identifier use to its declaration required for optimization. The checker reports errors such as duplicate bindings. Its result supplies neither a public use-to-declaration map nor type inference. [Tagged parse job](https://github.com/dvrd/kessel/blob/v0.4.1/src/parse_job.odin#L286-L315) · [Tagged checker](https://github.com/dvrd/kessel/blob/v0.4.1/src/checker.odin#L377-L402)

The first compiler milestone defines which expressions emit readers, which props emit getters, and how the runtime forwards them. Later template extraction makes a separate decision about which values the build can evaluate. [Emission and forwarding rules](0007-saba-reactive-props-and-bindings.md)

## First compiler milestone

The initial pairing is Kessel `v0.4.1` at `4fc1eaf42d9b000a53955de3d8e175d0ba34fb3f`. Its Krs installed-source digest is `cae24825a6d9ffebb523ead5543a7ef349d028e74df474314d53bd8b623172de`. The tagged package exposes `parse_job_open_inline`, `parse_job_run`, `job.program` and `checker_run_for_job`. Pass the original source and JSX filename, run the checker once, and consume the tree and diagnostics before closing the job. Borrowed source bytes must outlive the job. [Tagged JSX node definitions](https://github.com/dvrd/kessel/blob/v0.4.1/src/ast.odin#L95-L174) · [Distribution decision](0005-krs-package-distribution.md)

Use half-open byte offsets `[start, end)` from the original source. Emit each outermost JSX expression once and recurse into its JSX children and expression holes. Copy everything outside the replaced span verbatim. Generated imports and temporaries must avoid collisions with author bindings. For a name whose lexical binding Saba cannot establish, use the conservative reader or leave the value to browser code. Shadowed imports, a parameter with the same spelling as a module constant, or an opaque call give no license to execute code at build time. [Extraction contract](0004-saba-compile-time-html-no-request-rendering.md)

The project lock now pins Kessel `v0.21.0`. A parse error is reported at its `ParseError.start` offset, converted to the original file's line and column; Kessel reports a mismatched closing tag at the following token, so Saba moves that error back to the preceding `</`. Only the first reported error is shown, and the checker runs only when parsing succeeded. [Dependency lock](../../.krs/packages.json) · [Compiler entry](../../src/jsx/jsx.odin)

Start the forwarded-prop browser test and compiler implementation using the pinned Kessel version locally. Before merging the Kessel dependency, a clean Saba fixture must obtain that version through the project distribution path, compile an Odin caller of these APIs and pass the same browser test. The parser checks open a JSX module with multibyte text before nested JSX, verify that each span recovers the original text, and report a parser or checker error against its original filename and coordinates. Run the transformed module with an import name collision, a shadowed name, a tagged-template hole and a valid async-helper hole. Verify browser behavior and unchanged neighboring JavaScript. [Implementation sequence](../SABA_UI_ROADMAP.md#first-implementation-steps) · [Current Odin transform tests](../../tests/internal/jsx_test.odin) · [Project test entry point](../../Taskfile.yml)

## Limits and memory

Saba does not rely on the parser to bound its recursion: deeply nested or very long input could overflow the native stack while it is parsed, checked or walked. Before parsing, Saba scans the source with an estimate that needs no tokenizer. It tracks code, tags, JSX text and template literal text, skips comments and quoted strings that close on their line, and does not count text as code. It refuses:

- more than 128 nested JSX elements: `JSX nesting exceeds 128 levels`, at the opening tag that exceeds it;
- more than 256 levels of brackets: `Nesting exceeds 256 levels of brackets`;
- more than 20,000 operators, calls or indexes chained in one expression at one bracket level: `Expression nesting is too deep to compile`.

Each is a located diagnostic instead of a crash. The emitter enforces the same 128-level element limit and bounds its own tree walk. A line that starts with a letter in column zero resets the estimate, so a wrong guess cannot accumulate across a file.

The parser owns a fixed arena sized for the syntax tree. Everything the compiler itself allocates while emitting lives in a separate growing arena that is released when the compilation returns; only the result is copied to the caller's allocator.

## Namespace belongs to the rendered position

The compiler and runtime establish the effective namespace before creating each descendant. Deferred JSX construction lets the rendering position supply the namespace, including when children pass through a component. Components, fragments, forwarded JSX children and structural bindings carry that context. An explicitly supplied, already-created DOM node retains its own namespace. [Current element construction](../../src/modules/dom.js)

An HTML `svg` or `math` root enters SVG or MathML. Use `createElementNS` for foreign elements, preserve case in SVG names, and use namespace-aware setters for qualified attributes such as `xlink:href`. Apply the HTML foreign-content integration rules at child boundaries. In particular, `foreignObject` stays SVG, its `div` child is HTML, and an `svg` nested in that `div` re-enters SVG. A dynamic child switching between a fragment and an empty value keeps its insertion namespace.

Mount `<svg><Glyph/><foreignObject><Panel/></foreignObject></svg>`, with `Glyph` returning a fragment containing `path` and `Panel` returning an HTML `div` with an inner `svg`. Assert the actual `namespaceURI` of every element. Forward `<circle/>` as children to a component that inserts it into an SVG container, and check a retained namespaced attribute by namespace and local name. A MathML component returning `mi` must produce a MathML node. Repeat the fixtures against parsed static HTML and browser-created bindings when milestone 2 introduces templates.
