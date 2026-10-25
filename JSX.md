# JSX without a framework

Saba’s module pipeline lowers JSX to calls to `jsx` and `Fragment` internally.
Transformation errors report the filename, one-based line and column, and a
message. Configure `Server.modules` to enable processing; no separate transformer
API, Node, or npm dependencies are needed.

Saba owns the browser runtime in `javascript/dom.js`, embeds it into the
binary with `#load`, and serves it at `/__saba/dom.js` in development and production.
Applications do not create or copy a runtime file, configure its URL, or register
its route. This endpoint is reserved and takes precedence over application mounts.

The compiler injects `jsx` and, when needed, `Fragment` imports from that built-in
module, using aliases that avoid existing names across all scopes. Components do
not import these helpers manually. Imports for utilities such as `ref`, `run`, `mount`,
`onCleanup`, and `defineStyle` remain explicit and use the same built-in URL.
Existing imports are preserved; files without JSX acquire no runtime import.
The runtime uses `jsx(tag, properties, ...children)` and creates real DOM nodes.

JSX creates real DOM nodes once; variables are ordinary JavaScript variables. Update existing nodes explicitly.
There is no virtual DOM, reactive dependency tracking, automatic rerendering, or global state store.

Frontend ownership is explicit:

- `web/pages/`: one page module per public URL.
- `web/components/`: reusable JSX presentation and form components.
- `web/utils/`: requests, forms, navigation, and OAuth utilities.
- `web/assets/`: stylesheets, fonts, images, and licenses. Saba preloads this public
  directory through `Server.assets`; filenames supply their content types.

## File-based page routing

Saba discovers `.jsx` files beneath the configured page directory. Filenames and
directories determine the URL; `index.jsx` represents its directory’s root:

| File | URL |
| --- | --- |
| `web/pages/index.jsx` | `/` |
| `web/pages/login/index.jsx` | `/login` |
| `web/pages/login/email.jsx` | `/login/email` |
| `web/pages/events/index.jsx` | `/events` |
| `web/pages/events/new.jsx` | `/events/new` |

Each page has the same module contract:

```jsx
export const title = 'New event';

export default function NewEventPage() {
  return <h1>New event</h1>;
}
```

`web/index.html` contains one `<!--saba:page-->` placeholder. Saba replaces it with
an entry-script tag identifying the selected page module. Saba’s embedded `/__saba/page-entry.js` runtime
imports only that page, sets its title, and mounts its default component. There is
no application route list or browser page registry. Shared login/signup and email
screens remain components; their small page modules select their mode explicitly.

Unknown paths return `404`. `/index`, `/events/index`, and trailing-slash aliases
are not added. When `events.jsx` and `events/index.jsx` both exist, `/events` uses
`events/index.jsx`. This directory-index precedence is independent of discovery
order. Saba warns with the shared route, both source paths, and the selected file
so an accidental duplicate is visible; startup continues. Development discovers additions/deletions and
shell edits on each page request. Production snapshots routes, HTML, and compiled
modules at startup; restart to load changes. Page requests use GET and are served
before the application’s API router. Directory traversal, hidden paths, and files
outside the page root cannot become routes.

## Authoring a component

```jsx
import { ref, defineStyle } from '/__saba/dom.js';

export function Counter({ initial = 0 }) {
  defineStyle('counter', `.counter button { min-width: 3rem; }`);
  const label = ref('label');
  let count = initial;
  const increment = () => { label.current.textContent = String(++count); };

  return <div class="counter">
    <span ref={label}>{count}</span>
    <button type="button" onClick={increment}>Add one</button>
  </div>;
}
```

Mount with `mount(parent, Counter, { initial: 1 })`. It appends the component and
returns an idempotent disposal function. Each component has its own lifetime,
including nested components and content inserted later through `update`.
Disposal runs registered cleanup and removes the mounted nodes. Failed
construction also cleans up constructed descendants.

