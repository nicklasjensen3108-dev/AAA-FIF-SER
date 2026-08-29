# FIFA 13 Local FUT

> **v0.14.1.12 CL1217703 Store-parse hybrid:** keeps the v0.14.1.11 RS4/runtime-pairing backend, but replaces the failed native Store-ready experiment with the working legacy DIME/content parse path: real `storepackdescriptions` XLIFF, distinct pack backgrounds, and HTTP 200 delivery of the shipped `dimecfg.xml` / `storecfg.xml` / `storedesc-*.xml` metadata. The older test build's RS4 implementation is not imported.


Localhost-only FIFA 13 Ultimate Team revival with runtime pairing for the measured **CL1298564** and **CL1217703** PC builds.

The current `v0.14.1.12` ship candidate restores the FUT hub, Store, pack opening, club search, squad chemistry/link updates and local persistence without contacting EA FUT services. The game still supplies the UI, card art and native card database; this project supplies the local Blaze/HTTP services and local FUT state.

## What works

- FUT login and hub on the verified FIFA 13 PC build.
- Store catalogue and pack purchasing/opening.
- Base players plus FIFA 13 special variants including IF/TOTW, TOTY, TOTS, MOTM and Record Breaker cards.
- FIFA 13 duplicate detection in New Items.
- Squad editing with the working retail link-colour path and live chemistry refresh.
- Persistent local coins, club inventory, unassigned items, trade pile, squad slots and client data through SQLite.
- Normal Bronze/Silver/Gold packs contain the native FIFA 13 mix of players and non-player cards: contracts, healing, training, coin/pack cards, kits, badges, stadiums, balls, managers and staff.
- Player-only promo packs remain player-only.
- Automatic trace ZIP generation when the game closes or crashes.

## Fresh-save behaviour

The repository does **not** ship the old 12,115-card test club as owned inventory.

On first run, `save/fut13-local.sqlite3` is created locally with:

- empty club inventory;
- empty active squad slots;
- empty unassigned/trade piles;
- **100,000,000 local test coins**;
- no FIFA Points.

The complete player catalogue is still generated as the pack/search reference pool, but cards only become owned when they are actually acquired and moved into the club.

Use `RESET_LOCAL_SAVE.cmd` to return to this fresh state. Close FIFA first.

## Requirements

- Windows 10/11 x64.
- A legitimate FIFA 13 installation through the EA App/compatible installation.
- A working FIFA 13 PC installation. This release does **not** enforce a `fifa13.exe` SHA-256 allow-list.
- A CardsDLL matching the runtime build. Measured profiles:

  - CL1298564: `35BDAC6BB2F37F4E3F674C5BB979BCB607FEB11CD09105631796D566590FFC06`
  - CL1217703: `7D8A7EEAAAFEDF41EA407D497042C79E168D391D6AF5A2F692F870372284E089`

- Administrator permission for the localhost hosts redirect and local networking setup.

Python, Frida, Capstone, pefile and OpenSSL setup are handled by the prerequisite installer.
The trace proxy also runs on that same Python runtime, so users do **not** need to install a separate .NET 8 runtime or .NET SDK.

## First run

For somebody opening the repository for the first time:

1. Extract/clone the repository somewhere writable.
2. Run **`INSTALL_PREREQUISITES.cmd`** once. It checks or installs Python 3.10+, the required Python packages, Git/OpenSSL, and generates the localhost certificate files.
3. Run **`RUN_LOCAL_FUT13.cmd`**. The launcher locates FIFA 13 automatically (or asks for the `Game` directory if needed). There is **no `fifa13.exe` hash allow-list**.
4. The launcher records the installed `CardsDLLzf.dll` but does **not** force one revision before FIFA starts.
5. Launch FIFA and wait at the main menu. The local Blaze redirect reveals the real runtime build. The helper pairs `1298564 -> 35BD...FFC06` or `1217703 -> 7D8A...E089` before FUT loads. If the matching DLL is available in the installation, `required/`, or a launcher backup, it is selected automatically. Otherwise run **`IMPORT_MATCHED_CARDSDLL.cmd`** with a legally obtained matching copy and retry.
6. Wait for `LOCAL FUT13 READY`.
7. Launch FIFA 13 **through the EA App**.
8. Wait for the green `RE TRACE ALWAYS ON` line, then enter Ultimate Team. On CL1217703 the game-executable screen hooks are intentionally unavailable, but the CardsDLL/auth and HTTP trace path remains active.

