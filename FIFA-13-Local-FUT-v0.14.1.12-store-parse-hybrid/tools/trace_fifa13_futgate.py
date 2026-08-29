#!/usr/bin/env python3
"""Capture the whole FUT bootstrap: every HTTP request plus the FutCfg gate.

The timing problem that blocked every earlier attempt is solved by ordering,
not by cleverness:

  * spawning fifa13.exe under Frida kills it (it must come up through EA
    Desktop), and attaching at process birth kills it too, because the client
    decrypts its own .text during startup;
  * attaching once the client sits idle at the main menu is harmless;
  * and if the Blaze bridge is started only *after* that point, the entire FUT
    bootstrap — config fetches, downloads, launcher decision — happens later
    still, inside the window we control.

So: game to the main menu with no bridge, attach this, then start the bridge.

It hooks the wire (ws2_32) and the three FIFA 13 gate functions, so whichever
path submits the failing "fut*" transfer, either its request line or its
completion callback is recorded.

Read-only. Run from an elevated PowerShell.

    python tools/trace_fifa13_futgate.py
    python tools/trace_fifa13_futgate.py --seconds 900 --log artifacts/run.jsonl
"""
from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import frida

# rva -> (name, first bytes from the decrypted memory dump)
TARGETS = [
    ("FutLaunchStatus", 0x004EBDA0, "55 8b ec 83 ec 0c 53 56"),
    ("FUTCfgFileDownloadResult", 0x004EC320, "55 8b ec 8b 45 0c 56 6a"),
    ("FutCfgParser", 0x0057FEF0, "55 8b ec 81 ec 14 01 00"),
    ("DownloadQueue", 0x00511110, "55 8b ec 57 8b f9 e8 b5"),
    # cfgrouting.xml parsing: the whole-file parser, plus the per-entry reject
    # path. If entries are being thrown away, RoutingEntryReject fires and the
    # routing table stays empty — which is exactly what "service fut cancelled"
    # would look like from the outside.
    ("RoutingParse", 0x0077E1B0, "55 8b ec 81 ec e4 01 00"),
    ("RoutingEntryReject", 0x0077D8B4, "8b 45 ec 2b c3 83 f8 01"),
    # The launcher's final gate. Reached only once cfgFileOk=1, installed=1 and
    # updateRequired=0 — which is now the case. A negative return produces
    # OSDK_CLUBS_LOAD_ERR; a non-negative one produces ENTER_FUT2_OK and loads
    # CardsDLLzf.dll. The return code says which of its five exits was taken:
    #   -2  [obj+0x114] != 0 (busy/already loaded)
    #   -1  no DLC exposing "fut_dll", or FUT/FAKE_CARDS0_FAIL, or a cards
    #       archive present with a null handle
    ("CardsLoadGate", 0x004EBFB0, "55 8b ec 81 ec 1c 01 00"),
    # Every branch of the launcher converges here to dispatch its popup key, with
    # the key already pushed: at this address [esp] holds the string pointer.
    # The gate now returns 0, so the launcher should be choosing ENTER_FUT2_OK —
    # reading the key proves which branch really ran instead of inferring it.
    # DISABLED — this hook is a suspect, not a witness.
    # 0x00A42C2B is `mov edx,[esi]`, two bytes; an inline hook needs about five
    # and relocates what it displaces. The member trace shows ENTER_FUT2_OK being
    # set to 0 during initialisation and the write of 1 — which happens in the
    # very call this address guards — never reaching SetMemberInt at all, while
    # the *next* instruction's SetMemberString does fire. That is what a broken
    # relocation looks like. Re-enable only after confirming the failure
    # reproduces without it.
    # ("PopupDispatch", 0x00642C2B, "8b 16 8b 42 04 8b ce ff"),
    # Fut2Adapter::EnterFUT2 itself. helperfunctions.big calls it with no
    # arguments and branches on the ENTER_FUT2_OK member of the object it fills;
    # PopupDispatch above fires once per member it sets, so bracketing the call
    # separates "the launcher refused" from "the launcher succeeded and futMain
    # failed later". Both show the SAME empty popup from outside, because every
    # failure key is a localization key that does not resolve here.
    ("EnterFUT2", 0x00642A40, "55 8b ec 83 ec 10 56 8b"),
    # The archive/resource loader. arg0 is a path, strncpy'd into a 0x100 buffer
    # at 0x0129AB9C. On the success branch the ActionScript does
    # loadMovie("external/ion_fut/main/futMain.swf"), which the engine resolves
    # to data/ui/external/ion_fut/main/futmain.big — so this hook is what
    # separates "futMain never loaded" from "futMain loaded and then failed".
    ("ResourceOpen", 0x00E9AB80, "55 8b ec 81 ec 38 01 00"),
    # The config store's typed getters, __thiscall with ECX = the manager that
    # 0x0050C5D0 returns (that address is a plain singleton accessor and ignores
    # the pushed arguments — they belong to the getter that follows it).
    # Reading these answers, once and for all, WHICH of the keys the bridge
    # serves through Util::fetchClientConfig the client actually consults and
    # what value it ends up with. IsUltimateTeamAvailable (0x00952020) reaches
    # its futStatus branch, which proves FUT_ENABLE_MENU is not arriving as 1.
    ("ConfigGetInt", 0x0010DAA0, "55 8b ec 56 57 68 60 9f"),
    ("ConfigGetString", 0x0010CFD0, "55 8b ec 56 57 68 60 9f"),
    # The ION_Fut2 methods the ActionScript can actually call. Their registration
    # is at 0x0101D3F0: each entry pushes a thunk, wraps it (0x004C75C0), then
    # registers it under its name (0x004D0CE0). All dispatch through the adapter
    # vtable at [0x02748DCC]. Hooking them is the closest thing to watching the
    # ActionScript run — the APT trace sink is not reachable from here.
    #   EnterFUT2 0x0100D000 (vtable+0x14) is the same call our EnterFUT2 hook
    #   already brackets, so it is left out.
    # THE discriminator. helperFunctions' failure branch calls
    # ION_OnlineSession.FUTFailLoginRecovery() and nothing else does; the success
    # branch only does createEmptyMovieClip + loadMovie. Since no movie-load for
    # futMain is ever dispatched, this separates the last two possibilities:
    #   it fires      -> the ActionScript read ENTER_FUT2_OK as falsy despite the
    #                    native setting it to 1, and took the failure branch;
    #   it stays quiet -> the success branch ran and the load silently produced
    #                    nothing.
    # Registered at 0x0101ED65 (thunk 0x01011C70, name string 0x0243A7C0).
    ("Fut_FailLoginRecovery", 0x00C11C70, "8b 0d 94 90 74 02 8b 01"),
    # The ActionScript-facing EnterFUT2 thunk. It initialises the wrapper at
    # 0x026927E4 (0x004FB870 stores a fresh AS object in [wrapper+4] via
    # 0x004C74E0), calls the adapter, then returns [wrapper+4] as the AS value.
    # Every member setter writes through [wrapper+4] too, so if that pointer is
    # null the whole object silently evaporates: the native trace still shows
    # ENTER_FUT2_OK being set, while the ActionScript receives undefined, reads
    # undefined.ENTER_FUT2_OK as falsy, and takes the failure branch — which is
    # exactly what the 1 ms gap between LAUNCHER-DECISION and FUTFailLoginRecovery
    # looks like. 0x004C74E0 returns 0 when its 0x20-byte pool allocation fails.
    ("Fut2_EnterFUT2Thunk", 0x00C0D000, "b9 e4 27 69 02 e8 66 e8"),
    # The member setters the adapter writes through — vtable slots +4 (int) and
    # +0x10 (string) of the wrapper. They forward to SetMember(asObject, &name,
    # value) with asObject = [wrapper+4]. Reading them live is the only honest way
    # to see what the ActionScript object actually receives: dumping the object
    # after the attempt shows it empty, but so would a perfectly working object
    # that has since been reset — the same "measure during, not after" trap the
    # archive-mount question already sprang once tonight.
    ("SetMemberInt", 0x000FB750, "55 8b ec 8b 45 08 56 8b"),
    ("SetMemberString", 0x000FB820, "55 8b ec 8b 45 08 56 57"),
    ("Fut2_ExitFUT", 0x00C0D030, "8b 0d cc 8d 74 02 8b 01"),
    ("Fut2_GetDownloadingCfg", 0x00C0D0C0, "55 8b ec 51 6a 00 e8 15"),
    ("Fut2_DirectBootFUT", 0x00C0D100, "55 8b ec 51 8b 0d cc 8d"),
    # The Scaleform APT parser: arg0 is the raw movie payload and the function
    # opens by checking its header ("Apt Data:1:..." — [arg0+8] == ':' and
    # [arg0+9] == '1'). Every screen the game loads passes through here, which
    # answers the question the archive-loader hook could not: whether futMain
    # is actually loaded after ENTER_FUT2_OK. Screens are told apart by the
    # 16 bytes at +0x10 (see apt_fingerprints below) — the header itself is
    # identical for all of them.
    ("AptParse", 0x000DC000, "55 8b ec 83 ec 14 53 8b"),
    # The movie-load dispatch, one level above AptParse on the chain a
    # Thread.backtrace recovered from a real screen load. Screen loads are
    # *queued* and drained per frame (0x01C701F0 / 0x01C71AC0), so this is the
    # point where a queued request finally becomes a parse. Hooking it separates
    # "no load request for futMain was ever dispatched" from "one was dispatched
    # and died before the parser".
    ("MovieLoadDispatch", 0x000DE680, "55 8b ec 8b 45 08 8b 4d"),
    # The screen-event dispatchers: native -> ActionScript. Both build
    # "Handle_" + event name (prefix string at 0x0234BF24) and call the global
    # the APT registered through Register_GlobalFunctionReference, so they carry
    # LoginToFUT, FUTCfgFileDownloadResult, FutDllUnloaded, ShowLoadingIcon...
    # Arguments are (scope, event, payload vector), the same shape the FIFA 14
    # revival project hooks — that project's agent is what pointed at this
    # dispatcher as the way to watch the flow without an APT trace sink.
    ("ScreenEventA", 0x000FE460, "55 8b ec 81 ec 14 02 00"),
    ("ScreenEventB", 0x000FE540, "55 8b ec 81 ec 14 02 00"),
    # The archive layer. MountCardsArchives is the one place cards0.big and
    # cards_patch.big — the archive holding every FUT screen — are mounted:
    #   if (ArchiveExists("cards0.big"))      [0x02738068] = ArchiveMount(...)
    #   if (ArchiveExists("cards_patch.big")) [0x0273806C] = ArchiveMount(...)
    # Single caller 0x0095A45D, guarded only by "cards0 not yet mounted".
    # Measured: both mount correctly during a FUT attempt, and both are released
    # again by 0x008EBF60 on the way out — so a file-lock test taken afterwards
    # reads as "never mounted" and is misleading.
    ("MountCardsArchives", 0x004EBF10, "68 08 ea 39 02 e8 a6 ef"),
    ("ArchiveExists", 0x00E9AEC0, "55 8b ec 5d e9 e7 15 31"),
    ("ArchiveMount", 0x00E9EB40, "55 8b ec 8b 45 0c 8b 4d"),
]