Function components receive properties and a `children` array. JSX expressions
create real DOM nodes once. Refs bind during construction; startup runs after
insertion. Use explicit updates when data changes.

`defineStyle(id, css)` installs a style element once. Reusing the ID with different
CSS throws. Styles remain for the document's lifetime. Scope selectors under a
component class; this does not rewrite selectors or introduce Shadow DOM. Shared
tokens and existing page styles remain in `auth.css`.

## Shared page components

`web/components/` contains individual files for `PageHeading`, `StatusNotice`,
`SettingsSection`, `ActionRow`, and `AccountLayout` alongside `AuthLayout`.
Use these to keep headings, accessible status messages, settings sections, and
rows consistent. Fields also have individual files: `EmailField.jsx`, `PasswordField.jsx`,
`TextField.jsx`, `CurrentPasswordField.jsx`, and `SubmitButton.jsx`. Each filename
matches its component name, with labels and field errors included.

Declare DOM event handlers on elements with event props. Define behavior as named
functions, then connect them using `onClick` or `onSubmit`:

```jsx
export function Example() {
  const actions = pageActions();
  const { request, notice } = actions;

  async function save(input) {
    await request('/api/example', { method: 'POST', body: input });
    notice('Saved.');
  }

  return <AuthLayout>
    <StatusNotice />
    <Form onSubmit={save} actions={actions}>
      <EmailField />
      <SubmitButton>Save</SubmitButton>
    </Form>
  </AuthLayout>;
}
```

`pageActions()` captures its component lifetime and locates the local status notice
when needed. Nested modules use `pageActions(parentActions)` for their own
cancellation handle while inheriting the parent transport and status notice.
`Form` owns submission behavior. Its `onSubmit(values, form)` callback receives
validated form values and the native form element. It trims email addresses,
prevents browser navigation and duplicate submissions, shows errors, and restores
busy state. Pass the page's `actions` for its cancellation handle and status notice.
Named refs, data attributes, and other form attributes are forwarded to its native
form root; `novalidate` is set internally so field errors use the shared UI.
It captures the form before awaiting, because native `event.currentTarget` is
cleared after dispatch. Native `<form onSubmit={...}>` retains browser event
semantics. Application forms use `Form`; there is no `submit` wrapper API. Field components use `onBlur` and `onInput` for validation
and own their password-toggle click handlers. There is no imperative form binding
API or secondary password-toggle binding.

Use `run(load)` from page actions for mounted async startup with status errors and `onClick={action(save)}` for async
buttons. `action` prevents duplicate clicks, reports errors, and restores the
button while the page is alive. Requests abort on disposal and notices from
cancelled work are suppressed. Continue checking `abort.aborted` after async work
that does not use `request`, such as Web Crypto. Pages and components declare event
props; native listener installation belongs to the DOM runtime. Non-DOM abort
listeners remain inside the request transport.

`web/utils/navigation.js` shares post-login destinations, provider names, fragment-token
removal, and link-token shape checks. Pages still own endpoint selection,
confirmation rules, and their success behavior.

`readSessionData(key)` from `web/utils/storage.js` reads optional JSON session
state. Missing data, malformed JSON, and inaccessible storage return `null`;
callers explicitly test `value !== null` for presence and validate the decoded
value for their invitation or OAuth flow. The helper returns data, not a boolean.
Pages do not repeat storage parsing try/catch blocks. Malformed server JSON is an
API failure instead of optional state: `api` reports a readable response error,
which `Form`, `run`, and `action` display through the shared status notice.

`writeSessionData(key, value)` serializes JSON and saves it to session storage.
It returns no value. If saving fails, it throws a readable error for `run`,
`action`, or `Form` to display. Required state must be saved before continuing
OAuth or invitation flows; failed writes are not silently ignored.

```js
writeSessionData('app.group-invite', { token, created: Date.now() });
```

