# mg-prop-hunt

Hide as the furniture. Most players are props, who look at something on the map and become it; the rest are hunters, blindfolded while the props hide and then given a few minutes to find them, paying in health for every piece of real furniture they shoot.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The maps are in `maps/`, a link to [mg-prop-hunt-maps](../mg-prop-hunt-maps), written by its `tools/build_maps.py`; `maps/README.md` is the format.

**Built 2026-10-09 from mg-deathrun's skeleton** (module, services, wire, client, HUD, spectate, progress, avatars, figure, vote, renamed `dr` → `ph` and then rewritten wherever they named a course, a trap or an activator). Where a comment says "mg-wipeout found…" or "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here.

## What this game is, versus the others

The third asymmetric one, after buses and deathrun, and the first where **one side's whole move is to stop moving**. A prop's skill is choosing what to be and where; a hunter's is reading a room for the thing that is slightly wrong, and the decoy charge is what makes that a skill rather than spraying every chair.

## Layout

```
game/
  ph_config.gd       every rule a round is played under (maps are documents)
  ph_map_doc.gd      what a map IS: boxes, props by catalogue id, lights, spawns; validated
  ph_map.gd          a document built: solid boxes, furniture shapes, drawn batches, spawns
  ph_props.gd        the prop catalogue (props/catalogue.json): sizes, models, recolour, parts
  ph_materials.gd    the surfaces a box is drawn with, textures made in code
  ph_catalogue.gd    every map the server has, the built-in practice house, which is next
  ph_controller.gd   DotFpsController with the blindfold modifier
  ph_player.gd       one person: a body or a disguise, its hull, hitboxes, health, reveal, beacon
  ph_game.gd         the simulation: the draw, hide/seek, disguises, taunts, decoys, beacons, bots
  ph_rules.gd        a DotMatchRules whose outcome is whatever PhGame decided
  ph_hud.gd          the clock, hints, health, what you are, the taunt meter, the blindfold
  ph_audio.gd        the round's cues (made in code) and taunts played from a prop
  ph_client.gd       one local player, alone or against a server; third person as a prop
  ph_bindings.gd     every key, as dot-menu bindings; ph_settings.gd the Escape menu
  ph_module.gd       the DotGameModule: cvars, ph_status / ph_maps / ph_taunts / ph_map, stand-ins
  ph_services.gd     chat, voice and moderation over dot-game's base
  ph_progress.gd     stats and achievements; ph_vote.gd the map vote; ph_spectate.gd who watches whom
  net/               the codec (MAP, DISGUISE, TAUNT, DECOY…), the link, the player behaviour,
                     the bridge, and PhInterest (the blindfold on the wire)
props/               kits.json (which Kenney models, at what scale), catalogue.json (measured)
assets/props/        the vendored furniture and nature models (Kenney, CC0)
taunts/              the taunt sounds and taunts.json (Kenney, CC0); edit freely
maps/                link to ../mg-prop-hunt-maps/maps
examples/            headless_run (78), headless_maps (41), headless_net (49), dedicated (39)
tools/               shot.sh/.gd (render a view), measure_props.gd, audio_probe (xvfb only)
```

## Decision 1: a disguise is a hull, not a look

Becoming a chair changes what the controller sweeps, what the hitbox is and how much health there is, all as functions of the chair's measured size (`DotPropDisguise` in dot-props, under `DotPropDisguiseRules`): a footprint half as wide as the prop so a disguised player still fits through a door, a height clamped between 0.3 and 2.2 m, health `190 × volume^0.45` between 10 and 200, and a hurt prop that changes shape keeps its share of health. `PhPlayer.apply_disguise` writes the hull **into the controller's tunables in place**, because the motor holds that object by reference and a new one would never reach it.

**Both ends must agree, so both ends compute it from the same number.** A client predicting itself as a chair with a different capsule from the server's walks through a doorway the server's chair does not fit and is pulled back every tick. The size comes from `props/catalogue.json`, measured once offline by `tools/measure_props.gd`, because a headless server has the meshes but no business loading 163 of them to read their bounds. A DISGUISE event carries the prop, its turn and its lock; the receiving end rebuilds the hull from the catalogue. `headless_net` asserts the capsule and health equal on both ends and a running chair within 2 mm of the server's.