After the one-time prerequisite/DLL setup, normal use is simply **`RUN_LOCAL_FUT13.cmd` → launch FIFA 13 through EA App → enter FUT**.

The launcher automatically:

- locates the installed FIFA 13 game directory without enforcing an EXE hash;
- verifies the CardsDLL build;
- backs up and swaps an incompatible CardsDLL when an optional verified copy has been imported into `required/`;
- extracts the native player and non-player FUT catalogues from your own `cards0.big`;
- generates localhost-only TLS certificate material if needed;
- creates/loads the SQLite save;
- starts the local Blaze, RS4, DIME, EASW, POW and trace services;
- installs/updates the required localhost hosts entries.

## CardsDLL handling

The **public GitHub source package intentionally does not redistribute EA's `CardsDLLzf.dll`**.

If the runtime build and installed DLL already match, nothing is copied. To import either supported measured DLL, run:

`IMPORT_MATCHED_CARDSDLL.cmd`

Select a legally obtained copy of either measured DLL. The importer refuses unknown hashes and stores the copy by build number. At the next main-menu Blaze login, the launcher detects the actual runtime build, backs up an incompatible installed DLL to `backups/game-files/`, swaps the matching verified copy if needed, and verifies it before attaching the FUT tracer.

`RESTORE_ORIGINAL_CARDSDLL.cmd` restores the newest backup created by the launcher.

A private/local test package may contain `required/CardsDLLzf.dll` for convenience. **Do not publish that file unless you have the right to redistribute it.**

## Packs and native item pool

At startup the project reads the game's own `cards0.big` / `cards_ng_db` rather than inventing EA resource IDs.

Normal packs use the FIFA 13-style distribution model:

| Pack | Items | Guaranteed rare | Player behaviour |
|---|---:|---:|---|
| Bronze | 12 | 1 | mixed |
| Premium Bronze | 12 | 3 | mixed |
| Silver | 12 | 1 | mixed |
| Premium Silver | 12 | 3 | mixed |
| Gold | 12 | 1 | mixed |
| Premium Gold | 12 | 3 | mixed |
| Premium Gold Players | 12 | 3 | players only |
| Prime Gold Players | 12 | 6 | players only |
| Rare Players | 12 | 12 | players only |
| Jumbo Rare Players | 24 | 24 | players only |

Mixed packs can contain contracts, healing, training, coin/pack consumables, kits, badges, stadiums, balls, managers and coaches/staff. Known unusable/missing-art shipped rows are filtered from the pack pool.

## Local save

SQLite is provided by Python's standard library; no separate SQLite installation is required.

Save file:

`save/fut13-local.sqlite3`

Runtime/generated files such as the save, card catalogues, local certificates, traces and machine-specific settings are ignored by Git and are not part of the public source archive.

## GitHub publishing

Before publishing, use the **GitHub source ZIP** rather than the private/local ZIP. It excludes:

- EA `CardsDLLzf.dll`;
- generated TLS private keys/certificates;
- the SQLite save;
- generated card catalogues;
- logs/traces/backups;
- machine-specific `local.settings.json`.

`PUBLISH_TO_GITHUB.cmd` can initialize the extracted source as a Git repository, show exactly what is staged, and optionally push it to a repository URL you provide.

A Windows GitHub Actions workflow performs Python compilation, PowerShell parser checks and release-hygiene checks on every push/PR.

### Crash immediately when entering FUT on another PC

