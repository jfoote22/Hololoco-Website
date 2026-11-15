# The Hololoco app's back end

The Hololoco app (Unity, Android and iOS) is how the public finds and plays with
what businesses put on the map. It talks to the same Supabase project as the
website and needs no server of its own: everything below is a Postgres function
called through Supabase's REST API, and the database enforces every rule.

- **Calling a function:** `POST {SUPABASE_URL}/rest/v1/rpc/<name>` with a JSON
  body of its arguments, and the headers `apikey: <publishable key>` and, when
  signed in, `Authorization: Bearer <the player's access token>`. Any Supabase
  client library does this for you (`supabase.rpc("capture", {...})`).
- **Signing in:** Supabase Auth, with the same accounts as the website (Google,
  or an email code). Players need no profile name or age check to play; those
  are only for posting drops.
- **Errors:** a refused call comes back as HTTP 400 with a `message` that is one
  of the short codes listed with each function. Show your own words for each.
- **Shapes:** every function returns JSON. A *drop* is the shape of
  `drop_to_json` (the same as the website's `lib/drops/json.ts`): `id`, `type`
  (`offer`, `object` or `message`), `title`, `description`, `objectId` (a
  ready-made look from the website's `public/library/`) or `asset` (an uploaded
  photo or model, with paths in the public `drop-assets` bucket), `offer`,
  `placement` (`lat`, `lng`, `height` above the ground in metres, `size` across in
  metres, `turn` in degrees clockwise from north), `timeZone`, `timing`, `owner`.

## Placing drops in AR

`placement` is all a geospatial anchor needs: put a terrain anchor at `lat`,
`lng`, raise the model `height` metres, scale it to `size` metres across, and
turn it `turn` degrees. Models are GLB (load them with glTFast); photos come
framed as a GLB too. Use ARCore Geospatial on Android and iOS.

## What's around the player

### `app_nearby(lat, lng, radius_m = 500)`

Anyone can call it, signed in or not. `radius_m` is clamped to 50 to 2000.
Returns:

- `drops`: drops within the radius, nearest first, up to 200. Each is a drop
  plus `distance` (metres), `captured` (this player has captured it before),
  `mine` (the player posted it), `quest` (`id`, `name`, `position`,
  `stageCount`, if it's a quest stage) and `events` (`id`, `title`,
  `position` for each live event it's a stop of).
- `items`: items other players left on the map nearby (`id`, `kind`, `rarity`,
  `title`, `drop`, `placement`, `distance`, `droppedAt`, `mine`).
- `quests`: active quests starting within the radius, each with the player's
  `progress` (`stage` done, `completedAt`).
- `events`: live events with a stop within the radius, with the player's
  `progress` (`found` stop ids, `completedAt`).
- `player`: the signed-in player (see `my_player`), or null.

What shows up is decided here, so the app shouldn't filter further:

- Rarer offers show up less often: an uncommon one on about 60% of days for a
  given player, a rare one on about 30%. It's steady for the whole day.
- A quest's later stages show up only once the player has done the stage before.
- An event's stops always show up while the event is on.

Errors: `bad_location`.

## Capturing

### `capture(drop_id, lat, lng, accuracy_m = 10)`

The player captures a drop where they're standing. Pass the phone's position and
its horizontal accuracy in metres. It gives a new item when there's one to give
(an offer in stock and under its per-person limit; any other drop once), and
moves the player on in the drop's quest and any event it's a stop of.
Capturing something again still counts for a quest or event.

Returns `item` (the new item, or null), `xp` and `points` earned by this
capture, `quest` (`id`, `stage`, `stageCount`, `completed`) if it moved on,
`events` (`id`, `found`, `total`, `completed` for each), `rewards` (items given
for finishing an event) and `player`.

XP: a message 5, an object 10, an offer 20 (uncommon 50, rare 150). Each quest
stage 25 more, and finishing a quest 300 and 100 points. Events set their own
XP for each stop and for finishing (up to 100 and 1000), and points (up to 500).
Levels: level 2 at 100 XP, 3 at 300, 4 at 600 (`level_for(xp)`,
`xp_for_level(level)`).

Errors:

| Code | Meaning |
| --- | --- |
| `sign_in_needed` | Not signed in. |
| `bad_location` | No position, or not a real one. |
| `location_unclear` | Accuracy worse than 100 m. Ask them to wait for a better fix. |
| `not_available` | Not on the map now (paused, outside its hours, taken down), or not showing for this player today. |
| `own_drop` | Businesses can't capture their own drops. |
| `too_far` | More than about 40 m away (up to 70 m with poor accuracy). |
| `moving_too_fast` | Faster than 250 km/h since their last capture. |
| `limit_captures` | 100 captures in a day. |
| `quest_locked` | A later quest stage, before the one before it is done. |
| `sold_out` | The offer has run out. |
| `already_captured` | Captured before, as many times as allowed, and nothing new to count. |

## The inventory

### `my_inventory()`

The player's items: held, left on the map, and redeemed in the last 30 days.
Each item: `id`, `kind`, `rarity`, `title`, `status` (`held`, `dropped`,
`redeemed`), `source` (`capture`, `trade`, `pick_up`, `reward`), `tradeable`,
`forTrade`, `dropId`, `drop` (what the drop was when captured), `at`,
`redeemedAt`, `redemption` (`code`, `expiresAt` while a code is good) and
`onMap` (`lat`, `lng`, `expiresAt` while left on the map).

### `discard_item(item_id)`

Throws an item away. An offer goes back in its business's stock.

### `drop_item(item_id, lat, lng)`

Leaves an item on the map where the player is, for anyone to pick up. If nobody
does within 7 days it comes back to them. A player can have 20 out at once.
Errors: `item_not_found`, `item_not_available` (not held), `not_tradeable`,
`limit_dropped`.

### `pick_up_item(item_id, lat, lng, accuracy_m = 10)`

Picks up an item left on the map (5 XP, unless it was their own). Errors:
`not_available`, `too_far`, `location_unclear`.

## Redeeming an offer

1. The player taps Redeem: `start_redemption(item_id)` returns a 6-digit `code`
   good for 10 minutes (`expiresAt`), the `item`, and the `business` name.
   Asking again while it's good returns the same code. Show it large.
2. The business types the code into the website (`/redeem`), which calls
   `confirm_redemption(code)`. Only the business that made the offer can confirm
   its codes, and each works once, so a screenshot of a coupon is worth nothing.
3. Poll `my_inventory()` every few seconds while the code shows; the item's
   `status` turns `redeemed`.

Errors: `item_not_found`, `item_not_available`, `not_an_offer`, `offer_gone`
(the business's account is gone).

## Trading

Players find each other by **handle**: `set_handle(handle)` sets the player's
(3 to 20 lowercase letters, digits or `_`; errors `bad_handle`,
`handle_taken`). Nobody can see another player's inventory, which would show
where they've been: players choose items to put **up for trade** with
`set_for_trade(item_id, true)`, and others see only those.

- `player_shelf(handle)`: another player's name, level and the items they've put
  up for trade. Null if there's no such player.
- `propose_trade(to_handle, give, ask = [])`: offer 1 to 5 of your items
  (`give`, item ids) for up to 5 of theirs that are up for trade (`ask`). An
  empty `ask` is a gift. Errors: `player_not_found`, `trade_with_self`,
  `bad_trade`, `item_not_available`, `limit_trades` (10 open at once).
- `my_trades()`: open trades both ways, and those decided in the last 14 days:
  `id`, `status`, `fromMe`, `other` (`handle`, `name`), `give`, `get`, `at`,
  `expiresAt`, `decidedAt`. Trades expire after 7 days.
- `answer_trade(trade_id, accept)`: the other player accepts or declines.
  Returns `status`: `accepted`, `declined`, or `failed` if an item changed
  hands or was used since (then nothing moves). Error: `trade_not_found`.
- `cancel_trade(trade_id)`: the proposer withdraws it.

A business can make an offer untradeable: then it can't go up for trade, be
offered, or be left on the map (`not_tradeable`). Otherwise whoever holds an
offer can redeem it; the per-person limit counts captures, not trades.

## Quests

Quests are built by the database every 15 minutes from offers whose businesses
opted in: a common offer first, one or two uncommon ones, and a rare one last,
each from a different business, open at the same hours, a short walk apart.
Quests of one kind of business get a theme (`theme`, `themeName`, like "Coffee
crawl").

- `public_quest(quest_id)`, `public_quests_in_bounds(west, south, east, north)`:
  a quest's stages, in order, with each stage's drop.
- `my_quests()`: quests the player has started, unfinished first, with
  `progress`.

## Events

Businesses on the Events plan make events on the website from their own drops:
a **hunt** (find every stop, in any order) or a **trail** (in order), for a set
time. The app needs no special handling: capturing a stop counts. Show events
from `app_nearby`, and open one with `public_event(event_id)`: `title`,
`description`, `format`, `startsAt`, `endsAt`, `live`, `stopXp`, `bonusXp`,
`bonusPoints`, `reward` (the offer given for finishing, while it lasts),
`stops` (`position`, `dropId`, `drop`) and the player's `progress`.

## The player

`my_player()`: `handle`, `name`, `xp`, `points`, `level`, `levelXp` (XP the
level started at), `nextLevelXp`, `captures`, `questsDone`, `eventsDone`.

## Posting from the app

Players with a profile name and age check can post messages from the app with
the website's `save_drop(payload)` (see `lib/drops/types.ts`, `DropInput`).
Their plan's limits apply, as on the website.
