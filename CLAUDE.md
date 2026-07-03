# Quartermaster — Developer Notes

## What this is

Quartermaster is a World of Warcraft addon for the **1.12 client** (private servers
— OctoWoW / Turtle-style): a **personal raid-prep helper** that centralizes things
otherwise spread across several addons, with full per-character control. Four pillars:

1. **Consumables** — a single per-character desired list. **Prep:** "do I have enough, and
   if not where is the rest" (this char's bags/bank + other characters). **In-raid:**
   which are active and time left, and a one-click **consume without opening the bag**
   (`UseContainerItem` by itemID).
2. **Repair** — auto-repair at repair-capable vendors (`MERCHANT_SHOW`), and a gear
   durability **status / warning** when the worst item drops below a threshold.
3. **Reagents & stock items** — the *same* list also holds items you only want a live
   **count** of (`track="stock"` — reagents, on-use items), separated from the buffs with
   **category dividers**. An independent `restock` toggle (orthogonal to how the item is
   *used*) adds **auto-restock** at a vendor that sells them, buying up to a configured cap
   (`MERCHANT_SHOW` → `BuyMerchantItem`).
4. **Cross-character stocking** — consumables for the raid often live on a bank/mule
   alt. The account-wide DB lets any character see what the raid char **wants** and
   **has**; utility functions then move stock into the raid char's bags, either by
   **mailing** from an alt or **withdrawing from the bank**, always **filling existing
   partial stacks first** — and the reverse: a per-character **Transferable** list
   (`kind="transferable"`) of items to proactively shed, via `/qm banksync` (bank) or
   the **Transfer** config tab's mail actions (dump excess to a recipient, or supply
   another character's shortfall).

> **Status: scaffold.** The architecture, data model, bag/bank scan, the consume
> primitive, durability scan + auto-repair, the mail sequencer, the modular config
> (tabs + list editor — incl. the add **classifier**, the per-item **apply mode**, the
> **Track axis** with `stock` count rows, the **enabled/hidden/off** tristate, **category
> dividers**, and shift-click / drag-drop item entry), the shared moveable-frame system,
> the **central notification sink**, the **in-raid tracker HUD** (buff/enchant/cooldown
> readers + progress-bar rows, stock count gauges, divider headers + the expiring/lost
> notification triggers), reagent restock-to-cap, the prep math (`T.plan`), the bank
> stack-fill mover (both directions), the **Transfer** tab (transferable list,
> `/qm banksync`, mail dump-excess, mail supply-another-character), and the TurtleMail
> compat path (native flow via `TurtleMail.orig`, per-item retries), the **in-raid repair
> status row** (shares an edge with the profile-switch row rather than displacing it), the
> low-repair / low-stock notification triggers, and the Tracker tab's read-only **prep
> display** (`/qm prep`, and a **Prep** button on the Tracker tab, both reading
> `C.prepPlan`/`T.plan` for the active list) are all in place.

## Architecture (multi-file)

The addon is split by feature. 1.12 has **no per-file addon-table vararg**, so files
share state through one global table, `Quartermaster`, aliased `local QM =
Quartermaster` at the top of each file.

- [Core.lua](Core.lua) — the namespace + everything shared: SavedVariables model and
  defaults merge, the per-character registry, **bag/bank scanning**, money/item
  helpers, the **desired-list setters** (`addDesired`/`removeDesired`/`moveDesired`/
  `setTarget`), the **event hub** (`QM.on`), **internal signals** (`QM.subscribe`/
  `QM.fire`), the OnUpdate driver, and the slash command. Creates the engine frame at
  load, so `QM.on` works the instant any later file calls it.
- [Profiles.lua](Profiles.lua) — named per-character **profiles** of the Tracker list
  (switch/create/rename/delete/export/import). Invariant: `me.consumables` IS
  `profiles[activeProfile]` (the same table) — switching just re-points that alias and
  fires `DESIRED_CHANGED`; `migrateChar` re-links it on every load. Export/import is a
  hand-parsed `"QMP1:" .. base64(payload)` line format, **never `loadstring`**.
