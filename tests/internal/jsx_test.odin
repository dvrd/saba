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
	testing.expect(t, strings.contains(output, `__saba_registerSlotRow_1(Tile, {tag:"div", attrs:{"class":"tile & cell",}, fields:["id","score"], write(element, text, row) { element.setAttribute("data-id", row["id"]); text.data = row["id"] + ' · ' + (row["score"] + 1); }});`))
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

// A row the proof accepts: the mount is a thin wrapper over a direct loop and
// nothing of the keyed runtime is left.
jsx_expect_lowered :: proc(t: ^testing.T, source, label: string) -> string {
	output := jsx_compiled(t, source, label)
	testing.expectf(t, jsx_lowered(output), "%s was not lowered", label)
	testing.expectf(t, !strings.contains(output, "keyed("), "%s still calls keyed", label)
	testing.expectf(t, !strings.contains(output, "mountSlotWindow("), "%s still calls mountSlotWindow", label)
	testing.expectf(t, !strings.contains(output, "function Row("), "%s kept its unused row", label)
	return output
}

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
	testing.expect(t, !strings.contains(output, "/__saba/dom.js"))
	testing.expect(t, !strings.contains(output, "registerSlotRow"))
	// The authored signature survives and delegates.
	testing.expect(t, strings.contains(output, "export function mountBand(host, records) {\n  return __saba_list0(host, records);\n}"))
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
}

@(test)
jsx_lowers_a_proved_slot_window :: proc(t: ^testing.T) {
	output := jsx_expect_lowered(
		t,
		slot_module(
			`<div class="cell" data-id={record().element} title={record().text + ''}>{record().text + ' · ' + record().element}</div>`,
			`export function mountBand(host, records, first = 5) {
  const view = mountSlotWindow(host, Row);
  const replace = (next, nextFirst = 7) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}`,
		),
		"slot.jsx",
	)
	testing.expect(t, !strings.contains(output, "/__saba/slot-window.js"))
	// The author's defaults are kept, not rewritten.
	testing.expect(t, strings.contains(output, "export function mountBand(host, records, first = 5) {\n  return __saba_list0(host, records, first);\n}"))
	testing.expect(t, strings.contains(output, "function replace(next, nextFirst = 7) {"))
	// Record fields named like the slot's own members are stored by index.
	testing.expect(t, strings.contains(output, "return { element, text, f0: globalThis.NaN, f1: globalThis.NaN };"))
	testing.expect(t, strings.contains(output, `view[i] = { element, text, f0: row["element"], f1: row["text"] };`))
	testing.expect(t, !strings.contains(output, "element: row"))
	testing.expect(t, !strings.contains(output, "text: row"))
	write := jsx_between(output, "function __saba_write0(", "function __saba_mountFresh0(")
	testing.expect(t, strings.contains(write, `__saba_attr0(slot.element, "data-id", row["element"], true);`))
	testing.expect(t, strings.contains(write, `slot.element.setAttribute("title", row["text"] + '');`))
	testing.expect(t, strings.contains(write, `slot.f0 = row["element"];`))

	// A replace without a literal default, or a checkbox row, stays on the
	// runtime window.
	jsx_expect_runtime(
		t,
		slot_module(
			`<div class="cell">{record().id + ''}</div>`,
			`export function mountBand(host, records, first = 0) {
  const view = mountSlotWindow(host, Row);
  const replace = (next, nextFirst) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}`,
		),
		"slot-no-default.jsx",
	)
}

@(test)
jsx_lowers_a_positional_checkbox_row :: proc(t: ^testing.T) {
	output := jsx_expect_lowered(
		t,
		keyed_module(`<input type="checkbox" checked={record().on} data-id={record().id} title={record().label} />`),
		"checkbox.jsx",
	)
	testing.expect(t, strings.contains(output, `globalThis.document.createElement("input")`))
	testing.expect(t, strings.contains(output, `element.checked = row["on"];`))
	testing.expect(t, !strings.contains(output, `setAttribute("checked"`))
	testing.expect(t, strings.contains(output, "globalThis.document.createDocumentFragment()"))
	// A position can change record, so the key attribute is rewritten too, and
	// the keys are validated although no cell map is kept.
	update := jsx_between(output, "const element = boxes[i];", "render();")
	testing.expect(t, strings.contains(update, `element.setAttribute("data-id", row["id"]);`))
	testing.expect(t, strings.contains(update, `__saba_attr0(element, "title", row["label"], false);`))
	testing.expect(t, strings.contains(update, "element.checked !== on"))
	testing.expect(t, strings.contains(output, `"Duplicate row key: "`))
	testing.expect(t, !strings.contains(output, "replaceChildren"))
	// The runtime writes a quoted checked through the live property.
	jsx_expect_runtime(t, keyed_module(`<input type="checkbox" checked="yes" data-id={record().id} />`), "checked-literal.jsx")
}

