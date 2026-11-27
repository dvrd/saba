package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import jsx "shared:saba/jsx"

@(test)
jsx_compiles_scalar_slot_writer_for_a_hoisted_row :: proc(t: ^testing.T) {
	source := `#!/usr/bin/env node
const firstUse = mount(host, Tile)
const __saba_registerSlotRow = 1
export function Tile(record) {
  return <div class="tile &amp; cell" data-id={record().id}>
    {/* caption */}
    {record().id + ' · ' + (record().score + 1)}
  </div>
}`
	output, err := transform_jsx(source, "tile.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, strings.has_prefix(output, "#!/usr/bin/env node\nimport {"))
	testing.expect(t, strings.contains(output, "registerSlotRow as __saba_registerSlotRow_1"))
	testing.expect(t, strings.contains(output, `__saba_registerSlotRow_1(Tile, {tag:"div", attrs:{"class":"tile & cell",}, fields:["id","score"], write(element, text, row) { { const value = row["id"]; if (value == null) element.removeAttribute("data-id"); else element.setAttribute("data-id", globalThis.String(value)); } text.data = row["id"] + ' · ' + (row["score"] + 1); }});`))
	registration := strings.index(output, "__saba_registerSlotRow_1(Tile,")
	testing.expect(t, registration >= 0 && registration < strings.index(output, "const firstUse"))
	testing.expect(t, strings.contains(output, `"data-id": __saba_binding(() => (record().id))`))
	testing.expect(t, strings.contains(output, `__saba_textBinding(() => (record().id + ' · ' + (record().score + 1)))`))
}

@(test)
jsx_slot_writer_preserves_template_expressions_and_escaped_field_names :: proc(t: ^testing.T) {
	source := "export default function Caption(item) { return <span title={item().na\\u006de}>{`#${(item().count + 1)}: ${item().name}`}</span> }"
	output, err := transform_jsx(source, "caption.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, strings.contains(output, `__saba_registerSlotRow(Caption, {tag:"span", attrs:{}, fields:["name","count"]`))
	testing.expect(t, strings.contains(output, "text.data = `#${(row[\"count\"] + 1)}: ${row[\"name\"]}`"))
}

@(test)
jsx_slot_writer_rejects_rows_with_other_observable_behavior :: proc(t: ^testing.T) {
	for source in ([]string{
		`function Row(r) { return <span>{r().value}</span> }`,
		`function Row(r) { return <div>{String(r().name)}</div> }`,
		`function Row(r) { return <div>{'' + r()[field]}</div> }`,
		`function Row(r) { return <div>{'' + r?.().value}</div> }`,
		`function Row(r) { return <div>{'' + r().child.value}</div> }`,
		`function Row(r) { return <div>{'' + r().value + other()}</div> }`,
		`function Row(r) { return <div>{'' + r().value}<b/></div> }`,
		`function Row(r) { return <div ref={useRef}>{'' + r().value}</div> }`,
		`function Row(r) { return <div onClick={action}>{'' + r().value}</div> }`,
		`function Row(r) { return <div contenteditable="true">{'' + r().value}</div> }`,
		`function Row(r) { return <div title="one" title="two">{'' + r().value}</div> }`,
		`function Row(r) { return <div title={r().name} class="after">{'' + r().value}</div> }`,
		`function Row(r) { return <div {...props}>{'' + r().value}</div> }`,
		`function Row(r) { return <input value={r().value}>{'' + r().value}</input> }`,
		`function Row(r) { return <svg>{'' + r().value}</svg> }`,
		`function Row(r) { return <custom-row>{'' + r().value}</custom-row> }`,
		`function Row(r) { return <div xml:lang="en">{'' + r().value}</div> }`,
		`function Row(r = acquire()) { return <div>{'' + r().value}</div> }`,
		`function Row(...r) { return <div>{'' + r().value}</div> }`,
		`function Row(r) { observe(); return <div>{'' + r().value}</div> }`,
		`async function Row(r) { return <div>{'' + r().value}</div> }`,
		`export default (function Inner(r) { return <div>{'' + r().value}</div> })`,
		`function outer() { function Row(r) { return <div>{'' + r().value}</div> } return Row; }`,
		`/* function Fake(r) { return <p>{'' + r().value}</p> } */ const node = <div />`,
		`const sample = "function Fake(r) { return <p>{'' + r().value}</p> }"; const node = <p />`,
		`function Row(r) { return <div>{'' + /r\(\)/.test(r().value)}</div> }`,
		"const sample = `function Fake(r) { return <p>{'' + r().value}</p> }`; const node = <p />",
	}) {
		output, err := transform_jsx(source, "generic.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "", "%s: %v", source, err)
		testing.expectf(t, !strings.contains(output, "registerSlotRow"), "%s: %s", source, output)
	}
}

@(test)
transforms_html_components_fragments_and_expressions :: proc(t: ^testing.T) {
	cases := []struct {
		source, expected: string,
	} {
		{
			`const node = <button disabled title="a &amp; b" onClick={go}>{label}</button>;`,
			`const node = __saba_jsx("button", {"disabled": true,"title": "a & b","onClick": (go),}, (label));`,
		},
		{
			`const node = <><Card {...props} count={2} /><span>{ok && <b>Yes</b>}</span></>;`,
			`const node = __saba_jsx(__saba_Fragment, null, __saba_child(Card, __saba_mergeProps(__saba_mergeProps((props)), {"count": (2),})), __saba_child("span", {}, __saba_binding(() => (ok && __saba_jsx("b", {}, "Yes")))));`,
		},
		{
			`const node = <p>{/* comment */}Hello{' '}{name}</p>;`,
			`const node = __saba_jsx("p", {}, "Hello", (' '), (name));`,
		},
		{
			"const node = <p>\n  Hello\n  world\n</p>;",
			`const node = __saba_jsx("p", {}, "Hello world");`,
		},
		{
			`const node = <div title="&#x1f389; &#233;">&lt;safe&gt;</div>;`,
			`const node = __saba_jsx("div", {"title": "🎉 é",}, "<safe>");`,
		},
		{
			`const node = <UI.Card value={{ nested: [1, 2] }}>{items.map((item) => <p>{item}</p>)}</UI.Card>;`,
			`const node = __saba_jsx(UI.Card, __saba_liveProp("value", () => ({ nested: [1, 2] })), __saba_binding(() => (items.map((item) => __saba_jsx("p", {}, (item))))));`,
		},
		{`export default <p>Default</p>;`, `export default __saba_jsx("p", {}, "Default");`},
	}

	for item in cases {
		output, error := transform_jsx(item.source, "test.jsx", context.temp_allocator)
		if !testing.expectf(t, error.message == "", "%s: %v", item.source, error) {
			continue
		}
		imports := "jsx as __saba_jsx"
		for name in ([]string{"Fragment", "child", "binding", "textBinding", "liveProp", "mergeProps"}) {
			if strings.contains(item.expected, fmt.tprintf("__saba_%s", name)) {
				imports = fmt.tprintf("%s, %s as __saba_%s", imports, name, name)
			}
		}
		testing.expect_value(
			t,
			output,
			strings.concatenate(
				{"import { ", imports, " } from \"/__saba/dom.js\";\n", item.expected},
				context.temp_allocator,
			),
		)
	}
}

@(test)
jsx_specializes_proven_string_children :: proc(t: ^testing.T) {
	for expr in ([]string{
		"id + ' · ' + record().score",
		"(record().score + (':' + suffix()))",
		"`item ${record().score}`",
		"ready() ? 'yes' : ('no' + reason())",
		"typeof read()",
	}) {
		source := strings.concatenate({"<div>{", expr, "}</div>"}, context.temp_allocator)
		output, err := transform_jsx(source, "tile.jsx", context.temp_allocator)
		testing.expect_value(t, err.message, "")
		testing.expect(t, strings.contains(output, fmt.tprintf("__saba_textBinding(() => (%s))", expr)), expr)
	}

	for expr in ([]string{
		"record().score",
		"a() + b()",
		"tag`item ${read()}`",
		"String(read())",
		"ready() && ('yes' + read())",
		"ready() ? 'yes' : <b>Loading</b>",
	}) {
		source := strings.concatenate(
			{"function row(String) { return <div>{", expr, "}</div> }"},
			context.temp_allocator,
		)
		output, err := transform_jsx(source, "unknown.jsx", context.temp_allocator)
		testing.expect_value(t, err.message, "")
		testing.expect(t, strings.contains(output, "__saba_binding(() =>"), expr)
		testing.expect(t, !strings.contains(output, "textBinding"), expr)
	}
}

@(test)
jsx_string_child_optimization_requires_a_sole_emitted_child :: proc(t: ^testing.T) {
	cases := []struct {
		source: string,
		compact: bool,
	} {
		{"<p>\n  {/* note */}\n  {'a' + first()}\n</p>", true},
		{"<p>{'a' + first()}{'b' + second()}</p>", false},
		{"<p> {'a' + first()}</p>", false},
		{"<p>{'a' + first()}suffix</p>", false},
		{"<p>{'a' + first()}<b /></p>", false},
		{"<>{'a' + first()}</>", false},
	}
	for c in cases {
		output, err := transform_jsx(c.source, "siblings.jsx", context.temp_allocator)
		testing.expect_value(t, err.message, "")
		testing.expectf(t, strings.contains(output, "__saba_textBinding(() => ('a' + first()))") == c.compact, "%s: %s", c.source, output)
		testing.expectf(t, strings.contains(output, "__saba_binding(() => ('a' + first()))") == !c.compact, "%s: %s", c.source, output)
	}
}

@(test)
jsx_string_child_optimization_preserves_props_and_template_ownership :: proc(t: ^testing.T) {
	source := `const __saba_textBinding = 1;
export default function Page() {
  return <main title={'heading ' + title()}><div>{'row ' + id()}</div><Card>{'prop ' + id()}</Card></main>
}`
	page, err := jsx.compile_page_template(source, "page.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, page.supported)
	testing.expect(t, strings.contains(page.javascript, "textBinding as __saba_textBinding_1"))
	testing.expect(t, strings.contains(page.javascript, `__saba_textBinding_1(() => ('row ' + id()))`))
	testing.expect(t, strings.contains(page.javascript, `__saba_binding(() => ('heading ' + title()))`))
	testing.expect(t, strings.contains(page.javascript, `__saba_binding(() => ('prop ' + id()))`))
	testing.expect(t, strings.contains(page.html, "<!--saba:"))
	testing.expect(t, strings.contains(page.javascript, `.range(2, __saba_binding(() => ('row ' + id()))`))
}

@(test)
preserves_javascript_and_transforms_nested_template_expressions :: proc(t: ^testing.T) {
	cases := []string {
		`const x = a < b && c > d; const ratio = a / b / c;`,
		`const text = "<div>{notJSX}</div>"; // <Fake />
/* <Fake /> */ const re = /<tag>{2}[\/]/gi;`,
		"const text = `literal <div>${value / 2} ${`nested ${name}`}`;",
		`if (ready) /<tag>/.test(text); const f = () => /<tag>/;`,
		`const value = obj.return <Other;`,
		`if (ready) {} /<tag>/.test(text);`,
		`function f() {} /<tag>/.test(text); const f2 = function() {} / divisor;`,
		`const object = { if: (value) / 2 };`,
		`for (const match of /<tag>/.exec(text) || []) { console.log(match); }`,
		`for await (const match of /<tag>/.exec(text) || []) { console.log(match); }`,
		`for (const of of /<tag>/.exec(text) || []) { console.log(of); }`,
		`const of = 4; const ratio = of / 2; const other = obj.of / 2;`,
		`for (let of = 4; of / 2; of--) { const value = of / 2; }`,
		`try {} catch {} /<tag>/.test(text);`,
		"const line = 'continued\\\r\nstring';",
	}

	for source in cases {
		output, error := transform_jsx(source, "plain.jsx", context.temp_allocator)
		testing.expectf(t, error.message == "", "%s: %v", source, error)
		testing.expect_value(t, output, source)
	}

	output, error := transform_jsx(
		"const value = `prefix ${<b>{name}</b>}`;",
		"template.jsx",
		context.temp_allocator,
	)
	testing.expect(t, error.message == "", "JSX within a template expression")
	testing.expect_value(
		t,
		output,
		`import { jsx as __saba_jsx } from "/__saba/dom.js";` +
		"\nconst value = `prefix ${__saba_jsx(\"b\", {}, (name))}`;",
	)
}

@(test)
reports_invalid_jsx_with_source_locations :: proc(t: ^testing.T) {
	cases := []string {
		`<p></div>`,
		`<p>`,
		`<p title="oops>`,
		`<p value={}>`,
		`<p value={/* comment */}/>`,
		`<p {...}/>`,
		`<p {... /* comment */}/>`,
		`<p a=b/>`,
		`<p a="1"b="2"/>`,
		`<p>{...}</p>`,
		`<UI..Card />`,
		`<UI. />`,
		`<svg:path />`,
		`<p>&unknown;</p>`,
		`<p>&#x110000;</p>`,
		`<p>&#xD800;</p>`,
		`<p>&#;</p>`,
		`<p>}</p>`,
		`<p>{() => { return 1; }</p>`,
		`<p>{/unclosed}</p>`,
		"<p>{`unclosed}</p>",
	}

	for source in cases {
		output, error := transform_jsx(source, "broken.jsx", context.temp_allocator)
		testing.expectf(t, error.message != "" && output == "", "must reject %s", source)
		testing.expect_value(t, error.file, "broken.jsx")
		testing.expect(t, error.line >= 1 && error.column >= 1, "one-based diagnostic location")
	}

	_, error := transform_jsx(
		"const x = (\n  <p>\n    <b></p>\n);",
		"location.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, error.line, 3)
	_, error = transform_jsx(
		fmt.tprintf(
			"%s%s",
			strings.repeat("<p>", 140, context.temp_allocator),
			strings.repeat("</p>", 140, context.temp_allocator),
		),
		"deep.jsx",
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(error.message, "nesting"), "bounded parser recursion")
}

@(test)
automatic_jsx_imports_avoid_bindings_in_every_scope :: proc(t: ^testing.T) {
	for source in ([]string {
			`const __saba_jsx = 1; const node = <p />;`,
			`function view(__saba_jsx) { return <p />; }`,
			`const \u005f_saba_jsx = 1; const node = <p />;`,
			`const \u{5f}_saba_jsx = 1; const node = <p />;`,
		}) {
		output, error := transform_jsx(source, "bindings.jsx", context.temp_allocator)
		testing.expect_value(t, error.message, "")
		testing.expect(
			t,
			strings.has_prefix(output, `import { jsx as __saba_jsx_1 } from "/__saba/dom.js";`),
			"unique factory alias",
		)
		testing.expect(
			t,
			strings.contains(output, `__saba_jsx_1("p", {})`),
			"calls use the imported alias",
		)
	}

	output, error := transform_jsx(
		`function view(__saba_Fragment, __saba_jsx, __saba_jsx_1) { return <><i /></>; }`,
		"fragment.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, error.message, "")
	testing.expect(
		t,
		strings.has_prefix(
			output,
			`import { jsx as __saba_jsx_2, Fragment as __saba_Fragment_1, child as __saba_child }`,
		),
		"fragment and factory aliases are independent",
	)
	testing.expect(
		t,
		strings.contains(output, `__saba_jsx_2(__saba_Fragment_1, null`),
		"fragment uses its imported alias",
	)
}

@(test)
automatic_jsx_imports_preserve_existing_imports_and_hashbang :: proc(t: ^testing.T) {
	source :=
		"#!/usr/bin/env node\n" +
		`import { jsx, Fragment, helper } from './other.js';
export const node = <><span>{helper()}</span></>;`
	output, error := transform_jsx(source, "entry.jsx", context.temp_allocator)
	testing.expect_value(t, error.message, "")
	testing.expect(
		t,
		strings.has_prefix(
			output,
			"#!/usr/bin/env node\nimport { jsx as __saba_jsx, Fragment as __saba_Fragment, child as __saba_child, binding as __saba_binding }",
		),
		"hashbang precedes the generated import",
	)
	testing.expect(
		t,
		strings.contains(output, `import { jsx, Fragment, helper } from './other.js';`),
		"explicit imports remain untouched",
	)

	for plain in ([]string {
			`import { helper } from './other.js'; export const value = helper();`,
			"#!/usr/bin/env node\nconst value = 1;",
		}) {
		unchanged, plain_error := transform_jsx(plain, "plain.jsx", context.temp_allocator)
		testing.expect_value(t, plain_error.message, "")
		testing.expect_value(t, unchanged, plain)
	}
}

@(test)
jsx_uses_embedded_runtime_without_configuration :: proc(t: ^testing.T) {
	output, error := transform_jsx(
		`export default <><p /></>;`,
		"page.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, error.message, "")
	testing.expect(
		t,
		strings.has_prefix(
			output,
			`import { jsx as __saba_jsx, Fragment as __saba_Fragment, child as __saba_child } from "/__saba/dom.js";`,
		),
		"JSX always imports the embedded runtime",
	)
}

@(test)
jsx_uses_original_byte_spans_and_distinguishes_lexical_suspension :: proc(t: ^testing.T) {
	source :=
		"/* 東京 */ async function f() { return <p>{await label()}{...items}{tag" +
		"`x`" +
		"}</p>; } /* é */"
	output, failure := transform_jsx(source, "spans.jsx", context.temp_allocator)
	testing.expect_value(t, failure.message, "")
	testing.expect(t, strings.contains(output, "/* 東京 */ async function f() { return "))
	testing.expect(t, strings.has_suffix(output, "); } /* é */"))
	testing.expect(
		t,
		strings.contains(output, "(await label()), (items), __saba_binding(() => (tag"),
	)
	_, failure = transform_jsx(
		"/* é */\nfunction* gen() { return <p>{yield value}</p>; }",
		"suspend.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, failure.file, "suspend.jsx")
	testing.expect_value(t, failure.line, 2)
	testing.expect_value(t, failure.column, 30)
	testing.expect(t, strings.contains(failure.message, "yield"))
}

@(test)
jsx_reports_early_errors_in_the_authored_module :: proc(t: ^testing.T) {
	_, failure := transform_jsx(
		"const same = 1;\nconst same = <div/>;",
		"duplicate.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, failure.file, "duplicate.jsx")
	testing.expect_value(t, failure.line, 2)
	testing.expect(t, failure.message != "")
}

@(test)
template_extracts_only_proven_values_and_component_bindings :: proc(t: ^testing.T) {
	source :: `import Opaque from "./other.js";
export const title = "Heading";
function Local() { return <b>Known local</b> }
function Shadowed() { return <b>Wrong binding</b> }
export default function Page({Shadowed}) {
  return <main><h1>{"<Hello>"}</h1><Local/><Shadowed/><Opaque/><p>{privateValue()}</p></main>
}`
	page, err := jsx.compile_page_template(source, "page.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, page.supported)
	testing.expect_value(t, page.title, "Heading")
	testing.expect(
		t,
		strings.contains(page.html, "&lt;Hello&gt;") && strings.contains(page.html, "Known local"),
	)
	testing.expect(
		t,
		!strings.contains(page.html, "Wrong binding") &&
		!strings.contains(page.html, "privateValue"),
	)
	testing.expect_value(t, strings.count(page.html, ":start-->"), 3)
	testing.expect(t, strings.contains(page.javascript, "__sabaAttach(host, props)"))
	testing.expect(t, !strings.contains(page.javascript, "%!(MISSING"))
	fallback, failure := jsx.compile_page_template(
		"export default function Page() { return choosePage() }",
		"opaque.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, failure.message, "")
	testing.expect(t, !fallback.supported && fallback.html == "")
}

@(test)
template_preserves_recursive_components_and_html_parser_structure :: proc(t: ^testing.T) {
	source :: `function Tree(props) { return <b>{props.deep && <Tree/>}</b> }
export default function Page() { return <form><div><form/><Tree/></div><table>fostered text</table><span class="first" className="last" data-ready>{"\x3cHi>"}</span></form> }`
	page, err := jsx.compile_page_template(source, "recursive.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, page.supported)
	testing.expect_value(t, strings.count(page.html, ":start-->"), 3)
	testing.expect_value(t, strings.count(page.html, "<form "), 1)
	testing.expect(t, !strings.contains(page.html, "fostered text"))
	testing.expect(
		t,
		strings.contains(page.html, `class="last" data-ready="true">&lt;Hi&gt;</span>`),
	)
	testing.expect(t, !strings.contains(page.html, `class="first"`))
}

@(test)
jsx_reports_destructured_snapshot_without_changing_its_value :: proc(t: ^testing.T) {
	source :: `function Badge({count: n}) {
  return <output title={n}>{n}</output>;
}
const Next = (input) => { const {label} = input; return <>{label}{(()=>{const label = 3; return <p>{label}</p>})()}</> };
const Ordinary = (props) => <p>{props.count}</p>;`
	warnings := make([dynamic]jsx.JSX_Error, context.temp_allocator)
	page, failure := jsx.compile_module(
		source,
		"snap.jsx",
		false,
		context.temp_allocator,
		&warnings,
	)
	testing.expect_value(t, failure.message, "")
	testing.expectf(t, len(warnings) == 2, "Expected two snapshot warnings, got %v", warnings)
	if len(warnings) != 2 {
		return
	}
	testing.expect_value(t, warnings[0].file, "snap.jsx")
	testing.expect_value(t, warnings[0].line, 2)
	testing.expect_value(t, warnings[0].column, 25)
	testing.expect(
		t,
		strings.contains(warnings[0].message, "props.count") &&
		strings.contains(warnings[1].message, "input.label"),
	)
	testing.expect(t, strings.contains(page.javascript, `"title": (n)`))
}

// The lowered paths below are checked three ways: the shape of the emitted
// module, that every emitted module parses, and, in tests/ui, that a lowered
// mount and its runtime twin build the same DOM in Chromium.

KEYED_MOUNT :: `export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}`

SLOT_MOUNT :: `export function mountBand(host, records, first = 0) {
  const view = mountSlotWindow(host, Row);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}`

keyed_module :: proc(row: string, mount := KEYED_MOUNT) -> string {
	return fmt.tprintf(
		"import {{ keyed, mount, signal }} from '/__saba/dom.js';\nfunction Row(record) {{\n  return %s;\n}}\n%s\n",
		row,
		mount,
	)
}

slot_module :: proc(row: string, mount := SLOT_MOUNT) -> string {
	return fmt.tprintf(
		"import {{ mountSlotWindow }} from '/__saba/slot-window.js';\nfunction Row(record) {{\n  return %s;\n}}\n%s\n",
		row,
		mount,
	)
}

// Compile, require a clean result, and require the module to parse.
jsx_compiled :: proc(t: ^testing.T, source, label: string) -> string {
	output, err := transform_jsx(source, label, context.temp_allocator)
	testing.expectf(t, err.message == "", "%s: %s", label, err.message)
	jsx_node_check(t, label, output)
	return output
}

jsx_lowered :: proc(output: string) -> bool {
	return strings.contains(output, "function __saba_list0(")
}

// A row the proof accepts: the mount runs a direct loop for an HTML element
// host and keeps its authored statements for every other host.
jsx_expect_lowered :: proc(t: ^testing.T, source, label: string) -> string {
	output := jsx_compiled(t, source, label)
	testing.expectf(t, jsx_lowered(output), "%s was not lowered", label)
	testing.expectf(t, strings.contains(output, HTML_HOST_GUARD), "%s does not test its host", label)
	testing.expectf(t, strings.contains(output, "keyed(rows, record => record.id, Row)"), "%s lost its authored statements", label)
	testing.expectf(t, strings.contains(output, "function Row("), "%s lost its row", label)
	return output
}

HTML_HOST_GUARD :: `instanceof globalThis.Element && host.namespaceURI === "http://www.w3.org/1999/xhtml") return __saba_list0(host, records);`

// A row the proof rejects keeps every authored statement on the signal runtime.
jsx_expect_runtime :: proc(t: ^testing.T, source, label: string) -> string {
	output := jsx_compiled(t, source, label)
	testing.expectf(t, !jsx_lowered(output), "%s was lowered", label)
	testing.expectf(t, !strings.contains(output, "globalThis.document"), "%s builds DOM directly", label)
	testing.expectf(t, strings.contains(output, "function Row("), "%s lost its row", label)
	return output
}

jsx_node_check :: proc(t: ^testing.T, label, javascript: string) {
	dir, dir_err := os.make_directory_temp("", "saba-jsx-check-*", context.temp_allocator)
	if !testing.expectf(t, dir_err == nil, "could not create a directory for %s", label) {
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/module.mjs", dir)
	if !testing.expect(t, os.write_entire_file(path, transmute([]u8)javascript) == nil) {
		return
	}
	result, _, errors, err := os.process_exec({command = {"node", "--check", path}}, context.temp_allocator)
	if err != nil {
		log.infof("node is not on PATH (%v). Skipped the syntax check of %s.", err, label)
		return
	}
	testing.expectf(t, result.success, "%s does not parse:\n%s\n%s", label, string(errors), javascript)
}

jsx_between :: proc(output, start, stop: string) -> string {
	from := strings.index(output, start)
	if from < 0 {
		return ""
	}
	rest := output[from:]
	to := strings.index(rest, stop)
	if to < 0 {
		return ""
	}
	return rest[:to]
}

@(test)
jsx_lowers_a_proved_keyed_row :: proc(t: ^testing.T) {
	output := jsx_expect_lowered(
		t,
		keyed_module(
			`<div class="cell &amp; row" data-id={record().id} data-score={record().score} title={record().id + ' · ' + record().score}>{record().id + ' · ' + record().score}</div>`,
		),
		"keyed.jsx",
	)
	// The authored signature survives. An HTML element takes the direct loop;
	// a ref(name) reference, an element of another namespace or anything else
	// takes the authored statements, and with them the runtime's handling.
	testing.expect(
		t,
		strings.contains(
			output,
			"export function mountBand(host, records) {\n  if (host instanceof globalThis.Element && host.namespaceURI === \"http://www.w3.org/1999/xhtml\") return __saba_list0(host, records);\n  const rows = signal(records);\n  const list = keyed(rows, record => record.id, Row);\n  const dispose = mount(host, () => __saba_jsx(__saba_Fragment, null, (list)));\n  return { replace: rows.set, dispose };\n}",
		),
	)
	testing.expect(t, strings.contains(output, "import { keyed, mount, signal } from '/__saba/dom.js';"))
	testing.expect(t, !strings.contains(output, "throw new globalThis.TypeError(\"Expected a DOM element"))
	create := jsx_between(output, "function __saba_create0(", "function __saba_move0(")
	testing.expect(t, strings.contains(create, `element.className = "cell & row";`))
	// The validated key and a proven string are written directly. Any other
	// value goes through the runtime's attribute rules.
	testing.expect(t, strings.contains(create, `element.setAttribute("data-id", row["id"]);`))
	testing.expect(t, strings.contains(create, `__saba_attr0(element, "data-score", row["score"], true);`))
	testing.expect(t, strings.contains(create, `element.setAttribute("title", row["id"] + ' · ' + row["score"]);`))
	update := jsx_between(output, "cell.record !== row", "cell.record = row")
	testing.expect(t, strings.contains(update, "cell.text.data"))
	testing.expect(t, strings.contains(update, `"data-score"`))
	testing.expect(t, strings.contains(update, `"title"`))
	testing.expect(t, !strings.contains(update, `"data-id"`))
	// Keys follow the runtime's rules and messages.
	testing.expect(t, strings.contains(output, `"A row key must be a string or finite number."`))
	testing.expect(t, strings.contains(output, `"Duplicate row key: "`))
	testing.expect(t, strings.contains(output, "globalThis.Array.from(current)"))
	testing.expect(t, strings.contains(output, "globalThis.Object.is(items, current)"))

	// Rows are placed before an end marker, never at the end of the host, so
	// a host with other children keeps the list where it was mounted.
	list := jsx_between(output, "function __saba_list0(", "export function mountBand")
	testing.expect(t, strings.contains(list, "const end = globalThis.document.createComment(\"\");\n  host.append(end);"))
	testing.expect(t, strings.contains(list, "let before = end;"))
	testing.expect(t, !strings.contains(list, "let before = null;"))
	// The list belongs to the scope it is mounted in, as a runtime mount does,
	// and a failed first render leaves nothing behind.
	testing.expect(t, strings.contains(output, "ownSlotWindow as __saba_ownSlotWindow"))
	testing.expect(t, strings.contains(list, "const release = __saba_ownSlotWindow(end, () => {"))
	testing.expect(t, strings.contains(list, "end.remove();"))
	testing.expect(t, strings.contains(list, "} catch (error) {\n    release();\n    throw error;"))
	testing.expect(t, strings.contains(list, "dispose: release,"))
}

@(test)
jsx_keeps_a_slot_window_on_the_runtime :: proc(t: ^testing.T) {
	// The runtime's window enforces an empty, exclusive host, validates every
	// range, recovers from foreign mutation and tracks records with accessors.
	// None of that is provable here, so the mount is left as written. The row
	// is registered, which gives the window its direct writer.
	output := jsx_compiled(
		t,
		slot_module(
			`<div class="cell" data-id={record().element} title={record().text + ''} aria-label={record().label}>{record().text + ' · ' + record().element}</div>`,
			`export function mountBand(host, records, first = 5) {
  const view = mountSlotWindow(host, Row);
  const replace = (next, nextFirst = 7) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}`,
		),
		"slot.jsx",
	)
	testing.expect(t, !jsx_lowered(output))
	testing.expect(t, !strings.contains(output, "globalThis.document"))
	testing.expect(t, strings.contains(output, "import { mountSlotWindow } from '/__saba/slot-window.js';"))
	testing.expect(t, strings.contains(output, "const view = mountSlotWindow(host, Row);"))
	testing.expect(t, strings.contains(output, "const replace = (next, nextFirst = 7) => view.replace(nextFirst, next);"))
	testing.expect(t, strings.contains(output, "export function mountBand(host, records, first = 5) {"))

	// The registered writer follows the runtime's attribute rules: nullish
	// removes the attribute, and false removes it unless the name is data-*
	// or aria-*. A proven string is written as it is.
	testing.expect(
		t,
		strings.contains(
			output,
			`write(element, text, row) { { const value = row["element"]; if (value == null) element.removeAttribute("data-id"); else element.setAttribute("data-id", globalThis.String(value)); } element.setAttribute("title", row["text"] + ''); { const value = row["label"]; if (value == null) element.removeAttribute("aria-label"); else element.setAttribute("aria-label", globalThis.String(value)); } text.data = row["text"] + ' · ' + row["element"]; }`,
		),
	)
	plain := jsx_compiled(t, `function Row(r) { return <div class={r().kind} title={r().tip}>{r().id + ''}</div> }`, "slot-plain.jsx")
	testing.expect(
		t,
		strings.contains(
			plain,
			`{ const value = row["tip"]; if (value == null || value === false) element.removeAttribute("title"); else element.setAttribute("title", value === true ? "" : globalThis.String(value)); }`,
		),
	)
	testing.expect(t, !strings.contains(plain, `element.setAttribute("title", row["tip"])`))
	// The writer reaches String through globalThis. A module that names it
	// keeps the row on tracked bindings.
	shadowed := jsx_compiled(t, `const g = globalThis; function Row(r) { return <div title={r().tip}>{r().id + ''}</div> }`, "slot-shadowed.jsx")
	testing.expect(t, !strings.contains(shadowed, "registerSlotRow"))
	strings_only := jsx_compiled(t, `const g = globalThis; function Row(r) { return <div title={r().tip + ''}>{r().id + ''}</div> }`, "slot-strings.jsx")
	testing.expect(t, strings.contains(strings_only, `element.setAttribute("title", row["tip"] + '');`))
}

@(test)
jsx_lowers_a_checkbox_row_that_follows_its_key :: proc(t: ^testing.T) {
	output := jsx_expect_lowered(
		t,
		keyed_module(`<input type="checkbox" checked={record().on} data-id={record().id} title={record().label} />`),
		"checkbox.jsx",
	)
	testing.expect(t, strings.contains(output, `globalThis.document.createElement("input")`))
	testing.expect(t, strings.contains(output, `element.checked = row["on"];`))
	testing.expect(t, !strings.contains(output, `setAttribute("checked"`))
	testing.expect(t, strings.contains(output, "globalThis.document.createDocumentFragment()"))
	testing.expect(t, strings.contains(output, `"Duplicate row key: "`))
	testing.expect(t, !strings.contains(output, "replaceChildren"))
	list := jsx_between(output, "function __saba_list0(", "export function mountBand")
	// While the keys arrive in mounted order nothing is looked up, and a
	// record that is the same object is not written again.
	testing.expect(t, strings.contains(list, `for (let i = 0; same && i < next.length; i++) same = next[i]["id"] === keys[i];`))
	testing.expect(t, strings.contains(list, "if (rows[i] !== next[i]) __saba_update0(boxes[i], next[i]);"))
	// When the keys change the elements are matched by key, so an element
	// keeps its record, and with it focus and what the user toggled.
	testing.expect(t, strings.contains(list, "const at = old.get(id);"))
	testing.expect(t, strings.contains(list, "created[i] = boxes[at];"))
	testing.expect(t, strings.contains(list, "for (const at of old.values()) boxes[at].remove();"))
	testing.expect(t, strings.contains(list, "__saba_move0(host, created[i], before);"))
	testing.expect(t, strings.contains(list, "host.insertBefore(fragment, end);"))
	testing.expect(t, strings.contains(list, "const release = __saba_ownSlotWindow(end, () => {"))
	// An element keeps its key for life, so only the other attributes are
	// written again.
	update := jsx_between(output, "function __saba_update0(element, row) {", "function __saba_list0(")
	testing.expect(t, !strings.contains(update, `"data-id"`))
	testing.expect(t, strings.contains(update, `__saba_attr0(element, "title", row["label"], false);`))
	testing.expect(t, strings.contains(update, "element.checked !== on"))
	// The runtime writes a quoted checked through the live property.
	jsx_expect_runtime(t, keyed_module(`<input type="checkbox" checked="yes" data-id={record().id} />`), "checked-literal.jsx")
}

@(test)
jsx_lowers_tree_rows_with_media_and_holes :: proc(t: ^testing.T) {
	image := jsx_expect_lowered(t, keyed_module(`<img data-id={record().id} src={record().src} alt={record().alt} />`), "img.jsx")
	testing.expect(t, strings.contains(image, `globalThis.document.createElement("img")`))
	image_update := jsx_between(image, "cell.record !== row", "cell.record = row")
	// A URL goes through the runtime's own check, so a javascript: URL throws
	// and trusted() is unwrapped exactly as on the runtime path.
	testing.expect(t, strings.contains(image_update, `__saba_attr0(cell.element, "src", __saba_checkedAttribute("src", row["src"]), false);`))
	testing.expect(t, strings.contains(image, `checkedAttribute as __saba_checkedAttribute`))
	// A static URL is lowered only when it plainly is not a javascript: URL.
	jsx_expect_lowered(t, keyed_module(`<img src="/a.png" data-id={record().id} alt={record().alt} />`), "img-static.jsx")
	jsx_expect_runtime(t, keyed_module(`<img src="javascript:alert(1)" data-id={record().id} alt={record().alt} />`), "img-script.jsx")
	// Rows without a URL do not import the check.
	plain := jsx_expect_lowered(t, keyed_module(`<div data-id={record().id} title={record().title}>{record().label + ''}</div>`), "plain.jsx")
	testing.expect(t, !strings.contains(plain, "checkedAttribute"))
	testing.expect(t, strings.contains(image_update, `"alt"`))
	testing.expect(t, !strings.contains(image_update, `"data-id"`))

	video := jsx_expect_lowered(
		t,
		keyed_module(`<video preload="metadata" data-id={record().id} src={record().src} poster={record().poster} />`),
		"video.jsx",
	)
	testing.expect(t, strings.contains(video, `element.setAttribute("preload", "metadata");`))
	testing.expect(t, !strings.contains(jsx_between(video, "cell.record !== row", "cell.record = row"), "preload"))

	card := jsx_expect_lowered(
		t,
		keyed_module(
			"<div class=\"card\" data-id={record().id}><img src={record().src} alt={record().alt} /><span>x &amp; y {`${record().title}`}</span>{record().vip ? <div><span><b>deep</b></span></div> : null}{record().author.name + ''}<input type=\"checkbox\" checked={record().on} /></div>",
		),
		"card.jsx",
	)
	// Static text is entity-decoded exactly once.
	testing.expect(t, strings.contains(card, `createTextNode("x & y ")`))
	testing.expect(t, !strings.contains(card, "&amp;"))
	testing.expect(t, strings.contains(card, `row["author"]["name"] + ''`))
	testing.expect(t, strings.contains(card, `.checked = row["on"];`))
	// Every element of a nested branch has its own name.
	testing.expect(t, !strings.contains(card, "nested"))
	testing.expect(t, strings.contains(card, "b0.append(b1);"))
	testing.expect(t, strings.contains(card, "h0.append(b0);"))
	card_update := jsx_between(card, "cell.record !== row", "cell.record = row")
	testing.expect(t, strings.contains(card_update, ".checked !== on"))
	testing.expect(t, strings.contains(card_update, "insertBefore("))
	testing.expect(t, !strings.contains(card_update, `createElement("img")`))
}

@(test)
jsx_declines_rows_it_cannot_prove_equal_to_the_runtime :: proc(t: ^testing.T) {
	for row in ([]string {
			// A bare field can hold a node, an array, null or a boolean.
			`<div data-id={record().id}>{record().title}</div>`,
			`<div data-id={record().id}><span>{record().title}</span></div>`,
			`<div data-id={record().id}>{record().vip ? <b>{record().title}</b> : null}<i>x</i></div>`,
			`<div data-id={record().id}>{record().score + 1}</div>`,
			// Namespaces follow the rendered position.
			`<div data-id={record().id}><svg class="i"><path class="p"/></svg>{record().id + ''}</div>`,
			`<a data-id={record().id}><b>{record().id + ''}</b></a>`,
			`<my-row data-id={record().id}><b>{record().id + ''}</b></my-row>`,
			// Behavior the direct loop does not have.
			`<div data-id={record().id} onClick={select}>{record().id + ''}</div>`,
			`<div data-id={record().id}>{other() + ''}</div>`,
			`<div data-id={record().id} style={record().style + ''}>{record().id + ''}</div>`,
			// An entity only the ordinary emitter may report.
			`<div data-id={record().id}><b>&bogus;</b>{record().id + ''}</div>`,
		}) {
		source := keyed_module(row)
		output, err := transform_jsx(source, "declined.jsx", context.temp_allocator)
		if strings.contains(row, "&bogus;") {
			testing.expect(t, strings.contains(err.message, "Unsupported JSX entity"), row)
			continue
		}
		testing.expectf(t, err.message == "", "%s: %s", row, err.message)
		testing.expectf(t, !jsx_lowered(output), "lowered %s", row)
		testing.expect(t, strings.contains(output, "keyed("), row)
		testing.expect(t, strings.contains(output, "/__saba/dom.js"), row)
		jsx_node_check(t, row, output)
	}
}

@(test)
jsx_lowers_only_mounts_built_on_the_saba_runtime :: proc(t: ^testing.T) {
	row :: `<div data-id={record().id}>{record().id + ''}</div>`
	other_lib, _ := strings.replace_all(keyed_module(row), "'/__saba/dom.js'", "'./my-own-lib.js'", context.temp_allocator)
	jsx_expect_runtime(t, other_lib, "foreign-import.jsx")
	renamed, _ := strings.replace_all(keyed_module(row), "{ keyed, mount, signal }", "{ keyed, mount, computed as signal }", context.temp_allocator)
	jsx_expect_runtime(t, renamed, "renamed-import.jsx")
	// A parameter or a constant that shadows a runtime name.
	jsx_expect_runtime(
		t,
		keyed_module(
			row,
			`export function mountBand(host, records, keyed) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}`,
		),
		"shadowed.jsx",
	)
	// Any other shape of the mount.
	jsx_expect_runtime(
		t,
		keyed_module(
			row,
			`export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <section>{list}</section>);
  return { replace: rows.set, dispose };
}`,
		),
		"wrapped.jsx",
	)
	// Generated code reaches the platform through globalThis.
	jsx_expect_runtime(t, strings.concatenate({keyed_module(row), "const realm = globalThis;\n"}, context.temp_allocator), "global-this.jsx")
}

@(test)
jsx_lowering_leaves_the_rest_of_the_module_alone :: proc(t: ^testing.T) {
	row :: `<div data-id={record().id}>{record().id + ''}</div>`
	// The authored statements stay in the mount, so the row, its registration
	// and every import stay exactly as written.
	exported, _ := strings.replace_all(keyed_module(row), "function Row(", "export function Row(", context.temp_allocator)
	kept := jsx_compiled(t, exported, "exported-row.jsx")
	testing.expect(t, jsx_lowered(kept))
	testing.expect(t, strings.contains(kept, "export function Row(record)"))
	testing.expect(t, strings.contains(kept, "__saba_registerSlotRow(Row,"))

	shared := strings.concatenate(
		{
			"import { keyed, mount, signal, effect } from '/__saba/dom.js';\nimport * as dom from '/__saba/dom.js';\nimport Default, { computed as derived } from '/__saba/dom.js';\n",
			"export const total = signal(0);\nexport const twice = derived(() => total() * 2);\nfunction Row(record) {\n  return ", row, ";\n}\n",
			KEYED_MOUNT,
			"\nexport function other() { return Row; }\n",
		},
		context.temp_allocator,
	)
	output := jsx_compiled(t, shared, "shared.jsx")
	testing.expect(t, jsx_lowered(output))
	testing.expect(t, strings.contains(output, "function Row(record)"))
	testing.expect(t, strings.contains(output, "import { keyed, mount, signal, effect } from '/__saba/dom.js';"))
	testing.expect(t, strings.contains(output, "import * as dom from '/__saba/dom.js';"))
	testing.expect(t, strings.contains(output, "import Default, { computed as derived } from '/__saba/dom.js';"))
	testing.expect(t, strings.contains(output, "export const total = signal(0);"))
	testing.expect(t, strings.contains(output, "export function other() { return Row; }"))

	// Two mounts on one row, one of them outside the proof.
	second := strings.concatenate(
		{
			keyed_module(row),
			"export function mountB(host, records) {\n  const rows = signal(records);\n  return mount(host, () => <section>{keyed(rows, r => r.id, Row)}</section>);\n}\n",
		},
		context.temp_allocator,
	)
	both := jsx_compiled(t, second, "two-readers.jsx")
	testing.expect(t, jsx_lowered(both))
	testing.expect(t, strings.contains(both, "function Row(record)"))
	testing.expect_value(t, strings.count(both, "function __saba_list"), 1)
}

@(test)
jsx_lowered_names_avoid_authored_bindings :: proc(t: ^testing.T) {
	row :: `<div data-id={record().id}>{record().create + ' create'}</div>`
	// Authored names that the first lowering collided with: module bindings
	// named like a helper or a global, and parameters named like a local.
	source := strings.concatenate(
		{
			"const move = 1, create = 2, textOf = 3, Map = null, Set = null, document = null, Number = null;\nconst __saba_list0 = 4, __saba_create0 = 5;\n",
			keyed_module(
				row,
				`export function mountBand(before, cells = [], next) {
  const rows = signal(cells);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(before, () => <>{list}</>);
  return { replace: rows.set, dispose };
}`,
			),
		},
		context.temp_allocator,
	)
	output := jsx_compiled(t, source, "collisions.jsx")
	testing.expect(t, strings.contains(output, "function __saba_list0_1(host, records)"))
	testing.expect(t, strings.contains(output, "function __saba_create0_1(row)"))
	testing.expect(
		t,
		strings.contains(
			output,
			"export function mountBand(before, cells = [], next) {\n  if (before instanceof globalThis.Element && before.namespaceURI === \"http://www.w3.org/1999/xhtml\") return __saba_list0_1(before, cells);\n  const rows = signal(cells);",
		),
	)
	testing.expect(t, strings.contains(output, `row["create"] + ' create'`))
	testing.expect(t, strings.contains(output, "new globalThis.Map()"))
	testing.expect(t, strings.contains(output, "globalThis.Number.isFinite"))

	// Two mounts take separate names.
	two := `import { keyed, mount, signal } from '/__saba/dom.js';
function Person(record) {
  return <div data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}
export function mountPeople(host, people) {
  const rows = signal(people);
  const list = keyed(rows, record => record.id, Person);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
function Task(record) {
  return <div data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}
export function mountTasks(host, tasks) {
  const rows = signal(tasks);
  const list = keyed(rows, record => record.id, Task);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}`
	pair := jsx_compiled(t, two, "two-mounts.jsx")
	for name in ([]string{"__saba_list0(host", "__saba_list1(host", "__saba_create0(row)", "__saba_create1(row)", "__saba_move0(parent", "__saba_move1(parent"}) {
		testing.expect_value(t, strings.count(pair, fmt.tprintf("function %s", name)), 1)
	}
	testing.expect(t, strings.contains(pair, ") return __saba_list0(host, people);"))
	testing.expect(t, strings.contains(pair, ") return __saba_list1(host, tasks);"))
}

@(test)
jsx_swaps_a_proved_hole_with_a_tracked_synchronous_write :: proc(t: ^testing.T) {
	// A prop getter in the condition is followed. The write starts at once,
	// which effect() does not do during row preparation or activation.
	panel := jsx_compiled(
		t,
		"function Panel(props) {\n  return <div className=\"panel\" title=\"p &amp; q\"><span>before</span>{props.open ? <p htmlFor=\"x\">shown {`${props.label}`} {7}</p> : null}<span>after</span></div>;\n}",
		"panel.jsx",
	)
	testing.expect(t, strings.contains(panel, "paint as __saba_paint"))
	testing.expect(t, strings.contains(panel, "__saba_paint(__saba_swap);"))
	testing.expect(t, !strings.contains(panel, "__saba_effect"))
	testing.expect(t, !strings.contains(panel, "__saba_swap();"))
	testing.expect(t, !strings.contains(panel, "__saba_binding"))
	testing.expect(t, !strings.contains(panel, "createComment"))
	testing.expect(t, strings.contains(panel, "if (props.open) {"))
	// JSX aliases are written under their HTML names.
	testing.expect(t, strings.contains(panel, `.className = "panel";`))
	testing.expect(t, strings.contains(panel, `.setAttribute("for", "x");`))
	testing.expect(t, strings.contains(panel, `.setAttribute("title", "p & q");`))
	testing.expect(t, !strings.contains(panel, `"className"`))
	swap := panel[max(strings.index(panel, "const __saba_swap"), 0):]
	testing.expect(t, strings.contains(swap, `createElement("p")`))
	testing.expect(t, !strings.contains(swap, `createElement("span")`))

	card := jsx_compiled(
		t,
		"function Card(record) {\n  return <li><span>before</span>{record().caption ? <em>{`${record().caption}`}</em> : null}<span>after</span></li>;\n}",
		"card-hole.jsx",
	)
	testing.expect(t, strings.contains(card, "__saba_paint(__saba_swap);"))

	for source in ([]string {
			// A child that may be a node, an array, null or a boolean.
			`function Kids(props) { return <div>{props.open ? <p>{props.children}</p> : null}</div>; }`,
			`function Kids(props) { return <div>{props.open ? <p>{props.count && props.label}</p> : null}</div>; }`,
			`function Card(record) { return <div>{record().caption ? <em>{record().caption}</em> : null}</div>; }`,
			// A namespace the position decides.
			`function Icon(on) { return <i>{on() ? <svg viewBox="0 0 1 1"><path d="M0 0"/></svg> : null}</i>; }`,
			`function Link(on) { return <a>{on() ? <b>x</b> : null}</a>; }`,
			// Attributes the runtime does not write with setAttribute.
			`function Field(on) { return <div style="color: red">{on() ? <b>x</b> : null}</div>; }`,
			`function Field(on) { return <div onclick="go()">{on() ? <b>x</b> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <button ONCLICK="go()">y</button> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <button formaction="javascript:go()">y</button> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <a href="&#106;avascript:go()">y</a> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <button formaction="https://example.test/?a=1&b=2">y</button> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <iframe srcdoc="x"></iframe> : null}</div>; }`,
			// A component decides whether its children are built at all.
			`function Field(on) { return <Guard when={on}><p>{on().admin ? <b>x</b> : null}</p></Guard>; }`,
			`function Field(on) { return <div>{on() ? <input value="x"/> : null}</div>; }`,
			// A call the compiler cannot see through.
			`function Field(on) { return <div>{other() ? <b>x</b> : null}</div>; }`,
			`const globalThis = window; function Field(on) { return <div>{on() ? <b>x</b> : null}</div>; }`,
		}) {
		output, err := transform_jsx(source, "hole-declined.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "", "%s: %s", source, err.message)
		testing.expectf(t, !strings.contains(output, "__saba_paint"), "direct hole for %s", source)
		testing.expectf(t, strings.contains(output, "__saba_binding(() => ("), "no binding for %s", source)
		jsx_node_check(t, source, output)
	}
}

// The browser suite runs this fixture. Here it must take every lowered path,
// so that suite cannot pass by comparing the runtime with itself.
@(test)
jsx_differential_fixture_takes_every_lowered_path :: proc(t: ^testing.T) {
	source, read := os.read_entire_file("tests/fixtures/ui/lowered.jsx", context.temp_allocator)
	if !testing.expect(t, read == nil, "could not read tests/fixtures/ui/lowered.jsx") {
		return
	}
	output := jsx_compiled(t, string(source), "lowered.jsx")
	// Each Direct mount runs its own loop for an HTML host and keeps its
	// authored statements for any other.
	for name, index in ([]string{"flatDirect", "treeDirect", "boxDirect"}) {
		body := jsx_between(output, fmt.tprintf("export function %s(", name), "\n}")
		guard := fmt.tprintf(
			"if (host instanceof globalThis.Element && host.namespaceURI === \"http://www.w3.org/1999/xhtml\") return __saba_list%d(host, records);",
			index,
		)
		testing.expectf(t, strings.contains(body, guard), "%s is not lowered: %s", name, body)
		testing.expectf(t, strings.contains(body, "const list = keyed(rows, record => record.id,"), "%s lost its authored statements", name)
	}
	testing.expect_value(t, strings.count(output, "function __saba_list"), 3)
	testing.expect_value(t, strings.count(output, "(end, () => {"), 3)
	testing.expect(t, strings.contains(output, "let boxes = []"))
	testing.expect(t, strings.contains(output, "const at = old.get(id);"))
	testing.expect(t, strings.contains(output, "cell.h0"))
	testing.expect_value(t, strings.count(output, "__saba_paint(__saba_swap);"), 2)
	for name in ([]string{"flatRuntime", "treeRuntime", "boxRuntime"}) {
		body := jsx_between(output, fmt.tprintf("export function %s(", name), "\n}")
		testing.expectf(t, !strings.contains(body, "__saba_list") && strings.contains(body, "void 0;"), "%s left the runtime", name)
	}
	// Slot windows are never lowered. One row is registered for the window's
	// direct writer and its twin, with a second child, is tracked.
	for name in ([]string{"slotRegistered", "slotTracked"}) {
		body := jsx_between(output, fmt.tprintf("export function %s(", name), "\n}")
		testing.expectf(t, !strings.contains(body, "__saba_list") && strings.contains(body, "mountSlotWindow(host,"), "%s left the runtime", name)
	}
	testing.expect(t, strings.contains(output, "__saba_registerSlotRow(SlotRegistered,"))
	testing.expect(t, !strings.contains(output, "__saba_registerSlotRow(SlotTracked,"))
	for name in ([]string {
			"FlatDirect", "TreeDirect", "BoxDirect", "FlatRuntime", "TreeRuntime", "BoxRuntime",
			"SlotRegistered", "SlotTracked", "PanelRuntime", "CardRuntime", "Owner",
		}) {
		testing.expectf(t, strings.contains(output, fmt.tprintf("function %s(", name)), "%s is missing", name)
	}
	testing.expect(t, strings.contains(output, `import { keyed, mount, signal } from "/__saba/dom.js";`))
	testing.expect(t, strings.contains(output, `import { mountSlotWindow, scalarRecord } from "/__saba/slot-window.js";`))
	again, _ := transform_jsx(string(source), "lowered.jsx", context.temp_allocator)
	testing.expect(t, again == output, "lowered output is not deterministic")
}

@(test)
jsx_treats_a_bare_ampersand_as_text :: proc(t: ^testing.T) {
	output := jsx_compiled(
		t,
		`const a = <p title="/x?a=1&b=2;c=3">Fish & chips; R&D &amp; &#x41;&#65; &#x:; a &b c;</p>;`,
		"ampersand.jsx",
	)
	testing.expect(t, strings.contains(output, `"title": "/x?a=1&b=2;c=3"`))
	testing.expect(t, strings.contains(output, `"Fish & chips; R&D & AA &#x:; a &b c;"`))

	_, named := transform_jsx("const a = <p>\n  one &amp; two &nbsp; three\n</p>;", "entity.jsx", context.temp_allocator)
	testing.expect(t, strings.contains(named.message, "Unsupported JSX entity"))
	testing.expect_value(t, named.line, 2)
	testing.expect_value(t, named.column, 17)
	_, attribute := transform_jsx(`const a = <p title="a &copy; b"/>;`, "entity.jsx", context.temp_allocator)
	testing.expect_value(t, attribute.line, 1)
	testing.expect_value(t, attribute.column, 23)
	_, numeric := transform_jsx(`const a = <p>&#xD800;</p>;`, "entity.jsx", context.temp_allocator)
	testing.expect(t, strings.contains(numeric.message, "Invalid Unicode JSX entity"))
	testing.expect_value(t, numeric.column, 14)
	_, hex := transform_jsx(`const a = <p>&#12a;</p>;`, "entity.jsx", context.temp_allocator)
	testing.expect(t, strings.contains(hex.message, "Invalid numeric JSX entity"))
}

@(test)
jsx_reports_nesting_it_cannot_compile :: proc(t: ^testing.T) {
	// Long enough to exceed the tree walk's budget, short enough for the
	// parser and checker of the pinned kessel, which have no limit of their own.
	chain := strings.concatenate({"const a = <p>{", strings.repeat("1+", 900, context.temp_allocator), "1}</p>;"}, context.temp_allocator)
	_, deep := transform_jsx(chain, "chain.jsx", context.temp_allocator)
	testing.expect(t, strings.contains(deep.message, "Expression nesting is too deep"))
	testing.expect_value(t, deep.line, 1)

	closers := []string{")", "]", "}"}
	for open, index in ([]string{"(", "[", "{a:"}) {
		close := closers[index]
		nested := strings.concatenate(
			{"const x = ", strings.repeat(open, 2000, context.temp_allocator), "1", strings.repeat(close, 2000, context.temp_allocator), ";\nconst a = <p/>;"},
			context.temp_allocator,
		)
		_, err := transform_jsx(nested, "brackets.jsx", context.temp_allocator)
		testing.expect(t, strings.contains(err.message, "Nesting exceeds 256 levels of brackets"), open)
		testing.expect_value(t, err.line, 1)
	}

	// Ordinary nesting, and stray brackets in strings, comments and JSX text
	// spread over many statements, compile.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "const v%d = [fetch(`https://example.test/${{%d}}`), \"((((\", '[[[[']; // ((( {{{{ [[[\n", i, i)
	}
	strings.write_string(&b, "const a = <p>:( don't (</p>;\n")
	strings.write_string(&b, strings.repeat("(", 200, context.temp_allocator))
	strings.write_string(&b, "1")
	strings.write_string(&b, strings.repeat(")", 200, context.temp_allocator))
	strings.write_string(&b, ";\n")
	output, fine := transform_jsx(strings.to_string(b), "ordinary.jsx", context.temp_allocator)
	testing.expect_value(t, fine.message, "")
	testing.expect(t, strings.contains(output, `__saba_jsx("p", {}, ":( don't (")`))
}

@(test)
jsx_collects_warnings_in_an_empty_array :: proc(t: ^testing.T) {
	// The array starts without an allocator. Its storage must outlive the
	// parser arena the compiler works in.
	warnings: [dynamic]jsx.JSX_Error
	_, failure := jsx.compile_module(
		"function Badge({count}) { return <output>{count}</output>; }\nfunction Other({label}) { return <p>{label}</p>; }",
		"snap.jsx",
		false,
		context.temp_allocator,
		&warnings,
	)
	testing.expect_value(t, failure.message, "")
	if !testing.expect_value(t, len(warnings), 2) {
		return
	}
	// Churn the allocators the arena came from, then read the warnings.
	for _ in 0 ..< 8 {
		_, _ = transform_jsx("const a = <p>{x}</p>;", "churn.jsx", context.temp_allocator)
	}
	testing.expect(t, strings.contains(warnings[0].message, "props.count"))
	testing.expect(t, strings.contains(warnings[1].message, "props.label"))
}

@(test)
jsx_maps_every_copied_line_after_collapsed_jsx :: proc(t: ^testing.T) {
	source := "#!/usr/bin/env node\nconst é = 1;\nconst view = (\n  <section>\n    <p>{é}</p>\n  </section>\n);\nfunction later() {\n  throw new Error('é'); const b = <b/>;\n}\n"
	mapped: jsx.Source_Map
	output, err := transform_jsx(source, "lines.jsx", context.temp_allocator, &mapped)
	testing.expect_value(t, err.message, "")
	lines := strings.split_lines(output, context.temp_allocator)
	source_lines := strings.split_lines(source, context.temp_allocator)
	// Every generated line that copies authored code has an entry at its
	// start that names the authored line with the same text.
	checked := 0
	for needle in ([]string{"const é = 1;", "function later() {", "  throw new Error('é');", "}"}) {
		generated, original := -1, -1
		for line, index in lines {
			if strings.has_prefix(line, needle) {
				generated = index
			}
		}
		for line, index in source_lines {
			if strings.has_prefix(line, needle) {
				original = index
			}
		}
		if !testing.expectf(t, generated >= 0 && original >= 0, "missing %s", needle) {
			continue
		}
		found := false
		for entry in mapped.entries {
			if entry.generated_line == generated && entry.generated_column == 0 {
				found = true
				testing.expect_value(t, entry.original_line, original)
				testing.expect_value(t, entry.original_column, 0)
				testing.expect(t, jsx_test_mapping_matches(mapped.mappings, entry))
			}
		}
		testing.expectf(t, found, "no mapping for the line %s", needle)
		checked += 1
	}
	testing.expect_value(t, checked, 4)
	// Columns count UTF-16 code units, so the element after a two-byte letter
	// sits one column earlier than its byte offset.
	mark := strings.index(source, "<b/>")
	seen := false
	for entry in mapped.entries {
		if entry.source_start != mark {
			continue
		}
		seen = true
		testing.expect_value(t, entry.original_column, len("  throw new Error('é'); const b = ") - 1)
		testing.expect_value(t, entry.generated_column, len("  throw new Error('é'); const b = ") - 1)
	}
	testing.expect(t, seen)
	// Entries are ordered by generated position, as the mappings format needs.
	for i in 1 ..< len(mapped.entries) {
		a, b := mapped.entries[i - 1], mapped.entries[i]
		testing.expect(t, a.generated_line < b.generated_line || (a.generated_line == b.generated_line && a.generated_column < b.generated_column))
	}

	// A page template stages each component clone before emitting it. The
	// clone must not advance the generated position twice.
	page: jsx.Source_Map
	template, failure := jsx.compile_module(
		"function Badge(props) {\n  return <span>{props.count}</span>;\n}\nexport default function Page() {\n  return <main><Badge count={1}/></main>;\n}\nexport const after = 1;\n",
		"page.jsx",
		true,
		context.temp_allocator,
		nil,
		&page,
	)
	testing.expect_value(t, failure.message, "")
	testing.expect(t, template.supported)
	total := strings.count(template.javascript, "\n")
	for entry in page.entries {
		testing.expect(t, entry.generated_line <= total)
	}
	after_line := -1
	for line, index in strings.split_lines(template.javascript, context.temp_allocator) {
		if strings.has_prefix(line, "export const after = 1;") {
			after_line = index
		}
	}
	mapped_after := false
	for entry in page.entries {
		mapped_after ||= entry.generated_line == after_line && entry.original_line == 6
	}
	testing.expect(t, mapped_after)
}

@(test)
jsx_maps_a_generated_call_back_to_its_element :: proc(t: ^testing.T) {
	source := "const node = <em>{title}</em>;\n"
	mapped: jsx.Source_Map
	output, err := transform_jsx(source, "expr.jsx", context.temp_allocator, &mapped)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, mapped.version, 3)
	testing.expect_value(t, mapped.file, "expr.jsx")
	if !testing.expect(t, len(mapped.entries) > 0 && len(mapped.sources) == 1) {
		return
	}
	testing.expect_value(t, mapped.sources[0], "expr.jsx")
	mark := strings.index(source, "<em>")
	found := false
	for entry in mapped.entries {
		if entry.source_start != mark {
			continue
		}
		found = true
		origin := jsx_test_offset(source, entry.original_line, entry.original_column)
		generated := jsx_test_offset(output, entry.generated_line, entry.generated_column)
		if !testing.expect(t, origin == mark && generated >= 0 && generated < len(output)) {
			return
		}
		testing.expect(t, source[origin] == '<')
		testing.expect(t, strings.has_prefix(output[generated:], "__saba_jsx"))
		testing.expect(t, jsx_test_mapping_matches(mapped.mappings, entry))
	}
	testing.expect(t, found)

	_, failure := transform_jsx("<p></div>", "broken.jsx", context.temp_allocator)
	testing.expect_value(t, failure.file, "broken.jsx")
	testing.expect(t, failure.line >= 1 && failure.column >= 1)
	testing.expect(t, failure.message != "")
}

jsx_test_offset :: proc(text: string, line, column: int) -> int {
	at := 0
	row := 0
	for at < len(text) && row < line {
		if text[at] == '\n' {
			row += 1
		}
		at += 1
	}
	return at + column
}

// Decode the whole mappings string with its running deltas and look for a
// segment that maps the entry's generated position to its original position.
jsx_test_mapping_matches :: proc(mappings: string, entry: jsx.Source_Entry) -> bool {
	at := 0
	line, column, original_line, original_column := 0, 0, 0, 0
	for at < len(mappings) {
		switch mappings[at] {
		case ';':
			line += 1
			column = 0
			at += 1
			continue
		case ',':
			at += 1
			continue
		}
		column += jsx_test_vlq(mappings, &at)
		if jsx_test_vlq(mappings, &at) != 0 {
			return false
		}
		original_line += jsx_test_vlq(mappings, &at)
		original_column += jsx_test_vlq(mappings, &at)
		if line == entry.generated_line &&
		   column == entry.generated_column &&
		   original_line == entry.original_line &&
		   original_column == entry.original_column {
			return true
		}
	}
	return false
}

jsx_test_vlq :: proc(text: string, at: ^int) -> int {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	value := 0
	shift := uint(0)
	for at^ < len(text) {
		digit := strings.index_byte(alphabet, text[at^])
		at^ += 1
		if digit < 0 {
			return 0
		}
		value |= (digit & 31) << shift
		shift += 5
		if digit & 32 == 0 {
			break
		}
	}
	if value & 1 == 1 {
		return -(value >> 1)
	}
	return value >> 1
}

@(test)
page_generation_gives_different_bytes_different_hashes :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "saba-hash-test-*", context.allocator)
	if !testing.expect(t, dir_err == nil) {
		return
	}
	defer delete(dir)
	defer os.remove_all(dir)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	write_page :: proc(dir, name, label: string) -> string {
		path := fmt.tprintf("%s/%s", dir, name)
		source := fmt.tprintf(
			"export const title = '%s'; export default function App() {{ return <p>%s {{mark%s()}}</p> }}",
			label,
			label,
			label,
		)
		assert(os.write_entire_file(path, transmute([]u8)source) == nil)
		return path
	}
	alpha_path := write_page(dir, "alpha.jsx", "Alpha")
	beta_path := write_page(dir, "beta.jsx", "Beta")
	page_mount :: proc(path: string, allocator: mem.Allocator) -> Page_Mount {
		variants := make([]Template_Variant, 1, allocator)
		variants[0] = {
			language = "en",
			module_url = "/ui/app.js",
			source_file = path,
			recovery_label = "Reload",
		}
		pages := make([]Compiled_Page, 1, allocator)
		pages[0] = {
			path = "/",
			variants = variants,
		}
		return {
			templates = {pages = pages},
		}
	}
	alpha_cache, alpha_ok := prepare_pages(page_mount(alpha_path, allocator), false, allocator)
	beta_cache, beta_ok := prepare_pages(page_mount(beta_path, allocator), false, allocator)
	alpha := alpha_cache.build
	beta := beta_cache.build
	if !testing.expect(t, alpha_ok && beta_ok, "page generation failed") {
		return
	}
	alpha_doc, alpha_found := alpha.documents["/"]
	beta_doc, beta_found := beta.documents["/"]
	if !testing.expect(t, alpha_found && beta_found) {
		return
	}
	alpha_html, alpha_lang := alpha_doc.variants["en"]
	beta_html, beta_lang := beta_doc.variants["en"]
	if !testing.expect(t, alpha_lang && beta_lang) {
		return
	}
	testing.expect(t, string(alpha_html.body) != string(beta_html.body))
	testing.expect(t, alpha_html.tag != beta_html.tag)

	Hash_Item :: struct {
		body: string,
		tag:  [66]u8,
	}
	items := make([dynamic]Hash_Item, allocator)
	append(&items, Hash_Item{string(alpha_html.body), alpha_html.tag})
	append(&items, Hash_Item{string(beta_html.body), beta_html.tag})
	for _, file in alpha.files {
		append(&items, Hash_Item{string(file.body), file.tag})
	}
	for _, file in beta.files {
		append(&items, Hash_Item{string(file.body), file.tag})
	}
	if !testing.expect(t, len(items) >= 4) {
		return
	}
	differed := false
	for i in 0 ..< len(items) {
		for j in i + 1 ..< len(items) {
			if items[i].body != items[j].body {
				differed = true
				testing.expect(t, items[i].tag != items[j].tag)
			} else {
				testing.expect(t, items[i].tag == items[j].tag)
			}
		}
	}
	testing.expect(t, differed)
}

@(test)
jsx_direct_holes_keep_plain_links :: proc(t: ^testing.T) {
	for source in ([]string{
			`function Field(on) { return <div>{on() ? <button formaction="/items/7">y</button> : null}</div>; }`,
			`function Field(on) { return <div>{on() ? <button formaction="https://example.test/a?b=1">y</button> : null}</div>; }`,
			// An expression inside a component child is built when it runs.
			`function Field(on) { return <Guard>{() => <div>{on() ? <b>x</b> : null}</div>}</Guard>; }`,
		}) {
		output := jsx_compiled(t, source, "hole-kept.jsx")
		testing.expectf(t, strings.contains(output, "__saba_paint"), "no direct hole for %s", source)
	}
}

@(test)
jsx_takes_every_spelling_of_an_element_event_as_a_handler :: proc(t: ^testing.T) {
	element := jsx_compiled(
		t,
		`function B(props) { return <button onclick={props.onSelect} ONKEYDOWN={pick(1)} onClick={props.go} title={props.title}/>; }`,
		"events.jsx",
	)
	testing.expect(t, strings.contains(element, `"onclick": (props.onSelect)`))
	testing.expect(t, strings.contains(element, `"ONKEYDOWN": (pick(1))`))
	testing.expect(t, strings.contains(element, `"onClick": (props.go)`))
	testing.expect(t, strings.contains(element, `"title": __saba_binding(() => (props.title))`))

	// A component prop is an event only in the onName form.
	component := jsx_compiled(t, `function P(props) { return <Status online={props.up()} onChange={props.change}/>; }`, "props.jsx")
	testing.expect(t, strings.contains(component, `__saba_liveProp("online", () => (props.up()))`))
	testing.expect(t, strings.contains(component, `"onChange": (props.change)`))
}

@(test)
jsx_counts_brackets_after_an_apostrophe :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "function List(props) {\n  return <ul>\n")
	for _ in 0 ..< 300 {
		strings.write_string(&b, "    {props.items.map(item => <li>Don't stop {item}</li>)}\n")
	}
	strings.write_string(&b, "  </ul>;\n}\n")
	_, err := transform_jsx(strings.to_string(b), "apostrophes.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
}

@(test)
jsx_keeps_a_mount_with_jsx_in_its_signature_on_the_runtime :: proc(t: ^testing.T) {
	row := "import { keyed, mount, signal } from '/__saba/dom.js';\nfunction Row(record) {\n  return <div class=\"card\" data-id={record().id}>{record().a ? <b>x</b> : null}<span>mid {`${record().t}`}</span></div>;\n}\n"
	body := " {\n  const rows = signal(records);\n  const list = keyed(rows, row => row.id, Row);\n  const dispose = mount(host, () => <>{list}</>);\n  return { replace: rows.set, dispose };\n}\n"
	plain := jsx_compiled(t, strings.concatenate({row, "export function mountBand(host, records)", body}, context.temp_allocator), "mount.jsx")
	testing.expect(t, jsx_lowered(plain))
	defaulted := jsx_compiled(
		t,
		strings.concatenate({row, "export function mountBand(host, records, extra = <b/>)", body}, context.temp_allocator),
		"mount-default.jsx",
	)
	testing.expect(t, !jsx_lowered(defaulted))
}

@(test)
jsx_text_lines_end_at_any_newline_and_keep_no_break_spaces :: proc(t: ^testing.T) {
	testing.expect_value(t, jsx.jsx_clean_text("a\rb"), "a b")
	testing.expect_value(t, jsx.jsx_clean_text("\r\n  Hello\r\n  world\r\n"), "Hello world")
	testing.expect_value(t, jsx.jsx_clean_text("\n  Hello\n  \u00a0\n"), "Hello \u00a0")
	testing.expect_value(t, jsx.jsx_clean_text("  one line  "), "  one line  ")
	testing.expect_value(t, jsx.jsx_clean_text("\n\t \n"), "")
}

@(test)
jsx_reports_deep_element_nesting_at_the_element :: proc(t: ^testing.T) {
	nest :: proc(open: string, count: int, inner, close: string) -> string {
		return strings.concatenate(
			{strings.repeat(open, count, context.temp_allocator), inner, strings.repeat(close, count, context.temp_allocator)},
			context.temp_allocator,
		)
	}
	// 128 levels compile. One more is reported at the element that exceeds
	// the limit, however much deeper the source goes: the analyses that run
	// before emission stop at the same depth, and their working memory is
	// not the parser's fixed arena.
	fine := jsx_compiled(t, strings.concatenate({"const a = ", nest("<div>", 128, "x", "</div>"), ";"}, context.temp_allocator), "nest-128.jsx")
	testing.expect_value(t, strings.count(fine, `("div", {}`), 128)
	for count in ([]int{129, 300, 600, 1000}) {
		for shape in ([][3]string {
				{"const a = ", "x", ";"},
				// A row function: the closed-row analysis walks it first.
				{"import { keyed, mount, signal } from '/__saba/dom.js';\nfunction Row(record) { return ", "{record().id + ''}", "; }\n"},
				// Every level could host a direct hole.
				{"function C(on) { return ", "{on() ? <b>x</b> : null}", "; }"},
			}) {
			source := strings.concatenate({shape[0], nest("<div>", count, shape[1], "</div>"), shape[2]}, context.temp_allocator)
			_, err := transform_jsx(source, "nest.jsx", context.temp_allocator)
			testing.expectf(t, err.message == "JSX nesting exceeds 128 levels", "%d levels after %q: %s", count, shape[0], err.message)
			lines := strings.count(shape[0], "\n")
			column := len(shape[0]) - (strings.last_index(shape[0], "\n") + 1) + 5 * 128 + 1
			testing.expect_value(t, err.line, lines + 1)
			testing.expect_value(t, err.column, column)
		}
		// A hole at every level, which made every element a host candidate.
		holes := strings.concatenate(
			{"function C(on) { return ", nest("<div>{on() ? <b>x</b> : null}", count, "", "</div>"), "; }"},
			context.temp_allocator,
		)
		_, err := transform_jsx(holes, "nest-holes.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "JSX nesting exceeds 128 levels", "%d hole levels: %s", count, err.message)
		// A page template walks its root element by itself.
		_, failure := jsx.compile_page_template(
			strings.concatenate({"export default function Page() { return ", nest("<div>", count, "x", "</div>"), "; }"}, context.temp_allocator),
			"nest-page.jsx",
			context.temp_allocator,
		)
		testing.expectf(t, failure.message == "JSX nesting exceeds 128 levels", "%d template levels: %s", count, failure.message)
	}
	// Text that starts in column zero resets the estimate that runs before
	// the parser, so these reach the emitter and its analyses with the whole
	// tree. They stop at the same element: as plain elements, and below a
	// direct-hole host whose static children are analysed first.
	for count in ([]int{129, 300, 500}) {
		plain := strings.concatenate({"const a = (\n", nest("<div>\nx\n", count, "", "</div>\n"), ");"}, context.temp_allocator)
		_, err := transform_jsx(plain, "nest-text.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "JSX nesting exceeds 128 levels", "%d text levels: %s", count, err.message)
		testing.expect_value(t, err.line, 2 + 2 * 128)
		testing.expect_value(t, err.column, 1)
		hosted := strings.concatenate(
			{"function C(on) { return (\n<section>{on() ? <b>y</b> : null}\n", nest("<div>\nx\n", count, "", "</div>\n"), "</section>); }"},
			context.temp_allocator,
		)
		_, held := transform_jsx(hosted, "nest-host.jsx", context.temp_allocator)
		testing.expectf(t, held.message == "JSX nesting exceeds 128 levels", "%d hosted levels: %s", count, held.message)
		testing.expect_value(t, held.line, 3 + 2 * 127)
	}
	// Far deeper input is refused the same way, at the same element.
	for count in ([]int{5000, 10000, 100000}) {
		source := strings.concatenate({"const a = ", nest("<div>", count, "x", "</div>"), ";"}, context.temp_allocator)
		_, err := transform_jsx(source, "nest-deep.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "JSX nesting exceeds 128 levels", "%d levels: %s", count, err.message)
		testing.expect_value(t, err.line, 1)
		testing.expect_value(t, err.column, len("const a = ") + 5 * 128 + 1)
		multiline := strings.concatenate({"const a = (\n", nest("  <div>\n", count, "x\n", "  </div>\n"), ");"}, context.temp_allocator)
		_, lined := transform_jsx(multiline, "nest-lines.jsx", context.temp_allocator)
		testing.expectf(t, lined.message == "JSX nesting exceeds 128 levels", "%d lines: %s", count, lined.message)
		testing.expect_value(t, lined.line, 130)
		testing.expect_value(t, lined.column, 3)
	}
}

@(test)
jsx_reports_a_long_chain_without_overflow :: proc(t: ^testing.T) {
	// 150,000 terms as an element's only child, in a row function and in a
	// hole's condition. Each used to reach a helper that recursed once per
	// term; the pinned parser's checker overflows on such a chain as well, so
	// the source is refused before it is parsed.
	for shape in ([][3]string {
			{"const a = <p>{", "1+", "1}</p>;"},
			{"const a = <p title={", "x.y+", "''}>z</p>;"},
			{"function Row(record) { return <div>{", "record().a+", "''}</div>; }"},
			{"function C(on) { return <div>{", "on.a&&", "on() ? <b>x</b> : null}</div>; }"},
			{"const total = ", "a.b.c(1)+", "1;\nconst a = <p/>;"},
		}) {
		source := strings.concatenate({shape[0], strings.repeat(shape[1], 150000, context.temp_allocator), shape[2]}, context.temp_allocator)
		_, err := transform_jsx(source, "chain.jsx", context.temp_allocator)
		testing.expectf(t, err.message == "Expression nesting is too deep to compile", "%s: %s", shape[1], err.message)
		testing.expect_value(t, err.line, 1)
		testing.expect(t, err.column > len(shape[0]))
	}
}

@(test)
jsx_nesting_estimate_ignores_text_templates_and_comments :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	// JSX text is not code. Apostrophes and unbalanced brackets in it, on
	// hundreds of lines of one expression, say nothing about nesting.
	strings.write_string(&b, "function Notes(props) {\n  return <ul>\n")
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "    <li>Don't (really [ask :( #%d {{props.items.map(item => <b>it's {{item.name}} [</b>)}} and so on (</li>\n", i)
	}
	strings.write_string(&b, "  </ul>;\n}\n")
	// Neither is the text of a template literal, nor a comment.
	strings.write_string(&b, "function sql(id) {\n  return [\n")
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "    `select ((( from t%d where a > [ and b = ${{id}} -- it's (`, // ((( [[[ {{{{ don't\n", i)
		strings.write_string(&b, "    /* ((( [[[ */ 1,\n")
	}
	strings.write_string(&b, "  ];\n}\n")
	// Thousands of tags and comparisons in one expression are not a chain.
	strings.write_string(&b, "function Table(rows) {\n  return <table><tbody>\n")
	for i in 0 ..< 6000 {
		fmt.sbprintf(&b, "    <tr><td>%d</td><td>{{rows.a > rows.b ? rows.a : rows.b}}</td></tr>\n", i)
	}
	strings.write_string(&b, "  </tbody></table>;\n}\n")
	// A long text and a long template literal full of operator characters.
	strings.write_string(&b, "const prose = <p>")
	strings.write_string(&b, strings.repeat("a - b / c. d = e + f: ", 3000, context.temp_allocator))
	strings.write_string(&b, "</p>;\nconst blob = `")
	strings.write_string(&b, strings.repeat("+/=-.<>", 6000, context.temp_allocator))
	strings.write_string(&b, "`;\n")
	output, err := transform_jsx(strings.to_string(b), "text.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, strings.contains(output, `"Don't (really [ask :( #399 "`))
	jsx_node_check(t, "text.jsx", output)

	// Real nesting is still counted where text and code meet: inside an
	// expression among the children, inside a template's interpolation, after
	// an apostrophe, and after a comparison.
	deep := strings.repeat("(", 300, context.temp_allocator)
	shut := strings.repeat(")", 300, context.temp_allocator)
	for source in ([]string {
			strings.concatenate({"const a = <p>Don't {", deep, "1", shut, "}</p>;"}, context.temp_allocator),
			strings.concatenate({"const a = `it's ${", deep, "1", shut, "}`;\nconst b = <p/>;"}, context.temp_allocator),
			strings.concatenate({"const a = b > ", deep, "1", shut, ";\nconst c = <p/>;"}, context.temp_allocator),
			strings.concatenate({"const a = <p title={", deep, "1", shut, "}>x</p>;"}, context.temp_allocator),
			strings.concatenate({"const a = <p>(</p>;\nconst b = <i>{", deep, "1", shut, "}</i>;"}, context.temp_allocator),
		}) {
		_, deep_err := transform_jsx(source, "deep.jsx", context.temp_allocator)
		testing.expectf(t, deep_err.message == "Nesting exceeds 256 levels of brackets", "%s: %s", source[:24], deep_err.message)
	}
}

@(test)
template_static_attributes_are_escaped_renamed_and_never_saba_markers :: proc(t: ^testing.T) {
	source :: `export const title = "Attributes";
export default function Page() {
  return <main><label htmlFor="name" title='say "hi"' data-saba-node="forged" data-Saba-instance="forged" data-note="kept">Name</label></main>
}`
	page, err := jsx.compile_page_template(source, "attributes.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expect(t, page.supported)
	testing.expectf(t, strings.contains(page.html, `title="say &quot;hi&quot;"`), "%s", page.html)
	testing.expectf(t, strings.contains(page.html, `for="name"`), "%s", page.html)
	testing.expectf(t, strings.contains(page.html, `data-note="kept"`), "%s", page.html)
	testing.expectf(t, !strings.contains(page.html, "forged"), "%s", page.html)
}

@(test)
template_leaves_out_text_the_parser_would_foster_out_of_a_row :: proc(t: ^testing.T) {
	source :: `export const title = "Rows";
export default function Page() { return <table><tbody><tr>stray<td>cell</td></tr></tbody></table> }`
	page, err := jsx.compile_page_template(source, "rows.jsx", context.temp_allocator)
	testing.expect_value(t, err.message, "")
	testing.expectf(t, !strings.contains(page.html, "stray"), "%s", page.html)
}

@(test)
jsx_text_turns_a_tab_into_a_space :: proc(t: ^testing.T) {
	output := jsx_compiled(t, "const a = <p>one\ttwo</p>;", "tab.jsx")
	testing.expectf(t, strings.contains(output, `"one two"`), "%s", output)
}
