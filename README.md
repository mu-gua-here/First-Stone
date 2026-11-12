# First Stone

A low-poly society simulator built in Godot 4. Start with a handful of tribespeople in a mud-house settlement and guide them as they gather, build, and organise themselves into a civilisation.

Play it in your browser or download it: https://mu-gua-here.itch.io/first-stone

## About
You play a character in the world, not a cursor in the sky. Walk up to trees, cut them down, grab fruit, and work alongside your citizens. Each citizen has their own name, health, energy and happiness, and you can assign them jobs such as cutting trees, gathering fruit, hauling logs and building.

What your people gather goes to the stockpiles. Logs and building materials go to one, and food goes to the other. Wood is whatever logs have actually settled in the log stockpile, and builders use those real logs. Build huts, lodges and other structures on a tile grid, then watch your settlement grow through the day/night cycle.

## Goal
The long-term goal is a society that changes as it grows, with you shaping the rules instead of micromanaging every task.

- **Policy editor** (in design): write laws in a "Legal Mad Libs" style, such as `WHEN [Age] > [12] THEN [Assign] [Forager]`, with a live preview of the population impact and cost. You reach it through a centrepiece in your settlement. It starts as a tribal campfire and grows into town halls and parliaments as the civilisation advances.
- **Fluid progression**: variables like wealth, taxation and ideology unlock as your society researches technologies and builds administrative infrastructure.
- **Saving**: persist your progress across sessions and builds.
- **Online play**: a multiplayer server for the web build.
- **Automation**: later eras bring machines such as bulldozers and trucks.

These are planned and not all of them are in the game yet. See `BUCKET_LIST.md` for the current task list.

## Controls
| Key | Action |
| --- | --- |
| Mouse drag | Orbit the camera |
| Esc | Release the mouse pointer |
| Tab | Interact mode (build cursor) |
| B | Return to building mode |
| Backspace | Delete mode (from interact mode) |
| E | Grab fruit and other small items |
| Q | Drop carried items |

You can only interact with things within a short reach of your character. Selectable objects are outlined in yellow when you are close enough.

## Platforms
Runs natively (Forward+ renderer) and on the web (Compatibility renderer). Web visuals are still being tuned to match the native build.

## Built with
- Godot 4, GDScript
- Art, audio and project structure based on Kenney's City Builder Starter Kit

## Credits
See [CREDITS.md](CREDITS.md) for full attribution of assets, fonts and addons.

## License
See [LICENSE.md](LICENSE.md). The project grew out of Kenney's Starter Kit, whose MIT notice is retained.