`queryParams()` from `web/utils/navigation.js` returns `URLSearchParams` for
both the query string and hash. Hash values take precedence for `get`; repeated
values are retained for `getAll`. Use `queryParams('search')` or
`queryParams('hash')` when a flow requires a specific source. OAuth reads the
query string; `takeLinkToken` reads and clears fragment tokens.

```js
const token = queryParams().get('token');
const deliveryFailed = queryParams().get('sent') === '0';
```

## Component refs and execution order

Declare refs before returning JSX. Each ref is a stable object with a read-only
`current` property: `null` before binding, the native element after construction,
and `null` again when that element or its owning component is disposed.

```jsx
import { ref, run, update } from '/__saba/dom.js';
import { api } from '../utils/api.js';

export function EventSettings() {
  const events = ref('events');

  run(async ({ abort }) => {
    const items = await api('/api/v1/events', { abort });
    if (abort.aborted) return;
    update(events, items.map(item => <p>{item.title}</p>));
  });

  return <section ref={events}>Loading events…</section>;
}
```

The lifecycle is explicit:

1. Call the component synchronously. It declares refs and registers startup work.
2. Construct its returned JSX and bind object refs. No startup work runs yet.
3. Insert its DOM through `mount` or `update`.
4. Start registered `run` callbacks in microtasks, after insertion and ref binding.
   Callbacks receive their component's lifetime abort handle. Separate tasks can overlap.
5. Replacing or disposing the component aborts that handle, runs its cleanup,
   disposes descendants, and clears refs. Pending startup tasks never execute.

Components return JSX directly. There is no public `view` helper or `pageLifetime`
wrapper. A component must return a DOM node or fragment synchronously; an async
component is rejected. Arrays are supported as JSX children and `update` content.

`ref(name)` must run during component construction. Names are nonempty JavaScript
identifiers, unique within that component instance; different instances can reuse
names. Bind with `ref={reference}`. String refs, callback refs, ordinary objects,
and duplicate bindings are rejected. Component refs identify their returned root
element; `ref` is reserved and is not passed as a component prop. A fragment cannot
be a ref target. Pass a ref under an explicit prop such as `formRef` when a child
needs to bind an element for its parent.

For several refs, use `uiRefs(...names)` to create a read-only object of named refs:

```jsx
const ui = uiRefs('group', 'events');
// Bind with ref={ui.group}; update with update(ui.events, content).
```

Each property contains the corresponding `ref(name)`. `uiRefs` uses the same
component ownership, name validation, duplicate checks, and cleanup as `ref`.
Use `ref(name)` for one ref and `uiRefs(...names)` for grouped UI refs.

`run` starts once the returned content is connected. A callback may return a cleanup
function, including after an `await`. If the component was disposed while awaiting,
that cleanup runs immediately when it arrives. `onCleanup` registers synchronous
cleanup during construction. External work must use the lifetime abort handle or its
registered cleanup; aborting a lifetime does not stop arbitrary JavaScript.
`lifetime()` exposes the current component's `abort`, lazy `root`, and bound `run`
for shared utilities such as `pageActions`. Call it during construction.

`update`, `show`, `hide`, and `mount` accept either an element or a bound ref.
Pass refs directly; the runtime resolves them internally. An unbound or disposed
ref throws a descriptive error. Use `.current` only for native DOM properties and
methods, such as `input.current.value` or `input.current.focus()`.

`show(element, condition)` and `hide(element)` update visibility explicitly.
`update(target, content)` replaces a region with a JSX node, arrays, text, or `null`.
It disposes removed components and starts newly inserted components. It preserves
the target element and its owner's lifetime. Use these runtime operations for
component removal; direct native DOM removal does not trigger runtime cleanup.

```jsx
update(ui.providers, <Providers config={config} actions={actions} />);
update(ui.events, events.length ? events.map(renderEvent) : 'No events yet.');
update(ui.content, null);
```

