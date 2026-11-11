# EasyLFG
Make dungeon groups with ease

An addon for **World of Warcraft Forever** that builds your dungeon group from the Group Finder. You say what you want, and it invites matching players one at a time, so nobody gets spammed.

## What it does

- Pick the **dungeon** from the Group Finder's own list, and your own role.
- For each role (**Tank / Healer / DPS**), set:
  - how many you need,
  - the **minimum level**,
  - the **classes** you accept.
- Optionally ask for **distinct classes only**.
- EasyLFG reads the players who listed themselves alone for that dungeon and ranks them: the hardest role to find first, then the highest level.
- Each invite starts with a short whisper, by default `Hi, do you wanna join for <dungeon> ?`. You can edit it; `<dungeon>`, `<role>` and `<name>` are filled in for each player.
- EasyLFG waits for an answer (joined, declined, already in a group, not found, or no answer in time) before it invites the next player.
- Players who decline are not asked again for a while.
- Every player in the list shows why they fit or don't, for example "level 15, DPS needs 17" or "Rogue already in the group".

## Use

- `/elfg` opens the window. There is also an **EasyLFG** button in Blizzard's Group Finder.
- **Search** asks the Group Finder for your dungeon. Searches made in Blizzard's own window are used too.
- **Invite next** invites the best match.
- **Start auto** keeps inviting on its own, with a pause between invites, until the group is complete.
- Key bindings are under *Key Bindings > AddOns > EasyLFG*.

The game only allows a Group Finder search from a click or a key press. In auto mode, when nobody fits any more, EasyLFG waits for your next search.

| Command | |
|---|---|
| `/elfg` | show or hide the window |
| `/elfg search` | search the Group Finder |
| `/elfg next` | invite the next matching player |
| `/elfg start` / `stop` | auto invite on or off |
| `/elfg forget` | forget who declined or did not answer |
| `/elfg debug` | what the game allows, and what happened |

## Development

`tests/` holds a small simulated client. With Lua 5.1, run this from that folder:

```
lua test.lua . ..
```
