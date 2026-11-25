---
status: accepted
implementation: implemented for the synthetic item pilot
---

# An item editor owns its route, draft and validation errors

In this synthetic Saba acceptance case, a reader opens `/items/42` from a searchable list and changes the title. While they type, the list may reorder, another editor may save, or the server may reject the title. The editor must know which record the reader saw, what they submitted and which edits they made afterward.

## Deliver the page

The build produces one route table for the Odin page server and browser entry. Each entry identifies a pattern, HTML artifact and browser module from the same build. For the pilot, `items/index.jsx` maps to `/items` and `items/[id].jsx` maps to `/items/:id`. Links use ordinary document navigation. A direct visit, reload and link click select the same page.

Match whole path segments, excluding query and fragment. A literal wins over a parameter at the first differing segment, so `/items/new` wins over `/items/:id`. At build time reject overlapping patterns with identical literal segments and parameter positions, repeated or invalid parameter names, and patterns exceeding Odin’s eight captures. A parameter consumes one nonempty segment. Split before decoding each segment once as UTF-8. Malformed escapes, invalid UTF-8, or a decoded slash or backslash cannot select a page. Both matchers follow the declared trailing slash. The pilot registers only the slashless editor URL. [Existing request matcher](../../src/core/request.odin)

For `GET /items/42` the server sends the editor’s compiled HTML and external module reference. The browser entry passes immutable params to the page component (`props.params.id === "42"`) and opens its scope. Every item ID uses the same template, with blank, disabled controls. The editor requests `GET /api/items/42`. Its Odin handler authorizes the request and returns a record such as `{"id":"42","revision":7,"title":"Lamp"}`. [Compile-time delivery](0004-saba-compile-time-html-no-request-rendering.md)

## Edit and save

The first successful authorized read initializes a clean draft at revision 7. Keep the baseline record that the user edited, the latest confirmed record, the local draft and per-field edit versions. A clean editor can adopt a newer read. A dirty editor keeps its draft and original base revision and offers the newer record for review. Ignore older revisions. An input that returns to its baseline value is clean, but its edit version still advances. Each keyed row owns its editor scope, so reordering a row preserves its input, focus and draft. [DOM identity](0002-saba-ui-signals-with-incremental-borrowings.md)

The form’s submit handler prevents native submission, checks eligibility, validates and snapshots its item ID, draft, edit versions and base revision. Enter and the Save button use the same handler. One editor admits one outstanding save for its item. It sends, for example, `PATCH /api/items/42` with `{"operationId":"save-17","expectedRevision":7,"title":"Desk lamp"}`. The server checks authorization and revision and records the outcome according to the mutation contract. [Read and mutation ownership](0006-saba-async-reads-and-mutations.md)

| Reply to this submission | Effect on its live editor |
| --- | --- |
| 200 with `{"id":"42","revision":8,"title":"Desk lamp"}` | Settle this operation. With revision 8 current, adopt its canonical baseline, update fields whose edit versions still match, and preserve later edits. If revision 9 is already confirmed, keep 9 current. If no local changes remain after acknowledging the submission, the editor adopts 9. Otherwise preserve the unsaved fields and review 9 against the acknowledged baseline of 8. |
| 422 with `{"fieldErrors":{"title":"Choose a different title."}}` | Keep the draft and base revision. Attach a message only if the submitted revision is still current and the versions of all fields on which its rule depends still match the submission. Mark its input `aria-invalid` and add the message ID to `aria-describedby`. Within the active submitting form, focus the first applicable invalid field in DOM order. |
| 409 with `{"revision":9}` | Settle this operation, preserve the draft and request the latest authorized record. Show the base, draft and latest values. A fresh operation can use the reviewed revision after the user resolves differences and submits again. |
| 409 with `{"code":"operation_id_reused"}` | The server rejected these submission bytes because this identifier already belongs to different input. End this attempt, keep the draft and report the identifier collision. The other operation retains its own journal entry and receipt. An explicit new submit after an authorized refresh allocates a fresh ID. |

## Leave and return

