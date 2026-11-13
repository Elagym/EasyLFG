# EasyLFG
Make dungeon groups with ease

An addon for **World of Warcraft Forever** that builds your dungeon group from the Group Finder. You say what you want, and it invites matching players one at a time, so nobody gets spammed.

## What it does

- Pick the **dungeon** from the Group Finder's own list, and your own role.
- For each role (**Tank / Healer / DPS**), set:
  - how many you need,
  - the **minimum level**,
  - the **classes** you accept. Each role only offers the classes able to play it: Warrior, Paladin and Druid for tanks; Paladin, Priest, Shaman and Druid for healers; every class for DPS.
- Optionally ask for **distinct classes only**.
- EasyLFG only searches, and only reads, the listings for the dungeon you picked. Without a dungeon, it does neither.
- It reads the players who listed themselves alone for that dungeon. For each open role it picks the best match: highest level first, then the one listed longest.
- **One invite at a time.** The next invite only goes out after an answer: joined, declined, already in a group, not found, or no answer in time.
- **Tanks and healers first.** EasyLFG invites a tank if one is available, else a healer, and only then a DPS.
- **Everyone counts as the role they were invited for.** EasyLFG remembers each player by name with the role it invited them for, so a tank who joins is your tank, even though the game marks everyone as DPS by default. Nothing waits for a role check: the next invite goes out as soon as someone has joined.
- A pending invite counts as a taken seat. Once a tank is invited or in the group, no other tank is asked.
- Each invite goes out together with its whisper, by default `Hi, do you wanna join for <dungeon> as <role> ?`, so "as tank", "as healer" or "as dps". You can edit the text; `<dungeon>`, `<role>` and `<name>` are filled in for each player.
- An unanswered invite closes itself on the other side after 60 seconds and comes back as a decline. If no answer arrives at all, EasyLFG gives up after 90 seconds (adjustable, at least 70).
- **One role check, once the group is full**, so the game shows everyone's role. If someone picks a different role there than the one they were invited for (say a druid invited as tank picks healer), you're told in chat, but EasyLFG keeps counting them as invited and invites nobody new. Players EasyLFG didn't invite, such as friends already in your group, count as the game shows them. `/elfg rolecheck` starts a role check by hand.
- **Your role in the role check popup** is already selected for you: the role you chose as "I am" in EasyLFG, not the game's default DPS. Just click Accept. If your class can't play the "I am" role, the popup is left as it is.
- **"I am" only changes in the EasyLFG window.** The game marking you DPS, or picking another role in a role check, never frees your seat. If you pick a different role in a role check, EasyLFG tells you in chat so you can change "I am" if you meant it.
- Players who declined or did not answer are not invited again this session. Use `/elfg forget`, or click the player in the list, to allow them again.
- Every player in the list shows why they fit or don't, for example "level 15, DPS needs 17" or "Rogue already in the group".

## Use

- `/elfg` opens the window. There is also an **EasyLFG** button in Blizzard's Group Finder.
- **The Group panel**, beside the window, shows the group being formed, one line per seat: tanks first, then healers, then DPS. Each line shows the role icon and the player's name, then where that seat stands:
  - **you**;
  - **in group**;
  - **joining**: accepted, but the game doesn't show them in the group yet;
  - **invited**, with the seconds left for an answer;
  - **wanted**, for a seat still open.

  Its title shows the group size, then "complete" or "auto". It sits on the window's right, or on its left when the screen has no room.
- **Search** asks the Group Finder for your dungeon. Searches made in Blizzard's own window are used too.
- The **+** button on a player's row whispers and invites that player, for the open role they fit, then refreshes the list.
  - It's greyed out when the player doesn't fit your rules, or while another invite waits for its answer. Hovering it says why.
  - Clicking the row offers "Invite anyway" for players outside the rules.
- **Start auto** keeps going on its own until the group is complete. As soon as a player declines, is already in a group, can't be found, doesn't answer, or has joined, the next player is invited right away. New search results are used straight away too.
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
| `/elfg demo` | open or close the demo window (made-up players) |
| `/elfg debug` | what the game allows, and what happened |

## Demo

`/elfg demo` opens a separate demo window, with an orange border, where you can try EasyLFG with made-up players. The demo is always on in that window: opening it starts the demo, and closing it ends the demo. **Nothing is sent to the game**: no search, no whisper, no invite, no role check. The demo window uses your real settings, so a change you make there stays.

- The list fills with about 14 made-up players for the dungeon you picked. Pick another dungeon and a new list is made for it. They have mixed classes, levels and roles, and some don't fit your rules. New ones list themselves every half minute or so.
- **+** and **Start auto** work as usual. Each made-up player answers after a few seconds: joins, declines, is already in a group, or lets the invite run out.
- Players who join make up a pretend group in the Group panel, and the role check is answered by them once the group is full. Your own role check popup isn't shown.
- The window shows **DEMO**, and chat messages and log lines are marked `[demo]`.
- The demo ends when you close its window: the close button, Escape, `/elfg` or `/elfg demo` again. A logout or `/reload` ends it too. Your real list, who you asked, and your group's roles all come back. Opening the main window closes the demo window.

The demo can't tell you whether the game allows EasyLFG's searches and invites; only real play shows that.

## Log

The **Log** button (or `/elfg log`) shows every action EasyLFG took, one timestamped line each:
- the rules in use and the dungeon chosen;
- each search and what it found;
- each invite, with the exact whisper sent;
- each answer, and how long it took;
- role checks and the roles picked in them;
- auto mode turning on and off;
- anything the game blocked, and any errors.

The same line repeated is counted instead of written again. The last 500 lines are kept, also after a reload. **Select all**, then Ctrl+C, copies the log to share it.

## Development

`tests/` holds a small simulated client. With Lua 5.1, run this from that folder:

```
lua test.lua . ..
```
