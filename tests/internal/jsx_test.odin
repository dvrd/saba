package server

import "core:fmt"
import "core:strings"
import "core:testing"

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
			`const node = __saba_jsx(__saba_Fragment, null, __saba_jsx(Card, {...(props),"count": (2),}), __saba_jsx("span", {}, (ok && __saba_jsx("b", {}, "Yes"))));`,
		},
		{
			`const node = <p>{/* comment */}Hello{' '}{name}</p>;`,
			`const node = __saba_jsx("p", {}, "Hello", (' '), (name));`,
		},
		{"const node = <p>\n  Hello\n  world\n</p>;", `const node = __saba_jsx("p", {}, "Hello world");`},
		{
			`const node = <div title="&#x1f389; &#233;">&lt;safe&gt;</div>;`,
			`const node = __saba_jsx("div", {"title": "\ud83c\udf89 é",}, "<safe>");`,
		},
		{
			`const node = <UI.Card value={{ nested: [1, 2] }}>{items.map((item) => <p>{item}</p>)}</UI.Card>;`,
			`const node = __saba_jsx(UI.Card, {"value": ({ nested: [1, 2] }),}, (items.map((item) => __saba_jsx("p", {}, (item)))));`,
		},
		{`export default <p>Default</p>;`, `export default __saba_jsx("p", {}, "Default");`},
	}

	for item in cases {
		output, error := transform_jsx(item.source, "test.jsx", context.temp_allocator)
		if !testing.expectf(t, error.message == "", "%s: %v", item.source, error) {
			continue
		}
		header := `import { jsx as __saba_jsx } from "/__saba/dom.js";` + "\n"
		if strings.contains(item.expected, "Fragment,") {
			header = `import { jsx as __saba_jsx, Fragment as __saba_Fragment } from "/__saba/dom.js";` + "\n"
		}
		testing.expect_value(t, output, fmt.tprintf("%s%s", header, item.expected))
	}
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

	output, error := transform_jsx("const value = `prefix ${<b>{name}</b>}`;", "template.jsx", context.temp_allocator)
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
		`<p>{...items}</p>`,
		`<p>{/* comment */ ...items}</p>`,
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

	_, error := transform_jsx("const x = (\n  <p>\n    <b></p>\n);", "location.jsx", context.temp_allocator)
	testing.expect_value(t, error.line, 3)
	_, error = transform_jsx(strings.repeat("<p>", 140, context.temp_allocator), "deep.jsx", context.temp_allocator)
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
		testing.expect(t, strings.contains(output, `__saba_jsx_1("p", {})`), "calls use the imported alias")
	}

	output, error := transform_jsx(
		`function view(__saba_Fragment, __saba_jsx, __saba_jsx_1) { return <><i /></>; }`,
		"fragment.jsx",
		context.temp_allocator,
	)
	testing.expect_value(t, error.message, "")
	testing.expect(
		t,
		strings.has_prefix(output, `import { jsx as __saba_jsx_2, Fragment as __saba_Fragment_1 }`),
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
		strings.has_prefix(output, "#!/usr/bin/env node\nimport { jsx as __saba_jsx, Fragment as __saba_Fragment }"),
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
	output, error := transform_jsx(`export default <><p /></>;`, "page.jsx", context.temp_allocator)
	testing.expect_value(t, error.message, "")
	testing.expect(
		t,
		strings.has_prefix(output, `import { jsx as __saba_jsx, Fragment as __saba_Fragment } from "/__saba/dom.js";`),
		"JSX always imports the embedded runtime",
	)
}