@(test)
jsx_lowers_tree_rows_with_media_and_holes :: proc(t: ^testing.T) {
	image := jsx_expect_lowered(t, keyed_module(`<img data-id={record().id} src={record().src} alt={record().alt} />`), "img.jsx")
	testing.expect(t, strings.contains(image, `globalThis.document.createElement("img")`))
	image_update := jsx_between(image, "cell.record !== row", "cell.record = row")
	testing.expect(t, strings.contains(image_update, `__saba_attr0(cell.element, "src", row["src"], false);`))
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
jsx_lowering_keeps_what_other_code_still_uses :: proc(t: ^testing.T) {
	row :: `<div data-id={record().id}>{record().id + ''}</div>`
	// An exported row is another module's import.
	exported, _ := strings.replace_all(keyed_module(row), "function Row(", "export function Row(", context.temp_allocator)
	kept := jsx_compiled(t, exported, "exported-row.jsx")
	testing.expect(t, jsx_lowered(kept))
	testing.expect(t, strings.contains(kept, "export function Row(record)"))
	testing.expect(t, strings.contains(kept, "__saba_registerSlotRow(Row,"))

	// A second reader of the row, and of signal, in code that is not lowered.
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
	// Only the specifiers no remaining code names are dropped.
	testing.expect(t, strings.contains(output, "import { signal } from '/__saba/dom.js';"))
	testing.expect(t, strings.contains(output, "import { computed as derived } from '/__saba/dom.js';"))
	testing.expect(t, !strings.contains(output, "import * as dom"))
	testing.expect(t, !strings.contains(output, "Default"))
	testing.expect(t, !strings.contains(output, "effect"))
	testing.expect(t, strings.contains(output, "export const total = signal(0);"))

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
	testing.expect(t, strings.contains(both, "import { keyed, mount, signal } from '/__saba/dom.js';"))
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
	testing.expect(t, strings.contains(output, "export function mountBand(before, cells = [], next) {\n  return __saba_list0_1(before, cells);\n}"))
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
	testing.expect(t, !strings.contains(pair, "/__saba/dom.js"))
	for name in ([]string{"__saba_list0(host", "__saba_list1(host", "__saba_create0(row)", "__saba_create1(row)", "__saba_move0(parent", "__saba_move1(parent"}) {
		testing.expect_value(t, strings.count(pair, fmt.tprintf("function %s", name)), 1)
	}
	testing.expect(t, strings.contains(pair, "return __saba_list0(host, people);"))
	testing.expect(t, strings.contains(pair, "return __saba_list1(host, tasks);"))
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
	source, read := os.read_entire_file("testdata/ui/lowered.jsx", context.temp_allocator)
	if !testing.expect(t, read == nil, "could not read testdata/ui/lowered.jsx") {
		return
	}
	output := jsx_compiled(t, string(source), "lowered.jsx")
	for name in ([]string{"flatDirect", "treeDirect", "boxDirect"}) {
		body := jsx_between(output, fmt.tprintf("export function %s(", name), "\n}")
		testing.expectf(t, strings.contains(body, "return __saba_list"), "%s is not lowered: %s", name, body)
	}
	testing.expect(t, strings.contains(output, "export function slotDirect(host, records, first = 0) {\n  return __saba_list3(host, records, first);"))
	testing.expect_value(t, strings.count(output, "function __saba_list"), 4)
	testing.expect(t, strings.contains(output, "let boxes = []"))
	testing.expect(t, strings.contains(output, "let slots = []"))
	testing.expect(t, strings.contains(output, "cell.h0"))
	testing.expect_value(t, strings.count(output, "__saba_paint(__saba_swap);"), 2)
	for name in ([]string{"flatRuntime", "treeRuntime", "boxRuntime", "slotRuntime"}) {
		body := jsx_between(output, fmt.tprintf("export function %s(", name), "\n}")
		testing.expectf(t, !strings.contains(body, "__saba_list") && strings.contains(body, "void 0;"), "%s left the runtime", name)
	}
	for name in ([]string{"FlatDirect", "TreeDirect", "BoxDirect", "SlotDirect"}) {
		testing.expectf(t, !strings.contains(output, fmt.tprintf("function %s(", name)), "%s was kept", name)
	}
	for name in ([]string{"FlatRuntime", "TreeRuntime", "BoxRuntime", "SlotRuntime", "PanelRuntime", "CardRuntime"}) {
		testing.expectf(t, strings.contains(output, fmt.tprintf("function %s(", name)), "%s is missing", name)
	}
	// The runtime twins still read every import.
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