def apt_fingerprints() -> dict[str, str]:
    """Map the 16 bytes at +0x10 of each extracted APT to its screen name.

    Built from analysis/extracted/apt rather than hardcoded, so extracting a new
    screen is enough to make the tracer name it.
    """
    from pathlib import Path as _Path

    import json as _json

    extracted = _Path(__file__).resolve().parents[1] / "analysis" / "extracted"

    # The full table, built once by scanning every screen in every archive, names
    # 1600 distinct APTs. Small APTs collide (3824 of them share bytes with a
    # sibling) and are recorded as "a|b"; futmain's is unique, which is what
    # matters. Fall back to whatever happens to be extracted under apt/.
    catalogue = extracted / "apt-fingerprints.json"
    if catalogue.is_file():
        return _json.loads(catalogue.read_text(encoding="utf-8"))

    table = {}
    root = extracted / "apt"
    if root.is_dir():
        for directory in sorted(root.iterdir()):
            payload = directory / "0.apt"
            if payload.is_file():
                table[payload.read_bytes()[0x10:0x20].hex()] = directory.name
    return table

AGENT = r"""
'use strict';

const TARGETS = %TARGETS%;
const CARDS_BUILD = %CARDS_BUILD%;
const CARDS_PROFILE = (CARDS_BUILD === '1217703')
  ? {name: 'retail-cl1217703-7d8', AuthRequestBuild: 0x68a00, ChemistryGlobal: 0x1ade48,
     StoreStateFrame: 0x306a0, StoreCommerceGate: 0x306c1,
     StoreReadyDispatch: 0x30745, StoreReleaseGate: 0x30779,
     StoreFrameContinue: 0x30789}
  : {name: 'stock-cl1298564-35bd', AuthRequestBuild: 0x69f00, ChemistryGlobal: 0x1b0e78};

function ipv4(sockaddr) {
  try {
    if (sockaddr.readU16() !== 2) return null;
    const port = (sockaddr.add(2).readU8() << 8) | sockaddr.add(3).readU8();
    const o = [4, 5, 6, 7].map(function (i) { return sockaddr.add(i).readU8(); });
    return o.join('.') + ':' + port;
  } catch (error) { return null; }
}

function head(pointer, length) {
  try {
    const bytes = pointer.readByteArray(Math.min(length, 8192));
    if (bytes === null) return null;
    const view = new Uint8Array(bytes);
    let out = '';
    for (let i = 0; i < view.length; i += 1) {
      const c = view[i];
      out += (c >= 0x20 && c <= 0x7e) ? String.fromCharCode(c) : (c === 0x0a ? ' | ' : (c === 0x0d ? '' : '.'));
    }
    return out;
  } catch (error) { return null; }
}

// The name argument came back null with readUtf8String, so decode defensively:
// dump the raw bytes and try both encodings. The pointer may also be a struct
// whose first field is the string, hence the extra one-level dereference.
function describe(pointer) {
  const out = {ptr: pointer.toString()};
  if (pointer.isNull()) return out;
  try {
    const raw = pointer.readByteArray(48);
    if (raw !== null) {
      const v = new Uint8Array(raw);
      let hex = '', asc = '';
      for (let i = 0; i < v.length; i += 1) {
        hex += ('0' + v[i].toString(16)).slice(-2) + ' ';
        asc += (v[i] >= 0x20 && v[i] <= 0x7e) ? String.fromCharCode(v[i]) : '.';
      }
      out.hex = hex.trim();
      out.ascii = asc;
    }
  } catch (error) { out.readError = String(error); }
  try { out.utf8 = pointer.readUtf8String(64); } catch (error) {}
  try { out.utf16 = pointer.readUtf16String(64); } catch (error) {}
  try {
    const inner = pointer.readPointer();
    if (!inner.isNull()) {
      try { out.deref_utf8 = inner.readUtf8String(64); } catch (error) {}
    }
  } catch (error) {}
  return out;
}

function text(pointer) {
  try {
    const v = pointer.readUtf8String(120);
    return v === null ? null : v.replace(/[^\x20-\x7e]/g, '.');
  } catch (error) { return null; }
}

// ---- wire ----------------------------------------------------------------
// Frida 17 dropped the static Module.getExportByName(module, name): calling it
// throws "TypeError: not a function" and takes the whole agent down before a
// single event is recorded. Resolve through whichever form this runtime has.
function exportByName(moduleName, name) {
  try {
    const m = Process.getModuleByName(moduleName);
    if (m && typeof m.getExportByName === 'function') {
      const a = m.getExportByName(name);
      if (a) return a;
    }
  } catch (error) {}
  try {
    if (typeof Module.getExportByName === 'function') {
      const a = Module.getExportByName(moduleName, name);
      if (a) return a;
    }
  } catch (error) {}
  try {
    if (typeof Module.getGlobalExportByName === 'function') {
      const a = Module.getGlobalExportByName(name);
      if (a) return a;
    }
  } catch (error) {}
  return null;
}

// The launcher now returns 0 from its final gate, so it should be loading the
// FUT plug-in. Hook LdrLoadDll rather than LoadLibraryEx: EA's own loader maps
// its *zf.dll modules without going through the Win32 wrapper, which is why an
// earlier LoadLibraryExW trace only ever saw DINPUT8.dll.
// CardsDLL loads but then emits nothing at all — no HTTP, no 404 — so it fails
// inside its own initialisation. These RVAs come from the Ghidra pass in
// debug/cardsdll-analysis.txt. The module only appears mid-session, so hook it
// from the loader callback once it is mapped.
const CARDS_RVA = {
  PlugInitialize: 0x3640,
  PlugInit_stage1: 0x2ab0,
  PlugInit_stage2: 0x2ee0,
  LoginToFUT: 0x23e90,
  RS4UrlConfig: 0x53e10,
  // Returns the config object RS4UrlConfig then queries. The whole FUT URL
  // setup is gated on HasKey("FUT_RS4_BASE_URL") — vtable slot +0x74 on that
  // object, with GetString at +0x18 (RVA 0x53E51 / 0x53E7B). Hooking the object
  // getter lets the slots be resolved and hooked at runtime, which is the only
  // way to see which keys CardsDLL asks for and what it is told.
  GetConfigObject: 0x108b0,
  // The /ut/auth request builder. Found by walking back from the references to
  // the SKU "395A0001" (0x10069FBD), nucleusPersonaId (0x1006A071),
  // identification (0x1006A1E0) and deviceId (0x1006A186) to the enclosing
  // prologue. If this never runs, the client is failing a precondition before it
  // even composes the authentication request — which is what "no socket is ever
  // opened" points at.
  // v0.13.20: this package now runs the STOCK EA-App CL1298564 CardsDLL
  // (SHA-256 35BD...FFC06), which is the exact build the donor parser/RVAs
  // were recovered from. Its real AuthRequestBuild prologue is 0x69F00
  // (push ebp; mov ebp,esp; sub esp,0x26c). The old 7D8 CL1217703 DLL
  // used a different layout and must never receive these offsets.
  AuthRequestBuild: 0x69f00
};

// v0.4 read-only instrumentation for the two remaining unknowns.
//
// Chemistry: the RS4 trace proves FIFA itself calculates aggregate values and
// sends them in PUT /squad/1 (35 -> 50 -> 56 in the v0.3.1 run). These native
// entry points tell us whether the value subsequently reaches the UI/team model
// and whether per-player chemistry is being calculated separately.
//
// Store: v0.3.1 crashes at CardsDLL+0x3CC4A with ECX/this == 0xF. Hook the
// containing function from its prologue (+0x3CC00), plus the localization parser
// and its nearby value-application routine, so the next crash tells us which
// object becomes invalid before the fault. READ ONLY: no return/register writes.
const CARDS_DIAGNOSTIC_RVA = {
  // These RVAs are the actual ActionScript registration targets from the
  // legacy 7D8A...E089 CardsDLL registration tables (diagnostic-only; not installed on stock) (v0.4 had two labels one
  // slot out: SetTeamName and GetAllPlayerCardFormationCoords).
  GetCurrentSquadChemistry: 0x9a760,
  CalculateOppChemistry: 0x9a780,
  SetCurrentSquadChemistry: 0x9a7a0,
  GetCurrentSquadFormation: 0x9a7c0,
  GetTeamChemistry: 0xa07a0,
  GetPlayerChemistry: 0xa3e10,
  GetLinksValue: 0xa3c60
};

// Underlying native service methods used by the ActionScript wrappers above.
// Hook the METHOD ENTRY rather than a mid-function instruction: previous Frida
// experiments showed that arbitrary mid-function detours can destabilize this
// old 32-bit client. The method return in EAX is the raw value before CardsDLL's
// ActionScript conversion layer.
const CARDS_CHEM_SERVICE_METHODS = [
  {name: 'GetCurrentSquadChemistry', global: 0x1b0e78, slot: 0x30},
  {name: 'CalculateOppChemistry', global: 0x1b0e78, slot: 0x34},
  {name: 'SetCurrentSquadChemistry', global: 0x1b0e78, slot: 0x38},
  {name: 'GetCurrentSquadFormation', global: 0x1b0e78, slot: 0x3c},
  {name: 'GetTeamChemistry', global: 0x1ae0e8, slot: 0x20},
  {name: 'GetLinksValue', global: 0x1ae2a8, slot: 0x28},
  {name: 'GetPlayerChemistry', global: 0x1ae2a8, slot: 0x30}
];

function ptrValue(p) {
  try { return p.toString(); } catch (e) { return null; }
}

function intValue(p) {
  try { return p.toInt32(); } catch (e) { return null; }
}

function maybeCString(p) {
  try {
    if (!p || p.isNull()) return null;
    const n = p.toUInt32();
    if (n < 0x10000) return null;
    const s = p.readCString(160);
    if (s === null) return null;
    // Avoid dumping binary buffers that merely happen to contain a zero.
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c < 0x09 || (c > 0x0d && c < 0x20)) return null;
    }
    return s;
  } catch (e) { return null; }
}

// The two credential gates inside the /ut/auth JSON builder (0x69F00):
//   0x1006A218  test esi,esi                  -> EASW-Session
//   0x1006A25E  test esi,esi                  -> EASW-Token
// ESI carries the credential string obtained just before from 0x100108B0 ->
// [vtable+0x30]('dwps') -> [vtable+0x44]. When it is null the branch skips the
// field and the request is never serialised — the FIFA 14 project documents this
// as the exact abort. READ ONLY for now: report ESI, change nothing. These are
// two-byte instructions followed by a six-byte je, the same shape as the
// PopupDispatch hook that silently broke the call it was watching, so the first
// run has to prove the hooks are inert before any substitution is attempted.
const CARDS_CREDENTIAL_GATES = [
  {name: 'EASW-Session', rva: 0x6a218},
  {name: 'EASW-Token', rva: 0x6a25e}
];

// The two game-side services PlugInit_stage1 fetches by hash and caches:
//   DAT_101AC288  <- (*plug+0x20)(0x834C5B0) then (+0xc)(0x88941A8)
//   DAT_101AC28C  <- (*plug+0x20)(0x83458EC) then (+0xc)(0x8894198)
// 0x101AC288 is the config service — stage1 immediately calls its +0x20 slot
// with "Global". So 0x101AC28C is the other one, and since CardsDLL imports no
// network API at all (MSVCR100 + KERNEL32 only), it is the transport the
// composed /ut/auth request is handed to. Hooking its vtable shows which call
// receives the request and what it answers.
const CARDS_TRANSPORT_RVA = 0x1ac28c;

// The event factory every Cards callback funnels through, called as
//   (eventName, resultCode, -1)
// cdecl, so at entry [esp]=eventName, [esp+4]=resultCode, [esp+8]=int.
//
// This is THE measurement for the Icebreaker question. RequestGamerCustomInfo
// ends at 0x100784A8 with a single byte test:
//   cmp byte [rec+0x5a],1 / jne  ->  "CARDS_CB_ERR_CLUB_NAME_CHANGE_REQUIRED"
//                                    else "NO_INFO"
// and futmain turns the first into CLUB_NAME_CHANGE=true (-> CHANGE_CLUBNAME)
// and the second into CUSTOM_DATA_AVAILABLE=false (-> ContinueToCreateClub,
// which always lands on ICEBREAKER_PACKSELECT because SkipIceBreaker() is the
// constant false). Reading the two strings here settles which path runs without
// inferring anything from the screen.
//
// It is a function ENTRY, not a mid-function instruction -- the shape that
// broke PopupDispatch. Read only: nothing is written.
const CARDS_EVENT_RVA = 0x4f070;
let cardsHookedBase = null;
let cardsModule = null;

// v0.13.11 donor-parity rule: keep Store and link rendering free of runtime
// Interceptors. After auth, the only persistent CardsDLL hook is the measured
// aggregate-chemistry getter refresh; it does not touch Store or link methods. The working donor build explicitly records that even an
// observation-only probe beside the Store's points gate was enough to break a
// purchase. Our previous tracer had dozens of chemistry, config, event and
// transport Interceptors active while the Store was constructing its objects.
//
// The ONE compatibility shim still required in this local setup is the EASW
// credential provider: our dwps service returns NULL for EASW-Session and
// EASW-Token, so without substituting those two strings CardsDLL never emits
// /ut/auth. Hook those providers only for the duration of AuthRequestBuild,
// then detach the credential listeners before the FUT UI starts.
function hookCardsDll() {
  const mod = Process.enumerateModules().find(function (m) {
    return m.name.toLowerCase().indexOf('cardsdll') !== -1;
  });
  if (mod === undefined) return;
  if (cardsHookedBase !== null && cardsHookedBase.equals(mod.base)) return;

  cardsHookedBase = mod.base;
  cardsModule = mod;
  send({kind: 'cardsdll-found', base: mod.base.toString(), size: mod.size,
        path: mod.path, mode: 'donor-parity-minimal', profile: CARDS_PROFILE.name});

  // v0.14.1.11 CL1217703 Store compatibility.
  //
  // The older 1217703 CardsDLL has a hard native dependency on FIFA's
  // first-party commerce service (service ids 0x0c515322 / 0x0c515323) in its
  // state-2 Store frame. That service was supplied by the old Origin wallet,
  // not by FUT/RS4, so there is no HTTP/Blaze response the localhost backend
  // can send to make it ready. The measured sequence is:
  //   StoreStateFrame +0x21 -> first-party commerce lookup
  //   async pack-list callback -> [store+0x16c] = 1 on success
  //   FUTStoreReady dispatch -> +0xa5 in the same frame function
  // Without the commerce service the retail function resets [store+0x14] to 0
  // before the pack-list callback can publish readiness, leaving the AS2 Store
  // spinner waiting forever.
  //
  // Do NOT patch bytes. Instead, on CL1217703 only, redirect two measured
  // instruction boundaries at runtime:
  //   * while pack-list state is 2 (pending), skip the unavailable Origin
  //     commerce block but leave Store state 2 intact;
  //   * once pack-list state is 1 (success), jump to the retail FUTStoreReady
  //     dispatch already present in this exact DLL;
  //   * skip the commerce-interface Release only for the synthetic null EDI.
  // This is gated by exact instruction bytes and by the real pack-list success
  // field, so it cannot publish an empty/unparsed Store. CL1298564 is untouched.
  function installCl121StoreCompatibility() {
    if (CARDS_BUILD !== '1217703') return;

    function matches(address, expected) {
      try {
        const raw = address.readByteArray(expected.length);
        if (raw === null) return false;
        const view = new Uint8Array(raw);
        for (let i = 0; i < expected.length; i += 1) {
          if (view[i] !== expected[i]) return false;
        }
        return true;
      } catch (error) {
        return false;
      }
    }

    const frame = mod.base.add(CARDS_PROFILE.StoreStateFrame);
    const commerceGate = mod.base.add(CARDS_PROFILE.StoreCommerceGate);
    const readyDispatch = mod.base.add(CARDS_PROFILE.StoreReadyDispatch);
    const releaseGate = mod.base.add(CARDS_PROFILE.StoreReleaseGate);
    const frameContinue = mod.base.add(CARDS_PROFILE.StoreFrameContinue);

    const checks = [
      ['frame', frame, [0x55, 0x8b, 0xec, 0x83, 0xec, 0x08]],
      ['commerce-gate', commerceGate, [0xe8, 0x2a, 0xde, 0xfe, 0xff]],
      ['ready-dispatch', readyDispatch, [0xe8, 0xe6, 0xcb, 0xfe, 0xff]],
      ['release-gate', releaseGate, [0x8b, 0x07, 0x8b, 0x50, 0x04]]
    ];
    const failed = checks.filter(function (entry) {
      return !matches(entry[1], entry[2]);
    }).map(function (entry) { return entry[0]; });

    if (failed.length !== 0) {
      send({kind: 'store121-compat', status: 'signature-mismatch', failed: failed});
      return;
    }

    let pendingLogged = false;
    let readyLogged = false;
    let releaseSkipLogged = false;

    try {
      Interceptor.attach(commerceGate, function () {
          try {
            const store = this.context.esi;
            if (!store || store.isNull() || store.toUInt32() < 0x10000) return;
            const state = store.add(0x14).readS32();
            const listState = store.add(0x16c).readS32();
            if (state !== 2) return;

            if (listState === 2) {
              // The async /store/purchasegroup/all request is still pending.
              // Retail CL1217703 would ask Origin commerce here and reset the
              // Store state to zero when that service is absent. Keep state 2
              // alive until the real pack-list callback completes instead.
              this.context.edi = ptr('0');
              this.context.pc = frameContinue;
              if (!pendingLogged) {
                pendingLogged = true;
                send({kind: 'store121-flow', phase: 'waiting-pack-list',
                      store: store.toString(), state: state, listState: listState});
              }
              return;
            }

            if (listState === 1) {
              // The native response callback has parsed the pack catalogue and
              // explicitly published success. At this point the only missing
              // prerequisite is the dead Origin commerce service. Enter the
              // DLL's own FUTStoreReady dispatch path.
              this.context.edi = ptr('0');
              this.context.pc = readyDispatch;
              if (!readyLogged) {
                readyLogged = true;
                send({kind: 'store121-flow', phase: 'dispatch-fut-store-ready',
                      store: store.toString(), state: state, listState: listState});
              }
            }
          } catch (error) {
            send({kind: 'store121-flow', phase: 'gate-error', error: String(error)});
          }
      });

      Interceptor.attach(releaseGate, function () {
          try {
            // Our compatibility path deliberately has no Origin commerce
            // interface to Release. Skip only when EDI is the null sentinel we
            // supplied above; retail paths with a real interface are untouched.
            if (this.context.edi && this.context.edi.isNull()) {
              this.context.pc = frameContinue;
              if (!releaseSkipLogged) {
                releaseSkipLogged = true;
                send({kind: 'store121-flow', phase: 'skip-null-commerce-release'});
              }
            }
          } catch (error) {
            send({kind: 'store121-flow', phase: 'release-error', error: String(error)});
          }
      });

      send({kind: 'store121-compat', status: 'installed',
            frame: frame.toString(), commerceGate: commerceGate.toString(),
            readyDispatch: readyDispatch.toString(), releaseGate: releaseGate.toString()});
    } catch (error) {
      send({kind: 'store121-compat', status: 'install-failed', error: String(error)});
    }
  }

  // v0.14.1.12 hybrid: leave the unsuccessful native CL121 Store force-ready
  // shim disabled. The Store now follows the legacy DIME/XML parse path imported
  // from the working 7D8 test build; RS4 remains the v0.14.1.11 implementation.
  // installCl121StoreCompatibility();

  // v0.13.16 Store policy for CL1298564 remains: NO Store code patching.
  //
  // v0.13.10 through v0.13.14 proved that repairing +0x3CC4A, its caller,
  // or a trampoline around either site only moved/corrupted the failure.
  // Keep retail Store instructions byte-for-byte untouched and satisfy the
  // FIFA 13 RS4 contracts instead. The temporary EASW credential shim below
  // remains scoped to AuthRequestBuild because the local Blaze/EASW service
  // still returns NULL there; it detaches before the FUT UI/Store runs.
  const credentialValues = {
    'EASW-Session': Memory.allocUtf8String('FUT13-LOCAL-EASW-SESSION'),
    'EASW-Token': Memory.allocUtf8String('FUT13-LOCAL-EASW-TOKEN')
  };
  const providerListeners = [];
  let providersInstalled = false;
  let authListener = null;

  function detachCredentialListeners(reason) {
    while (providerListeners.length > 0) {
      const listener = providerListeners.pop();
      try { listener.detach(); } catch (error) {}
    }
    providersInstalled = false;
    if (authListener !== null) {
      try { authListener.detach(); } catch (error) {}
      authListener = null;
    }
    send({kind: 'cardsdll-auth-hooks-detached', reason: reason});
  }

  // v0.13.11 chemistry: keep the now-correct retail link-colour path
  // completely untouched. The 21:21 trace shows only the aggregate is stale:
  // each PUT /squad/1 carries the chemistry from the PREVIOUS rearrangement.
  // v0.13.9 already measured the real fix: service vtable+0x38 recomputes and
  // stores the aggregate. Arm exactly one hook, on the service's current-
  // chemistry getter (+0x30), and run that native recompute immediately before
  // the getter reads the field. No GetLinksValue/GetPlayerChemistry hooks.
  let chemistryRefreshHookInstalled = false;
  let chemistryRefreshRetry = null;
  let chemistryRefreshInProgress = false;
  let chemistryRefreshCount = 0;

  function installChemistryRefreshHook(attempt) {
    if (chemistryRefreshHookInstalled) return;
    try {
      const service = mod.base.add(CARDS_PROFILE.ChemistryGlobal).readPointer();
      if (!service || service.isNull()) throw new Error('service-null');
      const vtable = service.readPointer();
      if (!vtable || vtable.isNull()) throw new Error('vtable-null');
      const getterTarget = vtable.add(0x30).readPointer();
      const recalcTarget = vtable.add(0x38).readPointer();
      if (!getterTarget || getterTarget.isNull() || !recalcTarget || recalcTarget.isNull()) {
        throw new Error('method-null');
      }

      const recalc = new NativeFunction(recalcTarget, 'void', ['pointer'], 'thiscall');
      Interceptor.attach(getterTarget, {
        onEnter: function () {
          if (chemistryRefreshInProgress) return;
          chemistryRefreshInProgress = true;
          try {
            // Use the live ECX if it is sane, otherwise the singleton resolved
            // above. Both are the same service on the measured retail build.
            let liveService = this.context.ecx;
            if (!liveService || liveService.isNull() || liveService.toUInt32() < 0x10000) {
              liveService = service;
            }
            const before = liveService.add(0x38).readS32();
            recalc(liveService);
            const after = liveService.add(0x38).readS32();
            chemistryRefreshCount++;
            send({kind: 'chem-native-refresh', count: chemistryRefreshCount,
                  reason: 'current-chemistry-read', service: liveService.toString(),
                  target: recalcTarget.toString(), before: before, after: after});
          } catch (error) {
            send({kind: 'chem-native-refresh-failed', reason: 'current-chemistry-read',
                  error: String(error)});
          } finally {
            chemistryRefreshInProgress = false;
          }
        }
      });
      chemistryRefreshHookInstalled = true;
      if (chemistryRefreshRetry !== null) {
        clearTimeout(chemistryRefreshRetry);
        chemistryRefreshRetry = null;
      }
      send({kind: 'chem-refresh-hook', status: 'installed-minimal',
            getter: getterTarget.toString(), recalc: recalcTarget.toString(),
            service: service.toString()});
    } catch (error) {
      if ((attempt || 0) < 40) {
        chemistryRefreshRetry = setTimeout(function () {
          installChemistryRefreshHook((attempt || 0) + 1);
        }, 250);
      } else {
        send({kind: 'chem-refresh-hook', status: 'failed', error: String(error)});
      }
    }
  }

  function installCredentialProviders() {
    if (providersInstalled) return;
    try {
      const getConfigObject = new NativeFunction(mod.base.add(CARDS_RVA.GetConfigObject),
                                                 'pointer', []);
      const configObject = getConfigObject();
      if (configObject.isNull()) throw new Error('config object is null');

      const getService = new NativeFunction(configObject.readPointer().add(0x30).readPointer(),
                                            'pointer', ['pointer', 'uint32'], 'thiscall');
      const dwps = getService(configObject, 0x73707764); // 'dwps'
      if (dwps.isNull()) throw new Error('dwps service is null');
      const vtable = dwps.readPointer();

      [['EASW-Session', 0x40], ['EASW-Token', 0x44]].forEach(function (entry) {
        const label = entry[0];
        const fn = vtable.add(entry[1]).readPointer();
        const listener = Interceptor.attach(fn, {
          onLeave: function (retval) {
            if (retval.isNull()) {
              retval.replace(credentialValues[label]);
              send({kind: 'cards-credential', gate: label,
                    value: credentialValues[label].readCString(),
                    is_null: true, substituted: true});
            } else {
              let text = null;
              try { text = retval.readCString(64); } catch (error) { text = '<unreadable>'; }
              send({kind: 'cards-credential', gate: label, value: text,
                    is_null: false, substituted: false});
            }
          }
        });
        providerListeners.push(listener);
      });
      providersInstalled = true;
      send({kind: 'cards-credential-providers', status: 'hooked-temporarily',
            vtable: vtable.toString()});
    } catch (error) {
      send({kind: 'cards-credential-providers', status: 'failed', error: String(error)});
    }
  }

  try {
    authListener = Interceptor.attach(mod.base.add(CARDS_PROFILE.AuthRequestBuild), {
      onEnter: function () {
        installCredentialProviders();
        send({kind: 'cardsdll-auth-build', phase: 'enter'});
      },
      onLeave: function (retval) {
        send({kind: 'cardsdll-auth-build', phase: 'leave', ret: retval.toInt32()});
        // All provider reads used by this request occur inside the builder.
        // Detach NOW so chemistry, squad rendering and Store execute on retail
        // CardsDLL code with no Frida Interceptors in the DLL.
        detachCredentialListeners('auth-request-complete');
        installChemistryRefreshHook(0);
      }
    });
    send({kind: 'cardsdll-donor-parity', status: 'only-auth-shim-armed'});
  } catch (error) {
    send({kind: 'cardsdll-hook-failed', fn: 'AuthRequestBuild', error: String(error)});
  }
}

const ldrLoadDll = exportByName('ntdll.dll', 'LdrLoadDll');
if (ldrLoadDll !== null) {
  Interceptor.attach(ldrLoadDll, {
    onEnter: function (args) {
      try {
        const unicodeString = args[2];
        const length = unicodeString.readU16();
        const buffer = unicodeString.add(4).readPointer();
        this.name = buffer.readUtf16String(length / 2);
        if (this.name !== null) send({kind: 'module-load', name: this.name});
      } catch (error) { this.name = null; }
    },
    onLeave: function () {
      if (this.name && this.name.toLowerCase().indexOf('cardsdll') !== -1) hookCardsDll();
    }
  });
}
// In case the plug-in is already mapped when the tracer attaches.
hookCardsDll();

const connectPtr = exportByName('ws2_32.dll', 'connect');
if (connectPtr !== null) {
  Interceptor.attach(connectPtr, {
    onEnter: function (args) {
      const to = ipv4(args[1]);
      if (to !== null) send({kind: 'connect', to: to});
    }
  });
} else {
  send({kind: 'wire-warning', missing: 'ws2_32!connect'});
}

const recentHttpSockets = {};
['send', 'WSASend'].forEach(function (name) {
  const address = exportByName('ws2_32.dll', name);
  if (address === null) { send({kind: 'wire-warning', missing: 'ws2_32!' + name}); return; }
  Interceptor.attach(address, {
    onEnter: function (args) {
      let body = null;
      const socketId = args[0].toString();
      if (name === 'send') body = head(args[1], args[2].toInt32());
      else {
        try {
          const b = args[1];
          body = head(b.add(Process.pointerSize).readPointer(), b.readU32());
        } catch (e) { body = null; }
      }
      if (body === null) return;
      if (/^(GET|POST|HEAD|PUT|DELETE|PATCH) /.test(body)) {
        recentHttpSockets[socketId] = Date.now() + 3000;
        send({kind: 'http-request', via: name, socket: socketId, data: body});
      } else if (recentHttpSockets[socketId] && recentHttpSockets[socketId] >= Date.now()) {
        const trimmed = body.replace(/^\s+/, '');
        if (/^[{[<]/.test(trimmed))
          send({kind: 'http-request-body-chunk', via: name, socket: socketId, data: body});
      }
    }
  });
});

// ---- FUT gate ------------------------------------------------------------
const fifa = Process.enumerateModules().find(function (m) {
  return m.name.toLowerCase() === 'fifa13.exe';
});

function matches(address, signature) {
  try {
    const want = signature.split(' ').map(function (b) { return parseInt(b, 16); });
    const got = new Uint8Array(address.readByteArray(want.length));
    for (let i = 0; i < want.length; i += 1) if (got[i] !== want[i]) return false;
    return true;
  } catch (error) { return false; }
}

if (fifa === undefined) {
  send({kind: 'ready', wire: true, gate: false, reason: 'fifa13.exe not found'});
} else {
  const at = {};
  const resolved = {};
  const bad = [];
  TARGETS.forEach(function (t) {
    const a = fifa.base.add(t.rva);
    at[t.name] = a;
    const ok = matches(a, t.signature);
    resolved[t.name] = {address: a.toString(), matched: ok};
    if (!ok) bad.push(t.name);
  });

  if (bad.length > 0) {
    send({kind: 'ready', wire: true, gate: false, reason: 'signature mismatch',
          mismatches: bad, targets: resolved});
  } else {
    Interceptor.attach(at.DownloadQueue, {
      onEnter: function (args) {
        send({kind: 'download-queued', name: text(args[0]),
              arg0: describe(args[0]), arg1: describe(args[1]),
              ecx: describe(this.context.ecx)});
      }
    });
    Interceptor.attach(at.FUTCfgFileDownloadResult, {
      onEnter: function (args) {
        send({kind: 'futcfg-download-callback', success_flag: args[0].toInt32(),
              name: text(args[1]), length: args[3].toInt32(),
              // Dump every argument: the name read back null, so the ABI guess
              // (success, name, buffer, length) needs confirming from the bytes.
              a0: describe(args[0]), a1: describe(args[1]),
              a2: describe(args[2]), a3: describe(args[3]),
              ecx: describe(this.context.ecx),
              caller: this.returnAddress.toString()});
      }
    });
    Interceptor.attach(at.FutCfgParser, {
      onEnter: function (args) {
        send({kind: 'futcfg-parser', length: args[1].toInt32(), preview: text(args[0])});
      }
    });
    // FutLaunchStatus is __thiscall, so ECX is the FUT manager on entry. Dump the
    // four dwords the FutCfg parser must fill (0x0097FFB7-0x0097FFD9 requires all
    // four non-zero) plus the state bytes, instead of guessing which XML field
    // feeds which offset. fut_version is known to land in +0x11c; +0x120 is the
    // value handed to the requiredVersionAvailable check at 0x008EBEC3.
    let lastFields = null;
    Interceptor.attach(at.FutLaunchStatus, {
      onEnter: function () {
        try {
          const self = this.context.ecx;
          lastFields = {
            this_: self.toString(),
            f11c: self.add(0x11c).readU32(),
            f120: self.add(0x120).readU32(),
            f140: self.add(0x140).readU32(),
            f148_dimeUniqueId: self.add(0x148).readU32(),
            f154_futKeyType: self.add(0x154).readU32(),
            b13c_inProgress: self.add(0x13c).readU8(),
            b14d_cfgLoaded: self.add(0x14d).readU8(),
            b14e_errorA: self.add(0x14e).readU8(),
            b14f_errorB: self.add(0x14f).readU8()
          };
        } catch (error) { lastFields = {error: String(error)}; }
      },
      onLeave: function (retval) {
        // Three call sites exist (0x8ec3d5 in the download-result path, 0x9520ba
        // in IsUltimateTeamAvailable, 0xa42ad2 inside EnterFUT2). Without the
        // return address the four late queries can only be guessed at.
        let from = null;
        try { from = this.returnAddress.sub(fifa.base).toString(); } catch (error) {}
        send({kind: 'fut-launch-status', value: retval.toInt32(), from_rva: from, fields: lastFields});
      }
    });

    // PopupDispatch hook removed with its target (see TARGETS): it sat on a
    // two-byte instruction inside the call that writes ENTER_FUT2_OK = 1.

    // Brackets the whole launcher decision. What the member setters report
    // between enter and leave is now the only account of what it decided.
    Interceptor.attach(at.EnterFUT2, {
      onEnter: function () { send({kind: 'enter-fut2', phase: 'enter'}); },
      onLeave: function () { send({kind: 'enter-fut2', phase: 'leave'}); }
    });

    // Far too noisy to report wholesale — the engine opens thousands of assets.
    // Only the FUT module and its screens matter here.
    Interceptor.attach(at.ResourceOpen, {
      onEnter: function (args) {
        let path = null;
        try { path = args[0].readCString(); } catch (error) { return; }
        if (!path) return;
        const low = path.toLowerCase();
        if (low.indexOf('fut') === -1 && low.indexOf('ion_fut') === -1
            && low.indexOf('cards') === -1 && low.indexOf('gamehub') === -1) return;
        send({kind: 'resource-open', path: path});
      }
    });

    // Config reads. The store is consulted constantly, so report only the keys
    // this project actually serves or depends on.
    const CONFIG_INTEREST = /FUT|POW|DIME|ROUTING|CARDS|STORE|EASW|LOCALE\/SKU|BLAZE/i;

    // v0.13.16 donor parity: powdllzf.dll is a separate web-service client from
    // CardsDLL's FUT RS4 client. The working donor advertises these four URLs;
    // our compiled bridge predates that discovery. Reuse the config getter hook
    // that is already present for tracing instead of adding another interceptor
    // or touching any Store function. The allocated strings live for the whole
    // agent lifetime.
    const CONFIG_STRING_OVERRIDE_TEXT = {
      // Full FIFA 13 EASW surface from the working donor. v0.13.15 only
      // advertised the AUTH key, so fifa13.exe never enabled the service and
      // never made the native /v2/authentication request. FUT_URI belongs to
      // fifa13.exe; CardsDLL's RS4 client is independently pinned by the
      // FUT_RS4_* keys and therefore remains on localhost:8099.
      'FUT_URI': 'http://127.0.0.1:19501/fut',
      'OSDK_EASW_AUTH_URL': 'http://127.0.0.1:19502/easw/auth',
      'OSDK_EASW_REQ_URL': 'http://127.0.0.1:19503/easw/req',
      'OSDK_EASW_EVENT_URL': 'http://127.0.0.1:19504/easw/event',
      'OSDK_EASW_MEDIA_URL': 'http://127.0.0.1:19505/easw/media',
      'OSDK_EASW_GF_FILE_URL': 'http://127.0.0.1:19506/easw/gf',
      'FUT/ROSTERUPDATE_URL': 'http://127.0.0.1:19507/fut/roster',
      'OSDK_EASW_CONNECT_RETRY_PERIOD': '30',
      // Exact four-character wildcard. fifa13.exe rejects five-character
      // locale tokens and silently disables EASW when this does not match.
      'OSDK_EASW_ALLOWED_LOCALES': '****',
      'FIFA_POW_URL': 'http://127.0.0.1:19512/',
      'FIFA_POW_NUCLEUS_PROXY_URL': 'http://127.0.0.1:19513/',
      'FIFA_POW_CONTENT_SERVER_URL': 'http://127.0.0.1:19514/',
      'FIFA_POW_MMM_URI': 'http://127.0.0.1:19515/'
    };
    const CONFIG_STRING_OVERRIDES = {};
    Object.keys(CONFIG_STRING_OVERRIDE_TEXT).forEach(function (key) {
      CONFIG_STRING_OVERRIDES[key] = Memory.allocUtf8String(CONFIG_STRING_OVERRIDE_TEXT[key]);
    });

    // These are exact donor configuration values. They are applied through the
    // existing read-only config observer rather than by touching Store code.
    // The bridge already advertises them, but the FIFA-side config store has
    // repeatedly returned its compiled defaults instead (e.g. FUT_ENABLE_MENU
    // was observed as 0). Force only the three Store/menu switches that the
    // donor explicitly relies on; leave every chemistry/link setting alone.
    const CONFIG_INT_OVERRIDES = {
      'FUT_ENABLE_MENU': 1,
      'USE_LOCAL_CFGFILES': 0,
      'FUT/STORE_USE_TRANSACTION': 0
    };

    function configHook(address, label, decode) {
      Interceptor.attach(address, {
        onEnter: function (args) {
          this.key = null;
          try {
            const key = args[0].readCString();
            if (key && CONFIG_INTEREST.test(key)) this.key = key;
          } catch (error) {}
        },
        onLeave: function (retval) {
          if (this.key === null) return;
          if (label === 'config-string' && CONFIG_STRING_OVERRIDES[this.key]) {
            const text = CONFIG_STRING_OVERRIDE_TEXT[this.key];
            retval.replace(CONFIG_STRING_OVERRIDES[this.key]);
            send({kind: 'config-string-override', key: this.key, value: text,
                  reason: 'donor-full-easw-pow-parity'});
          }
          if (label === 'config-int' && Object.prototype.hasOwnProperty.call(CONFIG_INT_OVERRIDES, this.key)) {
            const value = CONFIG_INT_OVERRIDES[this.key];
            retval.replace(ptr(value));
            send({kind: 'config-int-override', key: this.key, value: value,
                  reason: 'donor-store-config-parity'});
          }
          send({kind: label, key: this.key, value: decode(retval)});
        }
      });
    }
    ['ScreenEventA', 'ScreenEventB'].forEach(function (which) {
      Interceptor.attach(at[which], {
        onEnter: function (args) {
          try {
            const event = args[1].readCString();
            if (!event || event === 'updateTimeCount') return;   // per-frame noise
            const payloads = [];
            const vector = args[2];
            if (!vector.isNull()) {
              for (let i = 0; i < 8; i++) {
                const item = vector.add(i * Process.pointerSize).readPointer();
                if (item.isNull()) break;
                payloads.push(item.readCString());
              }
            }
            send({kind: 'screen-event', dispatcher: which,
                  scope: args[0].readCString(), event: event, payloads: payloads});
          } catch (error) {}
        }
      });
    });

    // NOT hooked: 0x01C72D10. It appeared in the backtrace of a screen load, but
    // tracing it showed it fires EVERY FRAME on the same object (0x15F05CD0) and
    // carries no string in its first 0x220 bytes — it is a per-frame update that
    // happens to sit on the load path, not a per-screen initialiser. Hooking it
    // produced 1000+ empty events and no information. The screen name has to come
    // from somewhere else on that chain.

    // Report the payload each dispatch carries, identified the same way as
    // AptParse so the two can be lined up: a dispatch with futmain's fingerprint
    // and no matching parse means the load died in between.
    Interceptor.attach(at.MovieLoadDispatch, {
      onEnter: function (args) {
        const found = [];
        for (let index = 0; index < 5; index++) {
          try {
            const value = args[index];
            if (value.isNull()) continue;
            if (value.readCString(8) === 'Apt Data') {
              const bytes = new Uint8Array(value.add(0x10).readByteArray(16));
              let hex = '';
              for (let i = 0; i < bytes.length; i++) hex += ('0' + bytes[i].toString(16)).slice(-2);
              found.push('arg' + index + ':apt:' + hex);
              continue;
            }
            const text = value.readCString(64);
            if (text && text.length >= 4 && /^[\x20-\x7e]+$/.test(text)) found.push('arg' + index + ':' + text);
          } catch (error) {}
        }
        send({kind: 'movie-load', payload: found});
      }
    });

    Interceptor.attach(at.MountCardsArchives, {
      onEnter: function () { send({kind: 'cards-archives', phase: 'enter'}); },
      onLeave: function () {
        let cards0 = null, patch = null;
        try {
          cards0 = fifa.base.add(0x2738068 - 0x400000).readU32();
          patch = fifa.base.add(0x273806c - 0x400000).readU32();
        } catch (error) {}
        send({kind: 'cards-archives', phase: 'leave',
              cards0_handle: cards0, cards_patch_handle: patch});
      }
    });

    const futWrapper = fifa.base.add(0x026927e4 - 0x400000);
    function wrapperObject() {
      try { return futWrapper.add(4).readU32(); } catch (error) { return null; }
    }
    Interceptor.attach(at.Fut2_EnterFUT2Thunk, {
      onEnter: function () { send({kind: 'fut2-thunk', phase: 'enter', as_object: wrapperObject()}); },
      onLeave: function (retval) {
        send({kind: 'fut2-thunk', phase: 'leave',
              as_object: wrapperObject(), returned: retval.toUInt32()});
      }
    });

    [['SetMemberInt', false], ['SetMemberString', true]].forEach(function (entry) {
      const which = entry[0], isText = entry[1];
      Interceptor.attach(at[which], {
        onEnter: function (args) {
          this.key = null;
          this.kind = null;
          try {
            const name = args[0].readCString();
            if (!name) return;

            if (/^ENTER_FUT2/.test(name)) {
              this.key = name;
              this.kind = 'fut2-member';
              this.value = isText ? args[1].readCString(64) : args[1].toInt32();
              return;
            }

            if (!isText && name === 'RESULT_COLOUR') {
              this.key = name;
              this.kind = 'chem-as-result-colour';
              this.value = args[1].toInt32();
            }
          } catch (error) {}
        },
        onLeave: function () {
          if (!this.key) return;
          if (this.kind === 'chem-as-result-colour') {
            send({kind: this.kind, key: this.key, value: this.value});
          } else {
            send({kind: 'fut2-member', setter: which, key: this.key,
                  value: this.value, as_object: wrapperObject()});
          }
        }
      });
    });

    Interceptor.attach(at.Fut_FailLoginRecovery, {
      onEnter: function () { send({kind: 'as-branch', which: 'FUTFailLoginRecovery (FAILURE branch)'}); }
    });

    ['ArchiveExists', 'ArchiveMount'].forEach(function (which) {
      Interceptor.attach(at[which], {
        onEnter: function (args) {
          this.name = null;
          try {
            const name = args[0].readCString();
            if (name && /cards|fut/i.test(name)) this.name = name;
          } catch (error) {}
        },
        onLeave: function (retval) {
          if (this.name === null) return;
          send({kind: 'archive', call: which, name: this.name, result: retval.toUInt32()});
        }
      });
    });

    // A Career Mode entry proved this hook sees screens loaded by exactly the
    // helperFunctions createEmptyMovieClip + loadMovie pattern (careermodemain
    // parsed). Capturing the call chain for the first few parses gives the real
    // resource-resolution path, which static analysis kept losing in hardcoded
    // special cases (_level24, Apt-Flash-Native-Filters).
    let aptTraces = 0;
    Interceptor.attach(at.AptParse, {
      onEnter: function (args) {
        try {
          if (args[0].readCString(8) !== 'Apt Data') return;
          const bytes = new Uint8Array(args[0].add(0x10).readByteArray(16));
          let hex = '';
          for (let i = 0; i < bytes.length; i++) hex += ('0' + bytes[i].toString(16)).slice(-2);
          let chain = null;
          if (aptTraces < 3) {
            aptTraces += 1;
            chain = Thread.backtrace(this.context, Backtracer.ACCURATE)
              .slice(0, 12)
              .map(function (address) {
                const offset = address.sub(fifa.base);
                return offset.compare(0) > 0 ? '0x' + offset.add(0x400000).toString(16) : address.toString();
              });
          }
          send({kind: 'apt-parse', fingerprint: hex, chain: chain});
        } catch (error) {}
      }
    });

    configHook(at.ConfigGetInt, 'config-int', function (r) { return r.toInt32(); });
    configHook(at.ConfigGetString, 'config-string', function (r) {
      try { return r.readCString(); } catch (error) { return '<unreadable>'; }
    });

    Interceptor.attach(at.CardsLoadGate, {
      onEnter: function () {
        try {
          const self = this.context.ecx;
          this.busy = self.add(0x114).readU32();
        } catch (error) { this.busy = null; }
      },
      onLeave: function (retval) {
        const code = retval.toInt32();
        const why = code >= 0 ? 'OK -> CardsDLL'
                  : (code === -2 ? '[obj+0x114] != 0 (busy/already loaded)'
                                 : 'no fut_dll DLC, or FAKE_CARDS0_FAIL, or a cards archive with a null handle');
        send({kind: 'cards-load-gate', ret: code, busy_field_0x114: this.busy, meaning: why});
      }
    });

    let rejected = 0;
    Interceptor.attach(at.RoutingParse, {
      onEnter: function (args) {
        rejected = 0;
        // The buffer turned out to hold the game's OWN cfgrouting.xml
        // (fileVersion="1", encoding="UTF-8"), not the file dropped into the
        // game folder — so the real routing table ships inside the archives.
        // Dump it whole: it is the authoritative schema and service list.
        // Called as push length; push buffer; call — so args[0]=buffer,
        // args[1]=length.
        let full = null;
        try {
          const len = args[1].toInt32();
          if (len > 0 && len < 1024 * 1024) full = args[0].readUtf8String(len);
        } catch (error) { full = null; }
        if (full === null) {
          try { full = args[0].readUtf8String(65536); } catch (error) {}
        }
        send({kind: 'routing-parse-begin', buffer: describe(args[0]),
              length: args[1].toInt32(), document: full});
      },
      onLeave: function () {
        send({kind: 'routing-parse-end', entries_rejected: rejected});
      }
    });
    Interceptor.attach(at.RoutingEntryReject, {
      onEnter: function () { rejected += 1; send({kind: 'routing-entry-rejected', n: rejected}); }
    });
    send({kind: 'ready', wire: true, gate: true, targets: resolved});
  }
}

// Capture the access violation itself instead of guessing at its caller.
//
// The crash is a null dereference at fifa13.exe+0x5DF4C9 (`mov ecx,[eax]` with
// eax = 0), identical across two runs and unchanged by populating the squad, so
// the question is no longer "what data is missing" but "who called this".
// The minidump only carries 0x100 bytes around the instruction pointer and its
// stack is mostly UTF-16 noise, so the backtrace has to be taken live.
//
// An exception handler is the safe way to do it: no inline hook, nothing
// relocated, no short mid-function instruction patched -- the mistake that made
// PopupDispatch suppress the very write it was watching. Returning false leaves
// the exception to the game's own handler, so behaviour is unchanged and the
// minidump is still written.
// AGENT is a RAW Python literal, so what is written here is exactly what the
// JavaScript engine sees: \\ is one backslash, \n is a real newline. Escaping it
// as if Python would process it produced a doubled path and a literal "\n".
// The two paths are substituted by build_agent() from the repository location,
// so nothing here is tied to one machine.
const CRASH_LOG = '%CRASH_LOG%';
const DEBUG_LOG = '%DEBUG_LOG%';

// Marker line, written at load. It makes the two failure modes distinguishable:
// a file holding only this line means the handler never fired (the game's own
// handler got there first); no file at all means File writing itself failed.
try {
  const marker = new File(CRASH_LOG, 'a');
  marker.write(JSON.stringify({kind: 'exception-handler-installed'}) + '\n');
  marker.flush();
  marker.close();
} catch (error) {
  send({kind: 'exception-marker-failed', error: String(error)});
}

// The game's own debug output -- and with it every ActionScript trace().
//
// The first run of the exception handler captured 13 exceptions and not one was
// the crash: all carried code 0x40010006 (DBG_PRINTEXCEPTION_C), which is how
// OutputDebugString signals. That noise would bury the real access violation,
// but the stream itself is exactly what we have been reading statically in the
// APT listings ("fcc_login::ContinueToCreateClub()" and friends).
//
// Written to disk as it arrives, not only when a fault is caught.
//
// The first run proved the handler fires (13 debug-print exceptions) yet never
// saw the access violation -- the game's own handler almost certainly gets it
// first. So the debug stream cannot depend on our handler running at crash
// time: it has to be on disk already. The handle stays open and every line is
// flushed, which costs an I/O per line but guarantees the last line before the
// crash survives. A ring buffer is kept as well, purely to enrich the fault
// record on the runs where we do catch it.
const DEBUG_RING = [];
const DEBUG_RING_MAX = 300;
let debugLog = null;
try {
  debugLog = new File(DEBUG_LOG, 'w');
} catch (error) {
  send({kind: 'debuglog-open-failed', error: String(error)});
}

['OutputDebugStringA', 'OutputDebugStringW'].forEach(function (name) {
  const wide = name.endsWith('W');
  // Frida 17 removed Module.findExportByName; use the compatibility resolver
  // already used by the rest of this agent.
  const address = exportByName('KERNELBASE.dll', name) ||
                  exportByName('kernel32.dll', name);
  if (address === null) return;
  try {
    Interceptor.attach(address, {
      onEnter: function (args) {
        try {
          const text = wide ? args[0].readUtf16String() : args[0].readCString();
          if (text === null) return;
          const line = text.replace(/[\r\n]+$/, '');
          DEBUG_RING.push(line);
          if (DEBUG_RING.length > DEBUG_RING_MAX) DEBUG_RING.shift();
          if (debugLog !== null) { debugLog.write(line + '\n'); debugLog.flush(); }
        } catch (error) { /* unreadable pointer: not worth failing the call */ }
      }
    });
  } catch (error) {
    send({kind: 'debugstring-hook-failed', fn: name, error: String(error)});
  }
});

// Squad-screen containment for the exact CL1217703 fault measured twice at
// fifa13.exe+0x5e4449. The code performs a two-level lookup without checking
// whether the first returned object is null:
//   mov eax,[eax] ; mov ecx,[eax] ; push ecx
// Hook the first instruction and, only when its source cell contains null,
// substitute a private two-cell chain whose final value is zero. This preserves
// the following call and cleanup path instead of jumping over arbitrary code.
// It is deliberately signature-gated and logs every activation: once the
// missing model field is identified this diagnostic guard can be removed.
if (false && fifa !== undefined) {
  // v0.13.11 donor parity: disabled. The current squad path loads cleanly and
  // this executable-context rewrite is no longer justified.
  const squadNullLoad = fifa.base.add(0x5e4447);
  const expected = '8b 00 8b 08 51 8d 4d e8';
  if (matches(squadNullLoad, expected)) {
    const zeroLeaf = Memory.alloc(Process.pointerSize);
    const zeroCell = Memory.alloc(Process.pointerSize);
    zeroLeaf.writePointer(ptr(0));
    zeroCell.writePointer(zeroLeaf);
    Interceptor.attach(squadNullLoad, {
      onEnter: function () {
        try {
          const source = this.context.eax;
          if (!source.isNull() && source.readPointer().isNull()) {
            this.context.eax = zeroCell;
            const line = '[FUT13] contained squad null lookup at fifa13+0x5e4447';
            if (debugLog !== null) { debugLog.write(line + '\n'); debugLog.flush(); }
            send({kind: 'squad-null-contained', address: squadNullLoad.toString(),
                  thread_id: Process.getCurrentThreadId()});
          }
        } catch (error) {
          send({kind: 'squad-null-guard-error', error: String(error)});
        }
      }
    });
    send({kind: 'squad-null-guard-ready', address: squadNullLoad.toString()});
  } else {
    send({kind: 'squad-null-guard-disabled', reason: 'signature mismatch',
          address: squadNullLoad.toString()});
  }
}

Process.setExceptionHandler(function (details) {
  // OutputDebugString raises DBG_PRINTEXCEPTION_C (0x40010006), which Frida
  // reports as a plain 'system' exception -- 13 of them in the first run, and
  // not one was the crash. They are told apart by the memory descriptor: a real
  // access violation carries one, a debug print does not.
  if (!details.memory) return false;
  try {
    const ctx = details.context;
    const frames = Thread.backtrace(ctx, Backtracer.ACCURATE)
      .concat(Thread.backtrace(ctx, Backtracer.FUZZY).slice(0, 12))
      .map(function (a) {
        const m = Process.findModuleByAddress(a);
        return m ? m.name + '+0x' + a.sub(m.base).toString(16) : a.toString();
      });
    const payload = {
      kind: 'exception',
      type: details.type,
      address: details.address.toString(),
      memory: details.memory ? {operation: details.memory.operation,
                                address: details.memory.address.toString()} : null,
      registers: {eax: ctx.eax.toString(), ecx: ctx.ecx.toString(),
                  edx: ctx.edx.toString(), esi: ctx.esi.toString(),
                  edi: ctx.edi.toString(), ebp: ctx.ebp.toString(),
                  esp: ctx.esp.toString()},
      cards_store: (function () {
        try {
          const currentCards = Process.enumerateModules().find(function (m) {
            return m.name.toLowerCase().indexOf('cardsdll') !== -1;
          });
          const cm = currentCards === undefined ? cardsModule : currentCards;
          if (cm === null || cm === undefined) return null;
          // v0.13.20 deliberately does NOT interpret the old CL1217703
          // +0x3CC4A/+0x1A97F8 addresses. Those were from the mismatched 7D8
          // DLL and are meaningless on stock CL1298564. Preserve only module
          // identity and fault RVA so a real stock-build failure can be
          // analysed without contaminating it with old-layout assumptions.
          let faultRva = null;
          try {
            if (details.address.compare(cm.base) >= 0 &&
                details.address.compare(cm.base.add(cm.size)) < 0) {
              faultRva = '0x' + details.address.sub(cm.base).toString(16);
            }
          } catch (e) {}
          return {build: CARDS_PROFILE.name,
                  module_base: cm.base.toString(),
                  module_size: cm.size,
                  fault_rva: faultRva,
                  esi: ctx.esi.toString()};
        } catch (e) { return {error: String(e)}; }
      })(),
      backtrace: frames,
      // The last lines the game printed before faulting -- ActionScript traces
      // included. This is what names the function that ran, which neither the
      // minidump nor the backtrace can give.
      debug_tail: DEBUG_RING.slice(-120)
    };

    // Write to disk FIRST, synchronously. send() is asynchronous, and the first
    // attempt at this lost the whole backtrace: the handler ran, queued the
    // message, returned, and the process died before the message ever left.
    // A flushed file survives the crash; the send() below is only a convenience
    // for the case where the process happens to live long enough.
    try {
      const file = new File(CRASH_LOG, 'a');
      file.write(JSON.stringify(payload) + '\n');
      file.flush();
      file.close();
    } catch (writeError) {
      send({kind: 'exception-write-failed', error: String(writeError)});
    }
    send(payload);
  } catch (error) {
    send({kind: 'exception-handler-failed', error: String(error)});
  }
  return false;
});
"""


