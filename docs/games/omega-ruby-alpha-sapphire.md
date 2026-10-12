# Pokemon Omega Ruby / Alpha Sapphire (3DS, Gen 6)

Adapter: `src/gen6/oras.lua` (module `gen6.oras`), v0.1. Backed methods: `revision`, `language` (heuristic, see open points), `team`, `box`, `box_count`. Not implemented (offsets unknown): location, battle, encounters, badges.

## Detection

| Game | 3DS title ID | Source |
|---|---|---|
| Omega Ruby | `000400000011C400` | matches the Memory Probe test on a real device (EUR cartridge, 2026-10-12) |
| Alpha Sapphire | `000400000011C500` | `src/core/games.lua`; not tested on a device |

Other regions of the same games may use other title IDs (open; only the IDs above are detected today).

## Revisions and addresses

3DS virtual addresses (heap `0x08000000`-`0x08CFFFFF` readable on the test setup).

| What | Address | State |
|---|---|---|
| rev2 party slot 1 | `0x08CF727C` | verified, Omega Ruby EUR Rev 2, maintainer, 2026-10-12 (checksum valid, species plausible) |
| rev2 party member 2 | `0x08CF7644` (= slot 1 + `0x3C8` = 2 x `0x1E4`) | verified once, 2 members only |
| rev2 box 1 slot 1 | `0x08C9A144` | verified, same session |
| rev0_1 party slot 1 | `0x08CFB26C` | community address, unverified (= rev2 + `0x3FF0`) |
| rev0_1 box 1 slot 1 | `0x08C9E134` | community address, unverified (= rev2 + `0x3FF0`) |

Revision is chosen at runtime: the first set (rev2, then rev0_1) whose party slot 1 decrypts with a valid checksum and species 1..721. Both sets are watched (party 6 x `0x1E4` bytes, box 31 x 30 x 232 bytes). The finding file is `notes/oras-memory/findings-2026-10-12.md` (maintainer notes, not in this repository).

Layout constants (named in `oras.lua`):

- Party: 6 slots, stride `PARTY_STRIDE = 0x1E4`, 260 bytes each. The stride is inferred from two members; order and stride are open.
- Boxes: 31 boxes x 30 slots x 232 bytes, assumed contiguous from box 1 slot 1 (as in the save block). Only box 1 slot 1 was verified; other boxes are unverified.

## PK6 format

Source: PKHeX `PKHeX.Core/PKM/PK6.cs` and `PokeCrypto.cs` (kwsch/PKHeX); cross-check Project Pokemon save structure documentation.

- Crypto: seed = first u32 (encryption constant). `seed = seed * 0x41C64E6D + 0x6073` (32 bit), each u16 is xored with `seed >> 16`. Bytes `0x08..0xE7` are crypted; the party extension `0xE8..0x103` is crypted with a fresh stream seeded by the same constant (not a continuation of the first stream). The 4 blocks of 56 bytes are shuffled by `(EC >> 13) & 31` taken modulo 24 (table in PKHeX `BlockPosition`). Checksum at `0x06` = u16 sum of all u16 in `0x08..0xE7`. The host helper `fb.codec.pk6_decrypt` does this; `tests/support/pk6_crypto.lua` re-implements it for tests only.
- Offsets used (decrypted): `0x00` EC u32, `0x06` checksum, `0x08` species u16, `0x0A` held item, `0x0C` TID, `0x0E` SID, `0x10` EXP u32, `0x14` ability, `0x18` PID u32, `0x1C` nature, `0x1D` bit0 fateful / bits1-2 gender / bits3-7 form, `0x1E`-`0x23` EVs, `0x40` nickname (UTF-16LE, 12 chars), `0x5A` moves 4 x u16, `0x74` IV32 (5 bits each hp/atk/def/spe/spa/spd, bit 30 egg, bit 31 nicknamed), `0xB0` OT name (UTF-16LE), `0xDF` origin game, `0xE3` language. Party extension: `0xE8` status u32, `0xEC` level, `0xF0` HP, `0xF2` max HP, `0xF4..` stats. All as in PKHeX PK6.cs; not independently verified on a device except species/EXP/checksum.
- Shiny: `(TID ^ SID ^ (PID >> 16) ^ (PID & 0xFFFF)) < 16`.
- Language byte (PKHeX LanguageID): 1 ja, 2 en, 3 fr, 4 it, 5 de, 6 es, 8 ko, 9 zh-Hans, 10 zh-Hant.
- The party extension of the live party is not trusted (level byte observed as garbage in Rev 2 EUR). It is parsed into `party_ext` only; `level`, `hp`, `max_hp`, `status` stay nil.

## Level from EXP

Level = highest n with `exp_for_level(rate, n) <= exp`, formulas in `src/gen6/growth.lua` (Bulbapedia "Experience"). Growth rate IDs (PKHeX PersonalInfo.EXPGrowth): 0 medium fast, 1 erratic, 2 fluctuating, 3 medium slow, 4 fast, 5 slow.

Growth rate per species is read at runtime from the user's own RomFS via `fb.rom.romfs` + `fb.codec.garc`/`garc_file` (`src/gen6/personal.lua`), cached in a Lua table only. Values to verify locally against a real RomFS (the tests use synthetic stubs):

- Path: candidates `/a/1/9/5` and `/a/1/9/6` (recollections differ, neither verified). Both are tried in order at runtime and the first that validates as a personal table is used; the accepted path is logged once at info level. To verify locally.
- Validation: either one file with length divisible by `0x50` and at least 722 entries, or at least 722 files of `0x50` bytes; the growth byte of entries 1..721 must always be 0..5. If neither path validates, no growth rate is returned.
- Entry size `0x50` (PKHeX PersonalInfoORAS). To verify locally.
- Growth byte at entry offset `0x15` (PKHeX PersonalInfoORAS.EXPGrowth). To verify locally.
- Species index = National Dex number; form-specific personal entries are not used (growth is per species).

If RomFS is unreadable (encrypted game, wrong path) `level` stays nil.

## Open points

- Party stride/order with 3 or more members, and maximum slots in live memory.
- Where live level/HP/status are kept (the `0xEC` byte is unusable at the Rev 2 party address).
- Language: no save-block offset is sourced (open). `language()` is a heuristic: party records whose origin game byte (`0xDF`) is Alpha Sapphire (26) or Omega Ruby (27) (PKHeX `GameVersion`: X 24, Y 25, AS 26, OR 27; recalled, not re-fetched) are grouped by OT ID/SID; the largest group (earliest slot on ties) is the player's own catches and its first member's language byte (`0xE3`) is returned, else nil. A Pokemon traded in from an OR/AS cartridge of another language can fool it, and it returns nil with only foreign-origin Pokemon in the party.
- Boxes beyond box 1 slot 1: contiguity and stride in live memory unverified.
- Location, battle, encounters, badges: no offsets.
- Alpha Sapphire, other regions/languages, Rev 0/1 (community addresses only), update-patch variants.
- Personal GARC path, shape and offsets (see above).
