This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, most players are **props**: they hide by turning into a piece of furniture, a plant or a rock somewhere on the map and keeping still. The rest are **hunters**, who are blindfolded while the props hide and then have a few minutes to find them, with every wrong guess costing them health. This is inspired by the classic prop hunt game mode!

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Each round starts with the **hide**. The props get 30 seconds to run off and pick a spot while the hunters stand at their spawn with a black screen (they can still see their HUD and menus, just not the map or anybody on it). Then the hunters are let go and have 5 minutes.

- **Props** look at something and press **E** to become it: a chair, a bin, a houseplant, a bookcase, a pumpkin. Bigger things have more health but are easier to spot, and you need room to become them: if you're too close to a wall you're moved a step away, and if there's no room at all (or no room to stand up when you show yourself) you're told so. Turn to fit in with the arrow keys, lock your rotation with **C** so looking around doesn't turn you, and stay still. Press **Q** to take the disguise off and show yourself as your avatar, which earns a point a second while you dare; it goes back on with **Q** again, and then you have to wait a little before you can do it again.
- **Taunts.** Once the hunters are let go, press **T** to play a sound from where you are standing (or **F3** to pick one). Every taunt is worth points, but the hunters hear where it came from. Stand still for too long and the game taunts for you, with a meter on screen showing how close it is.
- **Hunters** get an SMG, a shotgun and a hatchet. Shooting a prop hurts it. Shooting real furniture hurts **you**, so guess carefully. Run out of health and you blow apart.
- **The beacon.** When only one prop is left, or with 30 seconds to go, every prop still hiding pings out a sound and a ring everybody can see, every two seconds.

The props win if any of them is still hidden when the clock runs out, or if every hunter is gone. The hunters win if they find every prop. Winning is worth 10 points to everyone on that side, finding a prop 5 and surviving a round 5. Points, rounds won, props found and the rest go to your stats and the leaderboards on TMC.

A round draws the hunters fresh: one hunter for every three players by default. Say **!hunter** or **!prop** in chat to ask for a side. Anybody who is out watches the rest of the round. After a few rounds on a map, players vote for the next one (`!rtv`, `!nominate ph_house`).