**A hull changes size where the player stands, so the server looks for room first** (`PhGame._make_room`): the new capsule where they are, then a step of 0.3 or 0.6 m in eight directions, never through a wall and never off a floor, and otherwise a refusal ("There is no room…"). Without it a bottle by a wall that became a bookcase, or a small prop under a table that showed its face, was a capsule inside the wall or the table, which the motor resolves differently on each machine. Found in review (2026-10-09); `headless_run`'s "a bigger hull needs room" (armed by turning the check off: three fail).

**Turning** is yaw (free, or locked with C so looking around does not turn you), tilt and lean in 15° steps up to 90°, and upright again. A lock or a tilt is the server's, asked for and announced.

## Decision 2: the blindfold is true on the wire

The HUD paints a hunter's screen black during the hide, and a modifier (`PhController.BLINDFOLD`) holds them still on exactly the ticks the server does. Neither stops a client that skips the paint. So `net/ph_interest.gd` sends a hunter's snapshots **no prop at all** during the hide, evaluated every snapshot with no linger: a prop that kept being sent for a second after the hide began would be a second of where everybody ran. `headless_net` moves a prop on the server during the hide and asserts the hunter's copy did not move, then that it is right the tick seeking starts. **What the props became is held back the same way**: a DISGUISE event goes to every peer except a hunter during the hide, and each hunter is sent all of them when the seek starts (`PhNetBridge._on_disguise_changed`, `_on_phase_changed`). Without that a blindfolded client knew "two chairs and a plant", which is half of finding them; found in review, armed (`headless_net`'s "nor what it became").

## Decision 3: a wrong guess costs, and the furniture decides what is wrong