def utc_now() -> str:
    """Local time, with the UTC offset kept so the stamp stays unambiguous.

    This used to be plain UTC while the DIME server logged local time, a two
    hour gap that made the two journals annoying to line up by eye. Local time
    with an explicit offset is just as machine-readable and compares directly.
    """
    return datetime.now(timezone.utc).astimezone().isoformat()


def artifacts_dir() -> Path:
    """Where run output goes: <repo>/artifacts, created on demand."""
    path = Path(__file__).resolve().parents[1] / "artifacts"
    path.mkdir(parents=True, exist_ok=True)
    return path


def build_agent(cards_build: str) -> str:
    payload = json.dumps([{"name": n, "rva": r, "signature": s} for n, r, s in TARGETS])
    out = artifacts_dir()
    # The agent is JavaScript source, so a Windows path has to arrive with its
    # backslashes escaped or the string literal breaks.
    def js(path: Path) -> str:
        return str(path).replace("\\", "\\\\")
    return (AGENT
            .replace("%TARGETS%", payload)
            .replace("%CARDS_BUILD%", json.dumps(cards_build))
            .replace("%CRASH_LOG%", js(out / "crash-backtrace.jsonl"))
            .replace("%DEBUG_LOG%", js(out / "game-debug.log")))


def main() -> int:
    parser = argparse.ArgumentParser(description="Trace the FIFA 13 FUT bootstrap.")
    parser.add_argument("--seconds", type=int, default=420,
                        help="how long to keep the trace running (default 420)")
    parser.add_argument("--log", type=Path,
                        help="JSONL output path (default artifacts/fifa13-futgate-<timestamp>.jsonl)")
    parser.add_argument("--cards-build", choices=("1298564", "1217703"),
                        help="runtime FIFA build used to select CardsDLL hook RVAs")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    log_path = args.log or root / "artifacts" / f"fifa13-futgate-{datetime.now():%Y%m%d-%H%M%S}.jsonl"
    log_path.parent.mkdir(parents=True, exist_ok=True)

    device = frida.get_local_device()
    pid = None
    for process in device.enumerate_processes():
        if process.name.lower() == "fifa13.exe":
            pid = process.pid
            break
    if pid is None:
        raise SystemExit(
            "fifa13.exe not found. Start the game through EA Desktop and bring it to the "
            "MAIN MENU with the bridge stopped, then run this trace again."
        )

    print(f"Attached to PID {pid} (game at the menu, self-decryption finished).", flush=True)
    cards_build = args.cards_build
    if not cards_build:
        settings_path = root / 'local.settings.json'
        if settings_path.is_file():
            try:
                settings = json.loads(settings_path.read_text(encoding='utf-8-sig'))
                cards_build = str(settings.get('gameRuntimeVersion') or '').strip()
            except Exception:
                cards_build = ''
    if cards_build not in {'1298564', '1217703'}:
        raise SystemExit('CardsDLL runtime build is unknown. Launch through RUN_LOCAL_FUT13.cmd so Blaze runtime pairing completes first.')

    session = device.attach(pid)
    script = session.create_script(build_agent(cards_build))

    with log_path.open("w", encoding="utf-8") as stream:
        fingerprints = apt_fingerprints()

        def on_message(message, _data) -> None:
            payload = message.get("payload") if message["type"] == "send" else {
                "kind": "frida-message", "message": message}
            if payload.get("kind") == "apt-parse":
                payload["screen"] = fingerprints.get(payload.get("fingerprint"), "unknown")
            stream.write(json.dumps({"time": utc_now(), **payload}, ensure_ascii=False) + "\n")
            stream.flush()
            print(json.dumps(payload, ensure_ascii=True), flush=True)

        script.on("message", on_message)
        script.load()
        print(f"Trace active. Log: {log_path}", flush=True)
        print("START THE BRIDGE NOW, then enter Ultimate Team.", flush=True)

        try:
            time.sleep(args.seconds)
        except KeyboardInterrupt:
            pass
        finally:
            try:
                script.unload()
                session.detach()
            except frida.InvalidOperationError:
                pass

    print(f"Trace finished. Log: {log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