`AccountPage` returns its loading shell, then `run(initialize)` checks the session
and fetches the account. `update` inserts `AccountView`, whose own startup loads
sessions. `GroupSettings` and `EventSettings` independently load their data after
insertion. Each owns its refs; the page does not reach into their private markup.
Functions defined in a component are ordinary JavaScript functions. Event handlers
execute on events; `run` callbacks execute after mounting. Data changes do not
rerun components automatically.


## Supported syntax and DOM behavior

- HTML tags, custom element tags, function components, member components such as
  `UI.Button`, and fragments (`<>...</>`; the compiler imports `Fragment` automatically).
- Quoted and boolean attributes, expression attributes, and ordered property
  spreads (`<Button {...properties} disabled />`). JavaScript imports stay intact.
- Expression children, nested JSX, arrays, conditionals, and comment-only children.
  Strings and numbers become text nodes; null, undefined, and booleans are ignored.
  Interpolated strings never become HTML. Raw HTML properties are rejected.
- `class`/`className`, `for`/`htmlFor`, native HTML attributes, input properties,
  string-valued ARIA/data attributes, style strings or objects, direct `onClick`
  style event handlers, and named object refs created with `ref(name)`. Style object numbers need explicit units
  where CSS requires them. Use refs for event options or custom case-sensitive events.
- JSX text trims indentation across lines while retaining single-line spacing.
  Entities support `amp`, `lt`, `gt`, `quot`, `apos`, and numeric Unicode values.
  Prefer literal Unicode for other symbols.

The transformer scans JavaScript lexical contexts (strings, comments, regex
literals, balanced groups, and template interpolations). It is not a full
JavaScript validator or TypeScript compiler. JavaScript syntax errors remain the
browser's responsibility. There is a 128-level nesting limit. SVG/MathML,
namespaced tags, spread children, source maps, SSR, hydration, and bundling are
outside this first version.

## Development and production

Saba owns the module pipeline. Configure directories on the server:

```odin
server.serve(server.Server {
    handler = routes,
    assets = {{directory = "web/assets"}},
    modules = {{directory = "web"}},
    pages = {
        directory = "web/pages",
        shell = "web/index.html",
        module_prefix = "/pages/",
    },
    development = DEV_MODE,
    hot_reload_directory = "web",
})
```

Any `.jsx` file, including nested components, is available at the corresponding
`.js` URL. For example, `web/components/Button.jsx` is imported as
`/components/Button.js`. `web/pages/events/new.jsx` is served as the module
`/pages/events/new.js` and also defines the HTML route `/events/new`. Keep imports ending in `.js`. Ordinary JavaScript files
use the same mount. No file list, router call, or separate asset command is needed.
Use `prefix = "/components/"` with `directory = "web/components"` for a subtree.

Development transforms JSX on each request, sends `no-store`, and reports source
locations for errors. New files are discovered automatically, and the existing
web-directory watcher reloads pages after edits.

Production recursively preprocesses JSX and loads JavaScript into an immutable
server-owned cache **before opening the listener**. Invalid JSX, unreadable
modules, or `.jsx`/`.js` output collisions prevent startup. Source files remain
untouched: Saba writes no generated files and requires no output directory.
Restart the server to load updated production modules. The cache lives until all
connection workers finish, so requests do not borrow temporary build storage.

Deploy your application's `web/` directory alongside its binary. Set the
`Server` module, asset, and page directory paths to the deployed locations.
HTML routes use the page mount and `web/index.html` shell. CSS, fonts, and images
use the asset mount, with content types inferred from their extensions. Raw JSX,
dot paths, traversal, and links outside the module directory are not exposed.
Saba does not bundle or execute JavaScript. The transformer is an internal part of Saba.

## Verification

From the Saba repository root:

```sh
odin test . -warnings-as-errors
```

These tests cover the JSX transformer. Applications should additionally exercise
their components and page flows in a browser against their own test server.
