# EasyLFG
Make dungeon groups with ease

An addon for **World of Warcraft Forever** that builds your dungeon group from the Group Finder. You say what you want, and it invites matching players, never more than one waiting per role, so nobody gets spammed.

## What it does

- Pick the **dungeon** from the Group Finder's own list, and your own role.
- For each role (**Tank / Healer / DPS**), set:
  - how many you need,
  - the **minimum level**,
  - the **classes** you accept.
- Optionally ask for **distinct classes only**.
- EasyLFG only searches, and only reads, the listings for the dungeon you picked. Without a dungeon, it does neither.
- It reads the players who listed themselves alone for that dungeon. For each open role it picks the best match: highest level first, then the one listed longest.
- A round invites one player for each open role at the same time: a tank, a healer and a DPS at most.
- **There is never more than one invite waiting per role.** A role gets its next invite only after an answer: joined, declined, already in a group, or not found.
- A pending invite counts as a taken seat. Once a tank is invited or in the group, no other tank is asked.
- Each invite goes out together with its whisper, by default `Hi, do you wanna join for <dungeon> as <role> ?`, so "as tank", "as healer" or "as dps". You can edit the text; `<dungeon>`, `<role>` and `<name>` are filled in for each player.
- An unanswered invite closes itself on the other side after 60 seconds and comes back as a decline. If no answer arrives at all, EasyLFG gives up after 90 seconds (adjustable, at least 70).
- **Role check:** as soon as an invited tank or healer has joined, EasyLFG starts a role check so everyone confirms their role. The role picked there counts over the role the player was invited for. If someone picks another role (say a druid invited as tank picks healer), you're told, the seat they were invited for opens again, and auto mode invites a new player for it. This happens even if the group had just been reported complete. `/elfg rolecheck` starts one by hand.
- Players who declined or did not answer are not invited again this session. Use `/elfg forget`, or click the player in the list, to allow them again.
- Every player in the list shows why they fit or don't, for example "level 15, DPS needs 17" or "Rogue already in the group".

## Use

- `/elfg` opens the window. There is also an **EasyLFG** button in Blizzard's Group Finder.
- **Search** asks the Group Finder for your dungeon. Searches made in Blizzard's own window are used too.
- **Invite** sends one round: one invite per open role that has none waiting.
- **Start auto** keeps going on its own until the group is complete. As soon as a player declines, is already in a group, can't be found or doesn't answer, the next player for that role is invited right away. New search results are used straight away too.
- Key bindings are under *Key Bindings > AddOns > EasyLFG*.

**Keeping the list fresh:** after every batch of invites, EasyLFG searches the Group Finder again (for your dungeon only). In auto mode it also refreshes every 10 seconds while a role still waits for a player, never more than once every 5 seconds.

The game always allows a search from a click or a key press, so the refresh after a clicked **Invite** always works. Auto mode searches on its own, which the game may refuse. If it does, EasyLFG tells you once and stops trying for the session. Auto invites keep running, and **Search** (or its key binding) refreshes the list.

| Command | |
|---|---|
| `/elfg` | show or hide the window |
| `/elfg search` | search the Group Finder |
| `/elfg invite` | invite one matching player per open role |
| `/elfg start` / `stop` | auto invite on or off |
| `/elfg rolecheck` | ask the group to confirm their roles |
| `/elfg forget` | forget who declined or did not answer |
| `/elfg debug` | what the game allows, and what happened |

## Development

`tests/` holds a small simulated client. With Lua 5.1, run this from that folder:

```
lua test.lua . ..
```