Every exit revokes the editor’s permission to publish and releases its resource subscriptions. A save already dispatched may have committed. Persist its recovery identifier before dispatch as specified in ADR 0006. A full document exit disposes the editor. When `pagehide` fires with `event.persisted === true`, hide private values and disable the form before suspension, retire its old subscriptions and preserve its in-memory draft. On a browser `pageshow` with the same flag, verify the current authenticated session and tenant with the server before looking up a receipt. Reacquire an authorized record under fresh ownership before revealing preserved data. Keep Save locked until outstanding operations and the latest record have been reconciled. If a sibling's receipt lookup settles this editor's operation while recovery is reading the baseline, recovery applies that outcome after the read instead of dropping it. [Mutation recovery](0006-saba-async-reads-and-mutations.md) · [HTML page transition events](https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-pagetransitionevent-interface)

A newly loaded document, including a reload or a history visit after eviction, starts with blank controls and reads the server record. Only operation recovery identifiers survive a full exit. Browser-restored input values cannot initialize a draft or supply its base revision. Verify the session against a fresh credentialed server response on restoration. The session check, protected record, mutation and receipt endpoints use private, no-store responses and bypass browser and application caches for that verification and baseline read. A failed identity check keeps the form hidden and locked until verification succeeds. A changed identity purges the previous partition, draft, errors and operation references and opens a fresh editor. Old callbacks have no authority to publish into it. A recovered 422 may settle a journal entry, but only a restored form with the original submission snapshot can apply its field messages.

## Route ownership

The framework owns its development endpoints, runtime and page entry. Reserve the framework namespace and the application’s declared handler paths and prefixes before matching assets, modules or pages. The pilot routes the entire `/api/` prefix to its Odin handler, including `/api/report.js` when modules are mounted at `/`. Reject overlapping explicit reservations owned by different handlers at configuration time. On the remaining paths, configured assets win, followed by matching module requests and then generated pages. A module mount at `/` claims module requests by extension. A missing asset, module or API stays with its owner and returns that owner’s error. [Current dispatch order](../../src/application/application.odin) · [Module matcher](../../src/modules/modules.odin)

For other paths, only GET and HEAD select a generated page. HEAD returns the GET status and representation headers with an empty body. A page miss or another method goes to the existing application dispatcher or handler. The pilot's fallback returns HTTP 404 for an unknown URL. A custom handler that needs to win over an otherwise matching generated route declares ownership when configuring the server. A matched editor URL still returns shared HTML when the item is missing. Its separate authorized API read determines the visible form state.

## When the form can act

| Event | What the reader can do |
| --- | --- |
| Initial load pending | Read the loading status. Fields and Save are disabled in the served HTML and throughout attachment. The submit handler also checks the state. |
| First load fails temporarily | See an error and retry the GET. Fields stay blank and disabled until the first successful read. |
| Authorized record loaded | Edit fields. Save becomes available for a dirty, locally valid draft with a known base and no outstanding review or operation. Local validation reports errors on input or attempted submission. |
| Refresh fails temporarily | Keep the existing draft, base and errors. Indicate that the record could not be refreshed and offer retry. An otherwise eligible editor can still save against its known revision. |
| Save pending | Continue editing. Duplicate submissions join the existing operation. Other editor instances have independent drafts and may submit against the same server revision. |
| Newer record during an edit, or 409 | Review the new record. Save stays disabled until review completes. A failed conflict refresh keeps the draft and offers a read retry. |
| Read or save reports an authorized deletion | Show “Item no longer exists” and disable mutations. Keep a dirty draft available to copy if the API explicitly confirms deletion for this authorized caller. |
| Record read or save returns 401, 403 or an opaque 404 | Clear private values, errors and any prior record display and lock the form. A 404 used to conceal access gets the same generic unavailable state as any other opaque 404. Recheck authorization before reopening. |
| Save response lost or indeterminate | Preserve the draft. Reconcile the operation under ADR 0006. A pending receipt keeps Save locked. A missing or expired receipt requires a fresh read and explicit review before another write. `canRetry()` is true only while this editor's own operation is the sole open one and the partition still holds its original bytes inside `retentionMs`; `retry()` then resends those bytes under the same ID. When the partition refuses, `retry()` sends nothing and resolves `{kind: "retry-unavailable"}`. |
| Session check fails on a persisted `pageshow` | The status is `unverified`. The form stays hidden and locked. `restore()` can be called again and repeats the check; there is no automatic retry. Without `verifyIdentity` the editor is always `unverified` after suspension. Once the same identity is verified, `restore()` reconciles receipts, then reads the baseline. On a locked editor `refresh()` runs that recovery again. |
| Journal storage cannot be read | Show the record with status `read-only`. Nothing can be edited or saved from this document, since it cannot know about or record an outstanding save. |
| A save reply or another editor's committed record lacks an edited field | Status `invalid-record`. The editor locks after its own reply; after another editor's commit it reads the whole record again. |