If the trace shows FIFA advertising runtime build `1217703` while `CardsDLLzf.dll` is the CL1298564 `35BD...FFC06` build (or the reverse), do not keep forcing that DLL. v0.14.1.9 detects the build from the live Blaze redirect request at the main menu and pairs the matching measured CardsDLL before FUT loads. Existing launcher backups are searched automatically. v0.14.1.9 also searches nearby older release folders plus the user's Downloads/Desktop for CardsDLL-named backups and accepts them only when the SHA-256 exactly matches the runtime-required build, so extracting an update into a new folder can still recover a DLL backed up by an older release.

## Troubleshooting

### Launcher says `StartTime was null` or process metadata could not be read

Update to v0.14.1.5 or newer. Some Windows/PowerShell combinations temporarily hide `StartTime` for freshly launched hidden services. The launcher now treats that value as optional metadata and verifies services by live PID and socket ownership instead.


If FUT fails, Store/pack flow errors, or FIFA crashes, close the game normally if possible. The launcher packages an automatic `fut13-trace-*.zip`; include that ZIP when reporting the issue.

There is intentionally no `fifa13.exe` hash gate. If a particular executable revision proves incompatible, report the trace rather than adding an EXE allow-list.

If runtime pairing reports a CardsDLL mismatch, do not enter FUT. Import the matching measured DLL shown by the launcher or restore/repair the corresponding game revision, then relaunch.

### Store stuck loading on CL1217703

CL1217703 uses an older native Store state machine than CL1298564. Static analysis of the measured `7D8A...E089` DLL shows that state 2 hard-waits on the retired PC first-party-commerce/Origin wallet service (`0x0c515322` / `0x0c515323`) before the DLL can dispatch `FUTStoreReady`. That service is outside FUT/RS4, so a localhost FUT response cannot make it ready. Earlier server-only experiments (transaction config, six-pack catalogue, coins-only wallet) all completed with HTTP 200 but left the UI spinner unchanged.

v0.14.1.11 therefore adds a CL1217703-only native compatibility hook. While `/store/purchasegroup/all` is pending it prevents the absent commerce service from resetting the Store state; once the **retail pack-list callback itself** sets `[store+0x16c] = 1`, the helper redirects execution into the DLL's existing `FUTStoreReady` dispatch. Exact instruction bytes are checked before the hook is armed. CL1298564 is not modified.

## Scope

This is a local preservation/revival project. Online matchmaking, EA commerce and the original live FUT infrastructure are not restored by this release.

Protocol, item-model and persistence behaviour was cross-checked against the `fut13-revival` reference project supplied during development. Its preserved reference data retains its original license under `reference/donor-fut13-revival/LICENSE`.

## Legal

This repository is not affiliated with or endorsed by Electronic Arts. FIFA, FIFA 13 and Ultimate Team are trademarks/properties of their respective owners. The public source package does not include FIFA game executables, the EA CardsDLL, locally generated private keys, or your locally generated save/catalogue data.

### Startup diagnostics

v0.14.1.9 keeps the first-run/UAC and service-process startup hardening, uses a standard-library Python trace proxy, and now also runs the post-launch RE TRACE/compatibility helper in Python instead of spawning a second PowerShell process. This removes the `StackOverflowException` failure seen on some Windows PowerShell 5.1 machines. The visible launcher waits for a real green RE TRACE confirmation rather than giving up after 60 seconds.


## Runtime build pairing

No SHA-256 allow-list is applied to `fifa13.exe`. Windows file-version metadata is also not trusted for DLL selection. After Blaze login at the main menu, the helper reads the build number FIFA itself sent in the redirect request and pairs the corresponding measured CardsDLL before FUT is loaded. This prevents a CL1217703 executable from being forced to load the CL1298564 CardsDLL (and vice versa).


### v0.14.1.9 Windows path compatibility

Child PowerShell services and the hidden auto-attach helper now pre-quote their `-File` and path arguments before `Start-Process` hands them to Windows PowerShell 5.1. This fixes immediate RS4/service exits when the extracted package lives in a directory containing spaces (for example `Downloads\try this one`). If RS4 genuinely exits, the launcher now also includes the tail of its stderr log in the visible failure block.
