# LuaBots

Programmable robots for Luanti. A robot is a small machine that runs a Lua program you
write in-game: it moves, digs, places, crafts, chats and talks to other robots, one action
at a time. Works in any game.

Place a **Robot Base**, right-click it, write code, press **Run**:

```lua
chat.nearby("Hello")
for i = 1, 5 do
  dig.forward()
  move.forward()
end
```

The in-game manual (**Help**, English and Spanish) documents every function.
**Examples** has ready-to-run programs.

## Features

- Sequential programs: actions take time and the program waits for them.
- Sandbox for multiplayer servers: instruction and memory limits per tick, a hard CPU
  limit, bounded string functions and patterns, no globals, files, `load` or `debug`.
- Robots act as their owner: protection, locked nodes and node callbacks work as for a player.
- Levels by privilege (player, `luabots`, `luabots_admin`) with configurable limits.
- Persistent robots, inventories and `storage`.
- Full access for the server owner: the real API, and `core.register_*` callbacks that are
  removed when the robot stops, to write mods live without restarting.

## API

| Table | Functions |
|---|---|
| globals | `print sleep yield time colorize interact require` |
| `robot` | `id name run_id run_reason owner level limits used pos home facing energy hp label status skin size sound sound_stop sounds particle appearance animation display stop` |
| `move` | `forward back left right up down to` |
| `turn` | `left right around face angle` |
| `dig` / `place` | `forward back left right up down forward_up forward_down back_up back_down left_up left_down right_up right_down` |
| `sense` | `node light is_protected robot text write_text objects players find time_of_day day_count` |
| `inv` | `list slot count has free tool equip unequip swap drop put take peek lists pickup use` |
| `craft` | `make recipes` |
| `machine` | `energy burn refuel auto_refuel cook transfer` |
| `build` | `fill` |
| `blueprint` | `scan save read materials build` |
| `job` | `save load done` |
| `chat` | `nearby all owner tell listen receive` |
| `net` | `send broadcast receive find` |
| `player` | `connected pos view` |
| `punch` | `listen receive` |
| `forms` | `show close receive escape` |
| `shop` | `add remove clear list receive` |
| `screen` | `write clear` |
| `remote` | `receive` |
| `keyboard` | `set clear get receive` |
| `books` | `read write` |
| `disks` | `list load run` |
| `storage` | `get set keys clear` |
| `path` | `find` |
| `combat` | `attack hp` |
| `crypto` | `hash encrypt decrypt scramble` |
| `admin` | `is_admin get_node set_node teleport players player_info run sound particle particles particles_stop` |

Libraries: `string table math os coroutine bit vector json`.

## Commands

`/luabots list | start | stop | edit | console | unlink | track | msg | buy | info | help | stopall`
`/buy [owner/robot]` robot shops nearby (only if no other mod registers `/buy`).

Settings: see `settingtypes.txt` or the settings menu.

## API for other mods

```lua
luabots.register_api(function(bot, env)
  env.mymod = {
    hello = bot.wrap("mymod.hello", function(name)
      luabots.util.check_string(name, "name", 50)
      return "hello " .. name
    end),
  }
end)

luabots.compat.register_book_reader("mymod:book", function(stack) return title, text, author end)
```

`bot.wrap` runs the function outside the sandbox: validate every argument and never call
metamethods of program values.

## License

Code: MIT. Media: CC BY-SA 4.0. See `LICENSE.txt`.
Inspired by the `basic_robot`.