The application distinguishes an authorized deletion from a concealed miss in its response contract. For example, it may send 404 with `{"code":"item_deleted"}` after checking permission to disclose the deletion. A transient server or network error leaves the draft available only while the same authorized editor remains active.

During conflict review the user may discard the draft and adopt the current record, or take the current record as the new base and keep selected local changes. Show both values for each overlapping change. Carry forward server values for untouched fields. A newer revision invalidates any earlier review whenever unsaved changes remain, including after a review is accepted and before its save completes. Resolving the review never sends a request by itself. A later submit captures the reconciled fields and revision under a new operation ID.

A field error can depend on more than the field where it appears. By default its dependency set is the whole submitted draft. An application may declare a narrower set for a known rule, such as `[title]` for a title-only check. If several rules can produce the same field message, use the union of their inputs. Editing any dependency or adopting a newer server revision clears that message immediately. Map an unknown field to the form’s live status only while the submitted values are still current. Stale errors cause zero focus movement or announcements. Store IDs and field references per form instance and preserve existing description IDs. Move focus only if the submitting form still owns focus and the invalid target can receive it. If the user has moved elsewhere, show current messages in their original form and leave focus alone.

Two saves issued from revision 7 can yield one success and one conflict. A later save against revision 8 may reach the browser before the receipt for 8. Settle each submitting editor independently. For item 42 a successful mutation invalidates the exact detail key and the declared `items` collection family in the caller’s identity partition, including filtered lists the item may enter. The shared detail and an editor that has already observed revision 9 must keep 9 current throughout. [Resource invalidation and ordering](0006-saba-async-reads-and-mutations.md)

## What the application supplies

The application supplies a mutation partition for a freshly verified session and tenant, the editable fields and its validation rules. Each mounted form owns its own editor. The example below receives an already verified partition. The routed fixture also handles asynchronous identity verification before opening the editor. [Complete authored page](../../testdata/ui/item.jsx) · [Editor implementation](../../src/modules/editor.js)

```jsx
import {effect, ref, run} from "/__saba/dom.js"
import {createEditor} from "/__saba/editor.js"

function ItemForm({partition, item, verifyIdentity}) {
  const editor = createEditor({partition, item, fields: ["title"], verifyIdentity})
  const controls = ref("controls")
  const titleId = editor.fieldId("title")
  const helpId = titleId + "-help"
  run(() => {
    effect(() => { controls.current.disabled = !editor.editable() })
    void editor.open()
  })

  return <form onSubmit={editor.submit}>
    <fieldset disabled ref={controls}>
      <legend>Item details</legend>
      <label htmlFor={titleId}>Title</label>
      <input id={titleId} name="title" value={editor.field("title")}
        onInput={event => editor.edit("title", event.currentTarget.value)}
        aria-invalid={Boolean(editor.error("title"))}
        aria-describedby={editor.describedBy("title", helpId)}/>
      <small id={helpId}>Use the item name.</small>
      <span id={editor.errorId("title")}>{editor.error("title")}</span>
      <button type="submit" disabled={!editor.canSave()}>Save</button>
    </fieldset>
    <output aria-live="polite">{editor.message()}</output>
  </form>
}
```

