# Games

Per-game adapter documentation. Adapter status: **v0.1 adapter** = `team`/`box` readable; **detected** = recognized by the game table (`src/core/games.lua`), no adapter yet; **open** = identification not yet designed.

| Gen | Game | System | Detection code | Adapter |
|---|---|---|---|---|
| 1 | Red / Blue / Yellow | GB | open | identification open |
| 2 | Gold / Silver / Crystal | GB/GBC | open | identification open |
| 3 | Ruby | GBA | `AXV` (+ region letter) | detected, no adapter |
| 3 | Sapphire | GBA | `AXP` | detected, no adapter |
| 3 | FireRed | GBA | `BPR` | detected, no adapter |
| 3 | LeafGreen | GBA | `BPG` | detected, no adapter |
| 3 | Emerald | GBA | `BPE` | detected, no adapter |
| 4 | Diamond | NDS | `ADA` | detected, no adapter |
| 4 | Pearl | NDS | `APA` | detected, no adapter |
| 4 | Platinum | NDS | `CPU` | detected, no adapter |
| 4 | HeartGold | NDS | `IPK` | detected, no adapter |
| 4 | SoulSilver | NDS | `IPG` | detected, no adapter |
| 5 | Black | NDS | `IRB` | detected, no adapter |
| 5 | White | NDS | `IRA` | detected, no adapter |
| 5 | Black 2 | NDS | `IRE` | detected, no adapter |
| 5 | White 2 | NDS | `IRD` | detected, no adapter |
| 6 | X | 3DS | `0004000000055D00` | detected, no adapter |
| 6 | Y | 3DS | `0004000000055E00` | detected, no adapter |
| 6 | Omega Ruby | 3DS | `000400000011C400` | v0.1 adapter ([doc](omega-ruby-alpha-sapphire.md)) |
| 6 | Alpha Sapphire | 3DS | `000400000011C500` | v0.1 adapter, untested on device ([doc](omega-ruby-alpha-sapphire.md)) |
| 7 | Sun | 3DS | `0004000000164800` | detected, no adapter |
| 7 | Moon | 3DS | `0004000000175E00` | detected, no adapter |
| 7 | Ultra Sun | 3DS | `00040000001B5000` | detected, no adapter |
| 7 | Ultra Moon | 3DS | `00040000001B5100` | detected, no adapter |

NDS/GBA codes are the first three characters of the 4-character game code; the fourth is the region letter (language is derived from it). Gen 8 is out of scope. Gen 3 needs a GBA core in FrameBeam first.