A shot whose impacts land inside a map prop's box, and not on a player, is a decoy: the hunter takes `decoy_penalty` (20%) of the shot's damage, at least `decoy_penalty_min` (1), per pellet that hit furniture (`PhGame._charge_for_decoys`). Death by decoy blows the hunter apart (`hunter_break`, dot-player-char's `DotPlayerBodyBreak`). The client flashes on a DECOY event. **The first stand-in hunter killed itself this way in its first round**: it fired at a prop it could see through a sofa, every pellet hit the sofa, and `dedicated` reported "the hunters are gone" two seconds into the seek. A stand-in now needs a line of sight clear of furniture too, and stops guessing below 40% health.

## Decision 4: taunts are a choice with a price, and standing still is not free

`DotPropTaunts` (dot-props): **taunts start with the seek** (a taunt during the hide was no risk to the prop, and a hunter's client, told nothing about where the props are, played it from where it last saw them). A taunt plays from where the prop stands, to everybody within `taunt_range`, and pays `taunt_points`. A prop that has not moved `auto_taunt_radius` in `auto_taunt_seconds` is taunted for, at `forced_taunt_points`; the meter on the HUD fills toward it, and a voluntary taunt resets it. The list is `taunts/taunts.json`, which an owner edits.

## Decision 5: the end of a round finds the last props

With `beacon_props_left` props left or `beacon_seconds_left` seconds to go, every live prop pings: a sound and an expanding ring everybody sees (`DotFxBeacon`, dot-fx), every `beacon_period`.

## Sides, points and stats

`DotTeamRotation` (dot-team) draws the hunters: RANDOM (never the same person twice running when there is anybody else), QUEUE (everybody an equal share over time) or SWAP (last round's props hunt). `!hunter` / `!prop` / `!any` are wishes the draw honours where it can. Points: winning side 10, a find 5, surviving 5, taunts, and a point a second for a prop that shows its face (Q, `reveal_points_per_second`, paid for at most `reveal_paid_seconds`, then a `reveal_cooldown`). `PhProgress` keeps fourteen stats and eight achievements through dot-stats and dot-achievements, keyed by the player's TMC profile, and reports them when `report_progress` is on.

## Drawing a map

A map is hundreds of boxes and props. Boxes are batched by material, tint and 12 m chunk into one mesh each, because the Compatibility renderer lights a mesh with at most eight omni lights and a school as one mesh would be lit by eight of its fifty-two. Props are one `MultiMeshInstance3D` per model part. Textures are 128 px images made in code, laid in world space so boxes of a material meet without a seam.

**Kenney's Nature Kit is teal and coral by design**, and beside realistic rooms it read as a cartoon (the first school render had cyan trees with pink trunks). `props/kits.json` gives a kit a `recolour` table, material name to colour, which `PhProps` applies to a copy of each mesh as it loads. Furniture keeps its own colours except the plant.

## What running it found

- **Spawns inside sofas**: six, on three maps, because a spawn is written before a room is furnished. Found by `headless_maps`; mg-prop-hunt-maps' builder now moves them itself.
- **A pool of grass, a dark band round the gym, and washed-out daylight**: all three found by rendering, none by a check. The maps repo's CLAUDE.md has each.
- **A chair's 98 health was 97.9 on the client**: 12 bits over 0..1000 for `net_max_health`. 14 now.
- **`var rotation` on PhGame** shadowed `Node3D.rotation` and broke every transform; it is `hunter_history`.
- **dot-server-deploy had no `addons/dot_menu`** and a stale class cache, so the delivered game's client failed to parse; found by `prophunt_client` there, fixed locally.

## Validating

```bash
./game.sh test                                         # parse, then all four suites
python3 ../mg-prop-hunt-maps/tools/build_maps.py --check
xvfb-run -a godot --path . res://tools/audio_probe.tscn
tools/shot.sh --view=overview --ph-map-ids=ph_school
tools/shot.sh --view=room --ph-map-ids=ph_school --at=-38,1.7,3.5 --look=-26,0.8,14
tools/shot.sh --view=prop --as=furniture_chair_cushion --ph-map-ids=ph_house
tools/shot.sh --view=blind
tools/shot.sh --view=hunter --board --name=board
godot --headless --path . --script tools/measure_props.gd -- --check   # catalogue matches the models
```

`headless_run`'s and `headless_net`'s totals were wrong when first written and both fired; `headless_maps` was armed with a spawn put inside the practice kitchen's chair. Without `maps/` linked in (CI clones this repository alone) `headless_maps` checks the practice house only, as mg-deathrun's headless_courses does, and says so.

## Delivery

The maps are their own repository and pack, [mg-prop-hunt-maps](../mg-prop-hunt-maps): `maps/` here is a dot-bootstrap link (`.gitignore` names it), and `game.yml` does not name the pack: the server owner names `gamemann/mg-prop-hunt-maps` (or their own) in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills `DotGameDescriptor.maps`). `PhModule._add_delivered_maps` asks dot-game's `DotGameContent.map_dirs(server, "maps")` for every pack the server names, fetched through dot-cloud, and adds each mount's `maps/` to the catalogue at load and after every `ph_reload`. The game's own pack carries only `ph_practice`. A client is sent the one document being played. dot-server-deploy has `content/prophunt/`, `content/prophunt_maps/` and `examples/prophunt_client` (22 checks): the delivered pack boots, a real client joins over a real socket, the maps, prop catalogue and taunts are read from their mounts, and the client builds the server's map with every prop. No `class_name` anywhere in `game/`, because a mounted pack cannot register one.

**Before publishing**: dot-props (API level 2), dot-team (2), dot-fx (2), dot-game (3) and dot-menu must be tagged and in the client shell, or the pack fails to parse in it.

## Still to do

1. **Put it live.** Create `gamemann/mg-prop-hunt` and `gamemann/mg-prop-hunt-maps`, tag the addons above, rebuild the shell, publish the maps pack before the game.
2. **Try it in a browser**, with people: how long a hide should be and how much a decoy should cost are numbers only play settles.
3. Better stand-ins: a bot prop picks something near, not something clever.