There are five maps: a small practice house built into the game, and **Maple Grove School**, **Willow Lane**, **Brightline Offices** and **Pinecrest Woods** from [mg-prop-hunt-maps](https://github.com/gamemann/mg-prop-hunt-maps).

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Move and look |
| **Space** | Jump |
| **Ctrl** | Duck |
| **E** | Become what you are looking at (props) |
| **Q** | Show yourself / hide again (props) |
| **C** | Lock your rotation (props) |
| **Arrow keys** / **Z** | Tilt and lean / stand upright again (props) |
| **T** / **F3** | Taunt / pick a taunt (props) |
| **Mouse 1** / **R** / **1**-**3** | Fire / reload / weapons (hunters) |
| **V** | Talk (voice) |
| **F5** | First or third person |
| **Tab** | Scoreboard (hold) |
| **Esc** | Settings, including every key above |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-prop-hunt
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

The maps come from the mg-prop-hunt-maps checkout, which bootstrap links into `maps/` for you. On a deployed server they come from the server instead: the game ships only its built-in practice map, and the server owner picks the maps pack (`gamemann/mg-prop-hunt-maps`, or their own) in dot-server-deploy's `cfg/content.yml`.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots (they hide when you hunt, and hunt when you hide) |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `tools/shot.sh` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect from the next round.

```
ph_hide_seconds 30             // how long the props have to hide (a map may ask for less)
ph_round_seconds 300           // how long the hunters have to find them (a map may ask for less)
ph_timeout_winner 1            // who wins when the clock runs out: 0 nobody, 1 props, 2 hunters
ph_players_per_hunter 3        // one hunter for every this many players
ph_min_hunters 1               // never fewer than this many
ph_max_hunters 8               // never more than this many
ph_hunter_pick 0               // 0 random, 1 everybody gets an equal share, 2 the sides swap
ph_side_choice 1               // 1 = !hunter and !prop count in the draw
ph_auto_taunt_seconds 45       // a prop standing still this long is taunted for (0 never)
ph_auto_taunt_radius 1.5       // metres a prop has to move for it to count as moving
ph_taunt_points 2              // points for a taunt a prop chose
ph_forced_taunt_points 0       // points for one the game forced
ph_reveal_cooldown 10          // seconds before a prop can show itself again
ph_reveal_points 1             // points a second while a prop shows itself
ph_beacon_props_left 1         // beacon every prop once this few are left (0 never)
ph_beacon_seconds_left 30      // beacon every prop with this many seconds left (0 never)
ph_decoy_penalty 0.2           // share of a shot's damage a hunter takes for hitting furniture (0 off)
ph_rounds_per_map 4            // rounds on a map before the next one
ph_spectate_camera 0           // who the dead may watch: 0 anybody, 1 their own side, 2 nobody
ph_autobhop 0                  // 1 = hold jump to keep hopping
ph_min_players 4               // fill the round with bots up to this
ph_bots 1                      // 0 = no bots
ph_bot_suspicion 12            // how often a bot hunter shoots something it suspects
ph_vote_after 20               // seconds into a map's last round before the vote opens
```

`--ph-map-ids=<ids>` limits a server to some maps, and every other setting in `game/ph_config.gd` can be given the same way (`--ph-taunt-range=80`). The taunts are listed in `taunts/taunts.json`: edit it to add your own sounds. The vote's settings go in `user://cfg/prophunt_vote.json` (`{"enabled": false}` turns it off); dot-vote's README lists them.

Console commands:

| Command | |
| --- | --- |
| `ph_status` | The round, the map, and who is hiding as what |
| `ph_maps` | The maps the server has, and any it refused (with the reason) |
| `ph_map <id>` | Play this map next |
| `ph_taunts` | The taunts |
| `ph_reload` | Read the map folder again, for the next map |
| `ph_net` | What the network code is doing |

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`. `respawn` puts somebody back at their side's spawn. `give` and `strip` are turned off, because what a hunter carries is the server's loadout and a prop carries nothing.

## Writing a map
A map is a JSON file: the building as boxes, the furniture as props, the lights, and where each side starts. The maps are in [mg-prop-hunt-maps](https://github.com/gamemann/mg-prop-hunt-maps), whose `tools/build_maps.py` writes them (a wall with its doors and windows, or a furnished classroom, is one line there). [`maps/README.md`](maps/README.md) describes the format. The server sends the map to each player when it changes, so players don't need the map files.

## Testing

```bash
./game.sh test                      # every script parses, then every suite runs
./game.sh test headless_maps        # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: the draw, hiding, disguises, taunts, decoys, the beacon, bots |
| `headless_maps` | Every map: it fits on the wire, every spawn is clear, every prop stands on something |
| `headless_net` | A server and a client in one process, over the network code: disguises, the blindfold, taunts |
| `dedicated` | A real server: boots, loads the game, runs its commands, a round of bots, the map vote |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Not done yet
- The bots are simple: a bot prop walks to the nearest thing it can be and stays there, and a bot hunter wanders and shoots what moves.
- Your own avatar from TMC is used when you show yourself, but the props themselves can't be customised.
- The round sounds (not the taunts) are made in code and are placeholders.
- Not yet tried in a browser.

## Credits
The furniture is Kenney's Furniture Kit, the trees, plants and rocks his Nature Kit, the players his Blocky Characters, and the taunts come from his Voiceover Pack and Music Jingles ([kenney.nl](https://kenney.nl), CC0). The Nature Kit's colours are toned down when the game loads them. The weapons are from [zee-dot-weapons](https://github.com/gamemann/zee-dot-weapons). Floors, walls and every other surface are drawn in code. Each kit's licence is next to its files.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
