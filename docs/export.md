# Accounting export: columns

What `export.accounting` writes (`lyra/app/docs/offline/specs/money.md` M-60 to M-65). The code is
`lib/src/domain/export/accounting.dart`; its `*Columns` lists must match this file.

**Stable.** A column is never renamed, removed or moved. A new one is only ever **added at the
end** of its dataset (M-61), so an import set up on the other side keeps working.

## Format

| | CSV (`csv`) | Excel (`xlsx`) |
|---|---|---|
| File | a `.zip` with one `<dataset>.csv` per dataset | one workbook, one sheet per dataset |
| Encoding | UTF-8 with a BOM, CRLF | Office Open XML |
| Separator | `;` when the company language writes a decimal comma (`es`, `pt`, `fr`, `it`, `de`), else `,` | — |
| Amounts | the currency's decimals, with the language's decimal mark (`5,80` / `5.80`) | numbers, formatted with the currency's decimals |
| Dates | ISO 8601 in the company's time zone with its offset (`2026-09-01T10:00:00-04:00`) | same, as text |
| Booleans | `true` / `false` | booleans |
| Text | quoted only when needed; text starting with `=`, `+`, `-` or `@` gets a leading `'` so it never runs as a formula | inline strings, never formulas |

Datasets come in this order: `sales`, `sale_lines`, `payments`, `receivables`, `stock_movements`.
People and devices are written by name. Every amount has its `currency` on the same row.

## The window

`from` and `to` are calendar days in the company's time zone, both included.

| Dataset | A row is in the window when |
|---|---|
| `sales`, `sale_lines` | the ticket was closed in it, or cancelled in it (an open ticket isn't a sale yet) |
| `payments` | its `date` (when the money moved) is in it |
| `receivables` | the credit ticket was closed in it; `collected` is measured at the time of the export |
| `stock_movements` | it happened in it |

## sales

One row per ticket.

| Column | |
|---|---|
| `id` | Lyra's id of the ticket |
| `ticket` | its code (`A-0001`) |
| `status` | `closed` or `cancelled` (M-64) |
| `opened`, `closed`, `cancelled` | when |
| `device` | the till |
| `seller`, `closed_by`, `cancelled_by` | people |
| `payment_method` | the settlement kind's code (`cash`, `transfer`…); empty when cancelled |
| `payment_method_name` | its name in the company's language |
| `payment_reference` | the reference typed at the till |
| `credit` | sold on the store's tab |
| `lines`, `units` | how many lines, how many units |
| `subtotal`, `tax`, `total` | added up from its lines (each line's tax rounded once) |
| `currency` | |
| `note` | |

## sale_lines

One row per line of the tickets above.

| Column | |
|---|---|
| `id` | Lyra's id of the line |
| `sale_id`, `ticket`, `sale_status` | its ticket |
| `line` | 1, 2… within the ticket |
| `product_id`, `sku`, `name` | the product as it was sold (frozen) |
| `quantity` | |
| `unit_price` | the price charged per unit, before tax |
| `list_price` | the list price, when there was a discount |
| `discount_percent` | |
| `tax_rate` | percent |
| `subtotal`, `tax`, `total` | `unit_price × quantity`, its tax, their sum |
| `currency` | |

## payments

Money recorded by hand, both directions, voided ones included (M-64).

| Column | |
|---|---|
| `id` | Lyra's id of the payment |
| `date` | when the money moved |
| `recorded_at` | when it was typed in |
| `direction` | `in` or `out` |
| `concept`, `concept_name` | code and name |
| `amount`, `currency` | |
| `method`, `method_name` | settlement kind |
| `account` | the company account it moved through (its label, or its rail's name) |
| `reference` | |
| `counterpart_name`, `counterpart_contact` | |
| `ticket`, `sale_id` | the ticket it names |
| `note` | |
| `status` | `recorded` or `voided` |
| `registered_by` | |
| `voided_at`, `voided_by`, `void_reason` | |

## receivables

Credit tickets. Empty while a master doesn't sell on credit (`money.md` money.receivable).

| Column | |
|---|---|
| `id` | Lyra's id of the ticket |
| `ticket` | |
| `date` | when it was closed |
| `seller` | |
| `total`, `collected`, `outstanding` | |
| `currency` | |

## stock_movements

| Column | |
|---|---|
| `id` | Lyra's id of the movement |
| `at` | |
| `operation` | `add`, `remove`, `reserve`, `unreserve`, `return` |
| `reason` | |
| `quantity` | always positive |
| `on_hand_change` | what it did to the units on hand: `+quantity` for `add`, `-quantity` for `remove`, `0` otherwise |
| `product_id`, `sku`, `product_name` | |
| `table_id` | the inventory table |
| `sale_id`, `ticket` | the ticket that moved it, if any |
| `source` | `manual`, `pos`, `import`… |
| `actor`, `device` | |
| `note` | |