The literal disabled fieldset protects the first response. Its owned effect enables editing after the authorized record arrives. The separate Save binding lets the user continue typing while a save is pending. The pilot tracks scalar fields by name and edit version. For a conflict, the application displays `editor.review()` and supplies the reviewed revision and explicitly selected field names to `editor.resolveReview(revision, keep)`. On an identity change, the previous partition retires. The application can reopen a fresh form for the verified principal through `onIdentityChanged` or a native reload.

## Acceptance

Run the compiled fixture with its Odin server in a browser. Drive races by releasing specific requests. The following are implementation gates.

- Request two IDs and compare their HTML bytes. Test direct GET, HEAD, reload and ordinary link navigation. Run the same route fixtures through the Odin and browser matchers for literals, a UTF-8 parameter, an encoded separator, a malformed escape and a trailing slash. A browser URL with a query and fragment selects the same page as its HTTP path. Reject ambiguous patterns, repeated names and a ninth parameter at build time.
- Register a broad page, an API prefix, a custom handler and asset/module mounts. Verify the runtime module keeps its JavaScript response, the custom route keeps its response, and missing API, asset and module requests keep their own 404. Exercise an API URL ending in `.js` with a module mount at `/`. An unknown page goes to the fallback. A PATCH to a page path never receives its HTML.
- Hold the initial GET. Before and after module attachment try typing and submitting, then release revision 7. Assert a clean “Lamp”, zero PATCH requests and no focus jump. Exercise transient failure on first load and refresh, authorized deletion during a dirty edit, and revocation or an opaque 404 after a successful read. Check visibility of the old values and save eligibility in each case.
- With two forms present, submit a locally valid title with Enter and have the server reject it with 422. Assert a scoped message, label and error IDs, first-invalid focus and correction. In a two-field fixture change the other input of a cross-field rule before delivering the 422. Assert zero stale messages and no focus movement. Move focus into the other form before a current rejection and verify it stays there.
- Submit twice, type again, then deliver a canonical success. Assert one logical write, the new baseline, the later draft, input identity and selection. Have two editors submit from revision 7. Assert one commit and one 409, exercise review with a newer record arriving while open, and verify only an explicit submission uses the reviewed revision and a fresh ID. Deliver an older receipt after a newer confirmed record and check both the draft and the shared revision.
- Seed a server operation with different input, then force that ID onto a submitted draft. Verify the identifier error stays distinct from revision review, the other receipt never initializes this draft, and the UI sends no automatic PATCH. Refresh, submit explicitly with a fresh ID and verify the original receipt is unchanged.
- Leave during a save, commit on the server and drop its response. Exercise both a fresh document and a browser back/forward cache restoration. Capture a browser-generated `pageshow` and require `event.persisted === true` for the restoration case. A history navigation that reloads the document exercises only the fresh-document case. Check one write, zero late publications, the presence of the old draft only on same-identity restoration, and a receipt lookup before Save unlocks. Repeat after switching identity while away. No private value reappears and no previous-identity receipt is requested.

The Odin browser suite compiles the routed fixture’s authored form through the public JSX pipeline and serves the generated document at `/items/42`. Chrome changes the form through its native submit event. The suite holds or reorders replies to exercise conflicting drafts, stale validation, dirty deletion, an obsolete client and an unknown journal version. Its separate navigation cases use real SQLite PATCH and receipt endpoints. [Controlled editor tests](../../testdata/ui/mutations.js) · [SQLite fixture](../../testdata/ui_store/adapter.odin)

Run `task test -- --package ui` with Chromium available. One native Back test requires a trusted `pageshow` with `persisted === true`, hides the form while verifying the identity, and observes one receipt lookup before revealing the user's later draft. A second case switches tenant on the intervening page, observes zero former-tenant receipt lookups, and loads the second tenant’s record. Each case forces a full reload separately. Production applications supply their own identity verifier, domain fields, retention policy and conflict-review UI. [Browser orchestration](../../tests/ui/browser_test.odin) · [Navigation fixture](../../testdata/ui/history-helper.js)
