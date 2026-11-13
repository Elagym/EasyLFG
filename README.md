# EasyLFG
Make dungeon groups with ease

An addon for **World of Warcraft Forever** that builds your dungeon group from the Group Finder. You say what you want, and it invites matching players, never more than one waiting per role, so nobody gets spammed.

## What it does

- Pick the **dungeon** from the Group Finder's own list, and your own role.
- For each role (**Tank / Healer / DPS**), set:
  - how many you need,
  - the **minimum level**,
  - the **classes** you accept. Each role only offers the classes able to play it: Warrior, Paladin and Druid for tanks; Paladin, Priest, Shaman and Druid for healers; every class for DPS.
- Optionally ask for **distinct classes only**.
- EasyLFG only searches, and only reads, the listings for the dungeon you picked. Without a dungeon, it does neither.
- It reads the players who listed themselves alone for that dungeon. For each open role it picks the best match: highest level first, then the one listed longest.
- **One invite at a time.** The next invite only goes out after an answer: declined, already in a group, not found, or no answer in time.
- **Tanks and healers first.** EasyLFG invites a tank if one is available, else a healer, and only then a DPS.
- **After a tank or healer joins, it waits for their role.** A role check starts as soon as they're in the group, and no new invite goes out until they've confirmed their role. Until then they count as the role they were invited for, even though the game marks everyone as DPS by default. If they don't answer within 30 seconds, EasyLFG goes on and counts them as the role they were invited for. A DPS joining needs no role check, so the next invite goes out right away.
- A pending invite counts as a taken seat. Once a tank is invited or in the group, no other tank is asked.
- Each invite goes out together with its whisper, by default `Hi, do you wanna join for <dungeon> as <role> ?`, so "as tank", "as healer" or "as dps". You can edit the text; `<dungeon>`, `<role>` and `<name>` are filled in for each player.
- An unanswered invite closes itself on the other side after 60 seconds and comes back as a decline. If no answer arrives at all, EasyLFG gives up after 90 seconds (adjustable, at least 70).
- **Role check:** as soon as an invited tank or healer has joined, EasyLFG starts a role check so everyone confirms their role. It never starts one otherwise, except with `/elfg rolecheck`. The role picked there counts over the role the player was invited for. If someone picks another role (say a druid invited as tank picks healer), you're told, the seat they were invited for opens again, and auto mode invites a new player for it. This happens even if the group had just been reported complete. `/elfg rolecheck` starts one by hand.
- **Your role in the role check popup** is already selected for you: the role you chose as "I am" in EasyLFG, not the game's default DPS. Just click Accept. If your class can't play the "I am" role, the popup is left as it is.
- **"I am" only changes in the EasyLFG window.** The game marking you DPS, or picking another role in a role check, never frees your seat. If you pick a different role in a role check, EasyLFG tells you in chat so you can change "I am" if you meant it.
- Players who declined or did not answer are not invited again this session. Use `/elfg forget`, or click the player in the list, to allow them again.
- Every player in the list shows why they fit or don't, for example "level 15, DPS needs 17" or "Rogue already in the group".

## Use

- `/elfg` opens the window. There is also an **EasyLFG** button in Blizzard's Group Finder.
- **Search** asks the Group Finder for your dungeon. Searches made in Blizzard's own window are used too.
- The **+** button on a player's row whispers and invites that player, for the open role they fit, then refreshes the list.
  - It's greyed out when the player doesn't fit your rules, while another invite waits for its answer, or while a tank or healer who just joined hasn't confirmed their role. Hovering it says why.
  - Clicking the row offers "Invite anyway" for players outside the rules.
- **Start auto** keeps going on its own until the group is complete. As soon as a player declines, is already in a group, can't be found, doesn't answer, or has joined (as a tank or healer: once they've confirmed their role), the next player is invited right away. New search results are used straight away too.
- Key bindings are under *Key Bindings > AddOns > EasyLFG*.

**Keeping the list fresh:** after every invite, EasyLFG searches the Group Finder again (for your dungeon only).
- **While nobody is listed for a role you still need**, it searches again every 5 seconds until someone is. It does this in auto mode, and also with auto off while the EasyLFG window is open. With auto off, you get a message and a sound when a match shows up ("Tank found: …"). In auto mode they're invited right away.
- Otherwise, auto mode refreshes every 10 seconds while a seat is open.
- EasyLFG never searches more than once every 5 seconds. If the server rejects a search (too many searches), automatic searches pause for 15 seconds.

The game always allows a search from a click or a key press, so the refresh after a clicked **+** always works. Auto mode searches on its own, which the game may refuse. If it does, EasyLFG tells you once and stops trying for the session. Auto invites keep running, and **Search** (or its key binding) refreshes the list.

| Command | |
|---|---|
| `/elfg` | show or hide the window |
| `/elfg search` | search the Group Finder |
| `/elfg invite` | invite the next matching player: tank, then healer, then DPS (also a key binding) |
| `/elfg start` / `stop` | auto invite on or off |
| `/elfg rolecheck` | ask the group to confirm their roles |
| `/elfg forget` | forget who declined or did not answer |
| `/elfg log` | show what EasyLFG did |
| `/elfg debug` | what the game allows, and what happened |

## Log

The **Log** button (or `/elfg log`) shows every action EasyLFG took, one timestamped line each:
- the rules in use and the dungeon chosen;
- each search and what it found;
- each invite, with the exact whisper sent;
- each answer, and how long it took;
- role checks, the roles picked in them, and how long EasyLFG waited for each joiner's role;
- auto mode turning on and off;
- anything the game blocked, and any errors.

The same line repeated is counted instead of written again. The last 500 lines are kept, also after a reload. **Select all**, then Ctrl+C, copies the log to share it.

## Development

`tests/` holds a small simulated client. With Lua 5.1, run this from that folder:

```
lua test.lua . ..
```