- [ItemDB.lua](ItemDB.lua) — a **name → itemID index** for the add box's typed-name
  resolution and Tab-complete. **Compat**: if aux is loaded, reads its
  `aux.account.item_ids` directly. **Standalone**: otherwise builds & persists our own
  (`QuartermasterDB.itemIndex`) by scanning `GetItemInfo("item:ID")` across the ID range
  — the 1.12 WDB item cache makes this work offline (aux's `scan_wdb` trick). Exposes
  `QM.resolveName` and `QM.matchNames`.
- [ItemMeta.lua](ItemMeta.lua) — account-wide, item-intrinsic **tracking metadata**
  (`track` = buff/cd/food/**stock**, effect `match`, `maxDuration`, food `eatTime`/
  `eatMatch`), keyed by itemID. A curated `SEED` (see "Reference addons") holds defaults;
  `QM.db.items` holds only user/learned overrides; `QM.itemMeta(id)` merges the two per
  field. Owns the **live effect reader** `QM.itemEffect(id, apply)` (self-buff time-left/
  stacks, or weapon temp-enchant via Nampower/`GetWeaponEnchantInfo`) and
  `QM.itemMatchEffective` (the in-force match rule — weapon items need an *explicit*
  `enchantid`, never a guessed default). A weapon enchant's identity is **learned on
  apply**: `C.use` snapshots the slot's pre-apply enchant so `QM.learnWeaponEnchant` can
  commit the new one only once it differs, avoiding a stale-id window right after replace.
  Also owns **`QM.caps`**, the capability/compat table (`superwow`, `nampower`,
  `equippedItem`, `cUnitAuras`, `itemIdCooldown`, `turtleMail`, `aux`) every module
  branches on instead of re-probing.
- [Consumables.lua](Consumables.lua) — the **single** per-character desired list (buffs,
  on-use items, stocked reagents together). `C.classify(id, type, subtype)` → apply mode
  (`self`/`weapon`/`target`/`none`) via a curated `APPLY_OVERRIDES` table, then item
  class/subclass, matched **locale-safe** (`GetAuctionItemClasses`, not string names).
  `QM.itemValidators["consumables"]` is a **classifier that never rejects** — anything
  unrecognized just lands as a stocked item (`apply="none"`, `track="stock"`). **Restock**
  (`e.restock`) is an independent boolean, orthogonal to `apply` — `C.restockAtMerchant`
  tops `restock=true` entries to `target` on `MERCHANT_SHOW`, one `BuyMerchantItem`/tick,
  rounded to vendor batch size and capped by affordability. The **in-raid tracker**
  (`C.liveStatus`/`C.activeBuffs`/`C.orderTracked`) derives each row's `buff`/`cd`/
  `eating`/`ready`/`stock` phase and paints the HUD into `Quartermaster_Main`
  (progress bars, stock gauges, category headers, click-to-consume), plus the
  `consumableExpiring`/`consumableLost`/`lowConsumable` triggers (TICK, edge-detected —
  the last fires per `track="stock"` row when its bag count drops to/under its own Low
  threshold, mirroring the HUD's own red/orange/green count colouring; re-arms only on an
  actual further drop, tracked per item as `lowFloor[id]`, rather than on a timer, so it
  doesn't repeat while the count just sits at the same low level). An optional
  **repair status row** (`options.hudRepairRow`/`hudRepairRowPos`) reads `QM.Repair`'s
  last durability scan onto the same HUD; it shares whichever edge the profile-switch row
  also sits on rather than displacing it — the profile row always wins the true top/bottom
  edge, with the repair row nested just inside it (see `renderHUD`'s
  `profileAtTop`/`repairAtTop` ordering). Owns the **food
  eat session** (`track="food"`): a click starts a bar that fills toward the learned
  eat-time, then converts to the Well Fed duration; a learned per-item "still eating"
  regen aura stops the bar early on stand/move. Registers the **Tracker** config tab.
- [Repair.lua](Repair.lua) — `Rp.scanDurability()` / `Rp.autoRepair()`; `needsRepair()`
  vs threshold. The `lowRepair` notification trigger dedupes by a shrinking percentage
  BAND rather than a timer: below the threshold, a fresh warning needs the worst item to
  drop into a new, lower band -- 5%-wide normally (so e.g. a 33% threshold first warns for
  the 30% band, next at 25%, ...), narrowing to 2%-wide once under 10%. Recovering back
  above the threshold clears the band memory. `PLAYER_ENTERING_WORLD` (login, every
  zone/instance transition) bypasses the banding and warns unconditionally whenever still
  below threshold. Registers the **Repair** config tab.
- [Transfer.lua](Transfer.lua) — bag/bank/mail movement, both directions.
  `T.plan(charKey, kind)` computes a list's shortfall vs bags plus how much the open
  bank or other chars' cached inventory could cover. `T.fromBank`/`T.toBank` move
  stacks between bags and an open bank, filling partial stacks first.
  `T.mailItems(recipient, queue, onDone)` is the mail sequencer (see "Reference addons"):
  one stack per mail, sequenced on `MAIL_SEND_SUCCESS`. `planStacks(itemID, amount)`
  (via `packStacks`) turns "item X, send N" into a `{bag,slot}` queue, preferring exact
  stack matches and topping up the largest unclaimed stack otherwise — built so the mail
  can't strand an odd remainder (e.g. target 10 becoming a stray 9+1). It only *reads*
  bags; it does not touch the cursor, and skips non-mailable slots (soulbound/quest/
  conjured, detected by tooltip scan — 1.12 exposes no binding flag).
  **Only `prepareQueue`/`Prep` may execute that plan**, one action per tick: firing
  several `SplitContainerItem`/`PickupContainerItem` pairs back-to-back with zero delay
  desyncs this client (items stay locked mid-transaction, TurtleMail's attach never
  completes). `Prep` paces a multi-item batch at one step per `PREP_STEP_DELAY` (0.3s),
  then — because the last manipulation can still be server-lock-pending after that, and
  mailing an unsettled slot either attaches nothing or silently dies server-side with
  **no event at all** — ends in a **settle gate** (`queueSettled`): the queue waits until
  every slot's link is un-`locked` (polled per tick, `SETTLE_TIMEOUT` 5s) before handoff
  to `T.mailItems`. A status label narrates each phase so a paced batch doesn't look
  like a hang. Both `T.mailDumpExcess` and `T.supplySend` go through `Prep` rather than
  calling `planStacks` directly. Owns the **transferable list** (`kind="transferable"`,
  same never-rejects classifier as consumables): items to proactively shed, `target`
  repurposed as **Keep** (the floor left behind), plus `bankable` and a per-row
  `mailRecipient`. `transferableFloor(c, e)` resolves that floor for both sync paths: if
  the same item is *also* on the active tracked list, that list's `target` always wins
  over Keep, and a dual-listed item is processed only once (by the transferable pass) to
  avoid double-counting against a stale inventory snapshot. `T.bankSync()`
  (`/qm banksync`) tops up the tracked list's shortfall from the bank, then (optionally)
  banks tracked-list and transferable overage above their floors. `T.mailDumpExcess()`
  mails transferable overage to its resolved recipient, then (optionally) tracked-list
  overage to the character's `defaultMailRecipient`. `T.supplyPlan`/`T.supplySend`
  answer the inverse of `T.plan` — what *I* can cover of *another* character's shortfall
  (`/qm mailsync <character> [list]`) — netted against **`QM.inFlightCount`**
  (`chars[x].inFlight[itemID]`), a per-recipient virtual-stock count so a second mule
  doesn't also queue a mail for a shortfall already in transit. It's marked only from the
  actual before/after bag-count drop after a batch completes (never the requested amount
  blindly, so a partial failure doesn't strand a phantom entry), and cleared by the
  *receiving* character's own `TakeInboxItem` hook — with a `MAIL_SHOW` wipe as a backstop
  (a redundant resend is cheaper than a shortfall silently never covered). Both live mail
  controls sit on the **`Quartermaster_Mail`** panel (not a config tab), shown only while
  the mailbox is open. The sequencer runs **with or without TurtleMail**: TurtleMail
  globally replaces `ClickSendMailItemButton` at `PLAYER_LOGIN` with an async version that
  never attaches anything inside one synchronous call, so `T.mailItems` attaches via the
  surviving `TurtleMail.orig` when `QM.caps.turtleMail`, and neutralizes its
  `sendmail_state` around each batch so its hooks don't fake-lock the queue's slots. The
  per-item loop retries because on this server a `SendMail` sometimes gets **no reply at
  all** (no success event, no error) — a failed attach retries up to
  `MAIL_ATTACH_RETRIES`, an unanswered send re-routes through `sendCurrentMailItem` up to
  `MAIL_SEND_RETRIES` before the batch aborts.
- [Notify.lua](Notify.lua) — the **central notification sink**: `QM.notify(text, opts)`
  raises a transient, fading line on a moveable/anchorable area (`Quartermaster_Notify`).
  Feature modules call in with a `severity`, a `category` toggle (gated in config), and an
  optional dedupe `key`. Registers **no** config tab — the strip's look + master switch
  are on **Display**; per-category triggers live on the feature tabs that raise them.
- [Config.lua](Config.lua) — the tabbed panel framework + reusable widgets.
- [Quartermaster.xml](Quartermaster.xml) — the moveable main HUD + notification frame
  shells (contents built in Lua; events live on Core's Lua engine frame, not these).
- [pack.ps1](pack.ps1) — builds `Quartermaster.zip`.

**Load order** (`.toc`): Core, Profiles, then feature modules, then Config, then the XML.
Modules register events/signals/config-tabs at load; Core dispatches.

### Engine, events, signals

Core creates a hidden `CreateFrame("Frame")` engine that owns all `RegisterEvent`s
and the `OnUpdate`. `QM.on(event, fn)` registers the event on first use and appends a
handler (handlers read the global `event`/`arg1..` as usual on 1.12). `QM.subscribe`/
`QM.fire` is a second, **internal** pub/sub for module decoupling (signals: `DB_READY`,
`READY`, `TICK` (~0.5s), `INVENTORY_UPDATED`, `DURABILITY_UPDATED`, `DESIRED_CHANGED`,
`ITEM_META_CHANGED`, `ITEMDB_READY`, `LOCK_CHANGED`, `FRAME_MOVED`, `CONFIG_SHOWN`).
`BAG_UPDATE` only sets a dirty flag; the actual rescan is debounced to the next `TICK`.

### Moveable / anchorable frames

Core owns a shared frame-layout system (see "Reference addons"): a frame calls
`QM.registerMoveable(frame, layoutKey[, onLock])` from its XML `OnLoad` to follow the
global lock (`options.locked`) and persist its position under `frames[layoutKey]`.
Because 1.12 mis-positions non-`TOPLEFT` anchors, frames are always pinned `TOPLEFT`
with the offset derived from the user-facing anchor corner. XML drag routes through the
lock-aware `Quartermaster_FrameDragStart`/`_Stop`. Layouts are (re)applied on `DB_READY`;
locks on `LOCK_CHANGED`. The main HUD and notify area both use it. The **mail panel**
(`Quartermaster_Mail`) deliberately does not: it anchors live to Blizzard's own
`MailFrame` (re-applied on every `MAIL_SHOW`) rather than a stored position, since a
mailbox-relative anchor doesn't fit the UIParent-relative assumption the rest of the
system makes. It's still draggable, just not persisted.

**1.12 CTD rule: a frame's height (or width) must have exactly ONE owner.** The tracker
HUD's height is content-driven (`SetHeight` to its row count), so: the resize grip is
**width-only** (`StartSizing("RIGHT")`, never `"BOTTOMRIGHT"`) since native sizing and our
own `SetHeight` both driving height hard-crashes the client on mouse-up; `renderHUD` only
calls `SetHeight` when the value actually changes; drag hooks set a `qmMoving` flag so the
painter skips re-layout mid-drag; and the HUD is `SetResizable(true)` only for the
duration of an active grip-resize — a *permanently* resizable frame reconciles its size on
`StopMovingOrSizing` even after a plain move, which also collides with our `SetHeight`.

## Data model (SavedVariables: `QuartermasterDB`, **account-wide**)

Account-wide on purpose — that's what lets a bank alt read the raid char's wants/haves.

```lua
QuartermasterDB = {
  options = { locked, showWhenSolo, autoRepair, repairThreshold,
              reagentRestock, fillStacksFirst, rowOrder,
              hudHidden, hudHeader, showTargetCount, showItemName, abbreviateNames, hudOutline,
              barTexture,                          -- index into Consumables' BAR_TEXTURES
              buffLowDuration, showBuffIds, guardReuse,
              transfer = { dumpTrackedOverage,      -- /qm banksync also banks tracked overage
                           mailTrackedOverage },     -- Dump Excess also mails tracked overage
              notify = { enabled, duration, fontSize,
                         lowRepair, lowConsumable,   -- per-category gates
                         consumableExpiring, consumableLost } },
  frames  = { main   = { point, x, y, scale, width },
              notify = { point, x, y, scale, width } },
                        -- no entry for Quartermaster_Mail -- it anchors live to Blizzard's
                        -- MailFrame instead (see "Moveable / anchorable frames").
  items   = { [itemID] = { track, match = { by, value }, maxDuration, icon,
                           eatTime, eatMatch = { by, value } } },
                        -- account-wide, SPARSE -- overrides only of ItemMeta.lua's SEED.
  itemIndex = { [lowercase name] = itemID },   -- standalone mode only (ItemDB.lua)
  mailRecipients = { name, ... },   -- custom Transfer recipient names, account-wide
  chars   = {
    [charName] = {                  -- PER-CHARACTER (the desired list lives here)
      class, faction, realm, lastSeen,
      consumables = { { id, name, icon, quality, target, low, state, apply, restock }, ... },
                        -- THE single ordered list (buffs, on-use items, reagents). state =
                        -- enabled|hidden|off; apply = self|weapon|mh|oh|target|none (never
                        -- nil); restock = true|nil, independent of apply; target = prep
                        -- amount / restock cap. A row may instead be a DIVIDER:
                        -- { divider=true, label, state } (no id) -- a HUD group header +
                        -- row-order wall.
      profiles = { [name] = list }, activeProfile = name,
                        -- named profiles (Profiles.lua). INVARIANT: consumables IS
                        -- profiles[activeProfile] (same table, re-aliased on switch/load).
      transferable = { { id, name, icon, quality, target, state, bankable, mailRecipient }, ... },
                        -- Transfer.lua's proactive-shed list. `target` repurposed as Keep
                        -- (floor left behind, default 0); no `low`. `bankable` gates
                        -- /qm banksync; `mailRecipient` overrides defaultMailRecipient below.
      defaultMailRecipient,   -- this character's fallback Transfer mail recipient
      mailTarget = { char, profile },   -- last "supply another character" pick; backs both
                        -- the Quartermaster_Mail panel and /qm mailsync <character> [list].
      inventory   = { [itemID] = { name, icon, quality, bags, bank, total } },
      inventoryAt,
      durability  = { worst = pct, scannedAt },
      inFlight    = { [itemID] = amount },   -- virtual stock a mule has already mailed
                        -- toward a shortfall but not yet picked up (see Transfer.lua).
    }, ...
  },
}
```

`QM.me` points at the current character's record for the session. The **desired sets
are per character** (the raid char defines what it wants); the **inventory snapshot**
is written on every scan so other characters can read it for cross-char planning.

### Bag/bank scan (`QM.scanInventory`)

Bags (0–4) are always rescanned; the **bank** (`-1` plus bags
`NUM_BAG_SLOTS+1 .. +NUM_BANKBAGSLOTS`) only when `QM.bankOpen` (`BANKFRAME_OPENED`/
`_CLOSED`). When the bank is closed we **carry forward** the last-known bank counts so
the prep view still shows where stock is. `itemID` comes from parsing the item link
(`item:(%d+)`); per-stack count from `GetContainerItemInfo`.

## Config (`/qm`)

**Slash is intentionally minimal**: `/qm` / `/qm config` toggles the panel; `/qm lock` /
`/qm unlock`; `/qm show` / `/qm hide` toggle the tracker HUD; `/qm banksync` runs
`QM.Transfer.bankSync()` (needs the bank open); `/qm prep` prints the active tracked
list's shortfall (`C.prepPlanPrint`, backed by `T.plan`) to chat, one line per short
item — the same report the Tracker tab's **Prep** button shows in a read-only dialog;
`/qm mailsync dump` / `/qm mailsync
<character> [list]` run the Transfer mail sync (list defaults to that character's
`activeProfile`; both need the mail window open); `/qm mailtest <recipient>
[delaySeconds]` is a debug probe for the SendMail-no-reply failure. Character/profile
names are case-sensitive, so the handler preserves the slash text's original case for
`mailsync`'s arguments. Everything else lives in the panel/mail panel — no full slash
parity.

The panel is **modular and tabbed**: each module calls `QM.registerConfigTab{ name=,
order=, build=function(page) }` at load, and each page is built lazily on first
selection. The organising rule is **appearance vs. behaviour** — how anything looks or
where it sits lives on **Display**; what a feature does (its triggers, its content)
lives on that feature's own tab.

Tabs: **Display** (registered in [Consumables.lua](Consumables.lua) since the tracker
HUD is the bulk of it) — HUD appearance/placement, and the notification strip's look +
master switch. Includes a **show-buff-ids** toggle that hooks the GameTooltip buff
methods to inject each buff's spell id (and an equipped weapon's temp-enchant id) into
tooltips, as a discovery aid for typing Track match ids. **Tracker** (the unified item
list, profile switcher, row order, low-duration, don't-reuse, and the consumable
notification triggers). **Repair** (auto-repair, durability threshold, low-repair
trigger). **Transfer** (registered in [Transfer.lua](Transfer.lua) — the transferable
list plus recipient management and the tracked/transferable-overage sync options; the
live mail-action controls sit on the `Quartermaster_Mail` panel instead, not this tab).
There is no separate Notifications tab — the strip's presentation is on Display and its
per-category triggers sit on whichever feature tab raises them.

The reusable **`QM.Config.listEditor(page, spec)`** backs both **Tracker** and
**Transfer**. Each item row: a **state chip** (tristate, see below), item icon + name,
then right-aligned columns gated by `spec` — a **Use** drop (apply mode) on Tracker or a
**Mail To** recipient drop on Transfer (the two share one column slot, never coexist), a
**Track** drop (`buff`/`cd`/`food`/`stock`) + gear popup (Tracker only), a **Low**
threshold box (Tracker only), a **Target/Keep** box, and a **vendor-restock toggle**
(Tracker) or **bankable toggle** (Transfer) sharing a slot. A **divider** row instead
shows just a label editbox + state chip + reorder/delete, added via "+ Separator"
(Tracker only). `spec` also exposes `header`/`footer` hooks bracketing the list (profile
switcher, recipient manager, mail action row).

**Upvalue budget.** Lua 5.0 caps a function at **32 upvalues**, and `listEditor` — one
large function nesting `makeRow`/`paintItemRow`/`refresh`/etc. — sits right at that edge.
Fix: per-row widget factories are bundled into one table (`Widgets`) and paint-time tint
constants into another (`Tint`), since a table costs one upvalue regardless of how many
functions/constants it holds. Add new per-row widgets or tint constants to those tables
rather than a fresh chunk-level local referenced from inside `listEditor`.

**State chip** (leftmost column, `QM.itemState` — `enabled`/`hidden`/`off`): a tinted
circle — green enabled (shown + counted), amber hidden (not shown, still counted), grey
off (ignored). Click cycles state (`QM.cycleState`); the track UI/restock logic gates on
`QM.itemActive` (≠ off) and `QM.itemShown` (= enabled).

**Adding items** — shift-click a link into the add box, drag an item onto the box or
list (an overlay shows while the cursor holds an item), or type an ID/name with
Tab-complete (an inline ghost previews the match; Enter/Add resolves it via
[ItemDB.lua](ItemDB.lua)). The classifier never rejects, so a non-consumable just lands
as a `stock` row. 1.12 has no cursor-read API, so drag/drop remembers the link at pickup
via `PickupContainerItem`/`PickupInventoryItem` hooks; shift-click routes through a
`HandleModifiedItemClick` wrap, since vanilla only forwards to the chat box otherwise.
All edits route through the Core setters and `QM.fire("DESIRED_CHANGED")`.

## Comments & code style

Comments are costly and this codebase is over-commented — keep them lean. The bar: a
comment must tell the reader something the code itself does not.

- **Why, not how.** Don't restate what the code plainly does. Explain the non-obvious
  *reason* — a 1.12 API quirk, an ordering constraint, a deliberate trade-off.
- **Document the contract, not the body.** A function gets at most one short line on what
  it takes / returns / guarantees (and any side effect) when that isn't obvious from the
  name. Comment the important API and its signature; don't narrate the implementation
  line by line.
- **No development stories.** Comments describe the code as it is *now*. Do **not**:
  - reference plan phases/steps or status ("Phase 1", "first draft", "SKELETON", "stubbed");
  - narrate history — "was a boolean `enabled`", "migrating the old …", "now that `state`
    is authoritative", "before changing X". Git holds history.
  - recount what a sibling addon does or that we ported from it, beyond a brief pointer
    where we genuinely lift an idiom and the reader would want the source.
- **Keep** the genuinely surprising facts (texture is `GetItemInfo`'s 9th return; `--`
  breaks XML; one mail attachment per send) — phrased as facts, not anecdotes.
- File headers: one or two lines on the file's responsibility. Not a changelog or a
  feature tour.
- TODOs are the one allowed forward-reference, and only as a terse `-- TODO: <what>` — not
  a paragraph retelling the roadmap (that lives in `docs/` and "Open TODOs" below).

## 1.12 client gotchas

1. **Mail = ONE attachment per message.** Vanilla has a single send slot
   (`ClickSendMailItemButton` / `GetSendMailItem` / `SendMail`). To mail N stacks you
   send N mails, one each, sequenced on `MAIL_SEND_SUCCESS` (see "Reference addons" for
   the mailer's provenance). OctoWoW *may* differ — confirm in-game. **TurtleMail globally replaces
   `ClickSendMailItemButton`** (and several other mail globals) at `PLAYER_LOGIN` with its
   own async, cursor-polling version that never attaches anything inside a single
   synchronous call — so driving the vanilla attach sequence through the GLOBAL
   `ClickSendMailItemButton` under TurtleMail silently sends nothing (no error). The
   original survives in `TurtleMail.orig`; `T.mailItems` routes the attach through it
   when `QM.caps.turtleMail` — see [Transfer.lua](Transfer.lua)'s `clickSendSlot`.
2. **`GetItemInfo` needs the item cached** and returns no sell price on 1.12. The
   returns are `name, link, quality, level, type, subType, stackCount, equipLoc, texture`
   — **texture is the 9th** return (there is no `minLevel` field here; aux reads slot 9
   too). A freshly-referenced item can
   return `nil` until seen; resolve by **link or itemID** first. *Names* are not directly
   reliable, but `GetItemInfo("item:ID")` reads the persistent **WDB** item cache offline
   for any item the client has ever seen — so scanning the ID range yields a name→id index
   (see [ItemDB.lua](ItemDB.lua), the aux `scan_wdb` trick). Only never-seen items stay
   unresolvable by name.
3. **No `C_Timer.After`.** Use `OnUpdate` timers (Core's `TICK`, the mailer's own
   OnUpdate).
4. Vanilla Lua 5.0: global `this`/`event`/`arg1..` in handlers, `string.*`/`table.*`,
   `table.getn`, no `#` operator, `getglobal`, `math.mod`/`math.floor`.
5. **XML comments must not contain `--`** (XML rule, not WoW-specific). A `--` inside
   an `<!-- ... -->` block makes the *whole .xml file* malformed; the 1.12 client then
   **silently skips the file** — its frames are never created and **no Lua error is
   raised** (so nothing shows in BugGrabber). Symptom: a frame that "doesn't exist"
   with a clean error log. Mind this in our comment-heavy XML — write `;`/`-`/`—`, not
   `--`. (Validate locally with PowerShell: `[xml](Get-Content file.xml -Raw)`.)
6. **`GetWidth()`/`GetHeight()` are unreliable on this client for a frame sized purely
   by two opposing anchor points** (no explicit `SetWidth`/`SetHeight` ever called) --
   confirmed via `GetLeft()`/`GetRight()`, which read the true resolved edges and are
   accurate. An explicitly-sized frame (e.g. the config panel itself, `SetWidth()`'d in
   `build()`) reports `GetWidth()` correctly; a frame anchored on both sides (e.g. a
   `ScrollFrame` stretched between two points) can under-report. This bites hardest when
   that number gets **baked into another frame via an explicit `SetWidth()` call**
   (`QM.Config.scrollChild`'s `fit()` did exactly this) -- the error freezes permanently
   from that point on, surviving resize/reopen/reload, since the target frame is no
   longer anchor-derived. Fix: derive width from `GetRight() - GetLeft()` (guard both
   non-nil) instead of trusting `GetWidth()` on an anchor-only-sized source frame.

> **No Lua compiler/interpreter is available here** (same as the other addons) — there
> is no offline lint/run step. Verify by reading the code and loading it in-game.
> (XML *well-formedness*, though, you can check offline — see gotcha #5.)

## Reference addons (siblings in this `Interface/AddOns`)

This is the one section that names other addons living locally in this developer's
`Interface/AddOns` folder — either as the source of a ported idiom, or (TurtleMail, aux)
as something Quartermaster actively detects and interoperates with at runtime via
`QM.caps`. None of them ship with or are required by Quartermaster, and a checkout
elsewhere won't have these sibling folders; every other mention of "see Reference
addons" in this file points back here rather than re-naming them inline. (The README has
a short pointer to this section too, for anyone reading it without the sibling checkouts.)

- **QuickStash** (`../QuickStash/`) — same author. The **mail sequencer** (`T.mailItems`)
  and the merchant-buy loop (`C.restockAtMerchant`) are lifted from its `AutoMailer` and
  `Seller`; also the model for throttled bag-action loops and `UseContainerItem`. Read its
  CLAUDE.md for the mail/1.12 notes.
- **TurtleMail** (`../TurtleMail/`) — the battle-tested 1.12 mail driver; also globally
  hooks several mail globals (notably `ClickSendMailItemButton`) at `PLAYER_LOGIN`, which
  is why `T.mailItems` attaches via `TurtleMail.orig.ClickSendMailItemButton` and
  neutralizes its `sendmail_state` around each batch (see gotcha #1). Detected at runtime
  via `QM.caps.turtleMail` — Quartermaster works with or without it installed.
- **aux** — a popular auction/inventory addon. Detected at runtime via `QM.caps.aux`:
  when present, [ItemDB.lua](ItemDB.lua) reads its `aux.account.item_ids` name→id index
  directly instead of building/persisting our own (see gotcha #2). Optional — Quartermaster
  builds its own index when aux isn't installed.
- **ConsumesManager** (`../ConsumesManager/`) — an existing consumable tracker; its
  `Itemlist.lua` seeded [ItemMeta.lua](ItemMeta.lua)'s curated `SEED` defaults.
- **SellValue** (`../SellValue/`) — external vendor-price table (`SellValues["item:"..id]`),
  if Quartermaster ever needs prices.
- **FearWardHelper** (`../FearWardHelper/`) — sibling addon by the same author; the
  **config panel** idioms (FauxScrollFrame list editor, custom edit-box backdrop,
  value-in-title sliders), the **moveable/anchorable frame system**, the **notification
  strip**, the height-ownership CTD pitfall (see "Moveable / anchorable frames"), and the
  32-upvalue ceiling (see "Upvalue budget") were all encountered/solved there first.
- **pfUI** — general 1.12/SuperWoW API reference (e.g. which `GameTooltip` buff method to
  hook, see Display tab's show-buff-ids toggle).
