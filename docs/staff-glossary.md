# Staff glossary

The words the application uses, and the words it deliberately does not.

This exists because WP-9's test list includes a staff-vocabulary check and
there was nothing to check against. It is a draft assembled from the schema's
own vocabulary — the seeded role descriptions, the table comments, the CHECK
constraints — rather than invented. **Correct it.** Where the shop floor uses a
different word, the shop floor is right.

---

## The rule that decides where a word lives

Three categories, and confusing them is the most damaging mistake the client
can make (0004_configuration.sql:58, 78).

| Category | Owner | Where the words live | Example |
|---|---|---|---|
| **Application chrome** | the product | `lib/l10n/*.arb` | "Try again", "Working offline", the label for a `draft` order |
| **Tenant-owned labels** | the shop | the `translation` table, read at runtime | "Cutting", "Counter Staff", "Chest", "Regular customer" |
| **User-entered content** | the user | the row | a customer's name, a note, a reason's free text |

A tenant-owned label placed in a message catalogue silently breaks every shop
that renames it — which AP-1 exists to allow. When in doubt: **could a shop
owner reasonably want to change this word? Then it is theirs, not ours.**

---

## Application vocabulary

Words the product owns. These are catalogue entries.

| Word | Means | Not |
|---|---|---|
| **Branch** | one shop location | "store", "outlet", "unit" |
| **Order** | what a customer asked for, as a commercial fact | "job", "ticket" — a job card is production, not commerce |
| **Job card** | one garment's route through production | "work order", "task" |
| **Day close** | the end-of-day cash reconciliation | "cash up", "EOD", "settlement" |
| **Draft** | created, not yet committed; still freely editable | "pending", "unsaved" |
| **Confirmed** | committed; changes now leave a trail | "approved", "accepted" |
| **Cancelled** | stopped deliberately. Not an error | "void", "deleted" |
| **On the way** | `in_transit` — stock has left one branch and not arrived | "shipped", "in transit" |
| **Trial** | the fitting appointment before delivery | "fitting" is acceptable; pick one and keep it |
| **Alteration** | rework after the customer has seen the garment | "repair", "fix" |
| **Reason** | the recorded why behind an action that needs one | "note", "comment" — a note is optional, a reason is not |
| **Working offline** | expected, supported operation without a connection | "no internet", "connection lost", "error" |

## Tenant-owned vocabulary — never in a catalogue

These come from rows. The examples are the development seed's; a real shop's
will differ, which is the point.

| What | Table | Seed examples |
|---|---|---|
| Role names | `role.name` | Owner · Accountant · Branch Manager · Counter Staff · Master Cutter · Tailor · Delivery / QC |
| Workflow stages | `workflow_stage.label` | Cutting · Stitching · Finishing · Quality check |
| Reason codes | `reason_code.label` | the shop writes its own |
| Payment modes | `payment_mode.label` | the shop writes its own |
| Garment types | garment type names | Shirt · Trouser · Kurta · Blouse · Blazer |
| Measurement fields | `template_field` labels | Chest · Sleeve · Waist · Collar |

## Words to avoid

| Avoid | Because |
|---|---|
| "Sync" as a noun in front of staff | it describes the mechanism, not their situation. Say what it means for them |
| "Error" for an empty list | nothing is wrong; there is simply nothing there yet |
| "Invalid" | says the person is wrong. Say what is needed: "Enter a number" |
| "Please wait" | they are not waiting, they are working |
| "Success" | say what happened: "Saved", "Sent" |
| "User" | say who: customer, staff member, owner |
| "Delete" for something recoverable | the schema soft-deletes (BR-19). If it can come back, do not say delete |

## Tone

Short sentences. Present tense. The second person for instructions
("Enter a number"), never the passive ("A number must be entered"). No
exclamation marks. English in V1; every one of these is a catalogue key, so
Hindi is a translation rather than a rewrite.
