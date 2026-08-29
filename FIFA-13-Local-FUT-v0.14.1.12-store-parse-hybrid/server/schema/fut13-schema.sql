-- Schema for the FIFA 13 FUT local backend.
--
-- Modelled on the FIFA 14 revival project's SQLite store (server/local_identity.py),
-- which is the reference this project follows: its response builders read exactly
-- these entities, so keeping the shapes aligned means squad_list(), user_info()
-- and the item routes port over with no reinterpretation.
--
-- Deliberately NOT normalised to death. The client reads whole documents, so the
-- item payload is kept as jsonb: FUT item records carry dozens of fields whose
-- meaning is still being recovered, and a rigid column set would have to change
-- every time one more is identified.

CREATE TABLE IF NOT EXISTS persona (
    persona_id      bigint PRIMARY KEY,
    persona_name    text        NOT NULL,
    user_id         bigint      NOT NULL,
    credits         bigint      NOT NULL DEFAULT 0,
    returning_user  boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS club (
    persona_id  bigint PRIMARY KEY REFERENCES persona(persona_id) ON DELETE CASCADE,
    club_name   text NOT NULL DEFAULT '',
    club_abbr   text NOT NULL DEFAULT '',
    platform    text NOT NULL DEFAULT 'pc',
    asset_id    bigint NOT NULL DEFAULT 0
);

-- Pile numbers are the client's own: 7 = squad slot, per the FIFA 14 project's
-- _canonical_player_payload.
CREATE TABLE IF NOT EXISTS item (
    persona_id  bigint NOT NULL REFERENCES persona(persona_id) ON DELETE CASCADE,
    item_id     bigint NOT NULL,
    asset_id    bigint NOT NULL DEFAULT 0,
    pile        integer NOT NULL DEFAULT 0,
    payload     jsonb  NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (persona_id, item_id)
);

CREATE TABLE IF NOT EXISTS squad (
    squad_id    bigint NOT NULL,
    persona_id  bigint NOT NULL REFERENCES persona(persona_id) ON DELETE CASCADE,
    squad_name  text    NOT NULL DEFAULT '',
    formation   text    NOT NULL DEFAULT 'f442',
    active      boolean NOT NULL DEFAULT false,
    PRIMARY KEY (persona_id, squad_id)
);

-- MEASURED 7 August 23:27: fcc_login2::DownloadActiveSquadDeck() calls OnError()
-- outright when the squad list is empty (m_Squads.length < 1). A persona must
-- therefore always own at least one squad, even with every slot empty --
-- item_id 0 stands for an empty slot, exactly as the FIFA 14 project encodes it.
CREATE TABLE IF NOT EXISTS squad_player (
    persona_id  bigint  NOT NULL,
    squad_id    bigint  NOT NULL,
    slot_index  integer NOT NULL,
    item_id     bigint  NOT NULL DEFAULT 0,
    PRIMARY KEY (persona_id, squad_id, slot_index),
    FOREIGN KEY (persona_id, squad_id) REFERENCES squad(persona_id, squad_id) ON DELETE CASCADE
);

-- Opaque client blobs (tutorial popups, pile sizes...). The client round-trips
-- these without the server needing to understand them.
CREATE TABLE IF NOT EXISTS client_data (
    persona_id  bigint NOT NULL REFERENCES persona(persona_id) ON DELETE CASCADE,
    key         text   NOT NULL,
    payload     jsonb  NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (persona_id, key)
);

CREATE INDEX IF NOT EXISTS item_by_pile ON item (persona_id, pile);

-- Seed: the single local persona this stack serves, matching the constants in
-- bridge/Fut13BridgeSettings.cs (UserId 1000001 / PersonaId 2000001).
-- returning_user stays false and the club name stays empty on purpose: the FIFA
-- 14 project found that seeding a fake established club skips the retail
-- first-use path and breaks later.
INSERT INTO persona (persona_id, persona_name, user_id)
VALUES (2000001, 'FUT13 Local', 1000001)
ON CONFLICT (persona_id) DO NOTHING;

INSERT INTO club (persona_id) VALUES (2000001)
ON CONFLICT (persona_id) DO NOTHING;

INSERT INTO squad (squad_id, persona_id, squad_name, formation, active)
VALUES (1, 2000001, 'FUT13 Local', 'f442', true)
ON CONFLICT (persona_id, squad_id) DO NOTHING;

-- 23 slots: eleven starters, seven substitutes, five reserves. The earlier 18
-- was a guess; 23 comes from the FIFA 14 project's _slot_position table and is
-- confirmed by its Icebreaker fixture, whose squad array is exactly 23 long.
INSERT INTO squad_player (persona_id, squad_id, slot_index)
SELECT 2000001, 1, generate_series(0, 22)
ON CONFLICT (persona_id, squad_id, slot_index) DO NOTHING;

-- Seed: the 23 squad items.
--
-- WHY THIS SEED EXISTS. fut13-rs4-server.ps1 builds the squad document by two
-- routes: Get-SquadList when PostgreSQL answers, and the static
-- Build-SquadDocument when it does not. Both must emit the SAME document.
-- Before this seed they did not. squad_player was seeded with item_id 0 and no
-- item rows existed at all, so the SQL route returned 23 empty {"id":0} slots
-- while the static route returned 23 fully populated players: enabling the
-- database SILENTLY DOWNGRADED the response, with nothing failing loudly to say
-- so. The downgrade is not cosmetic -- 23 empty slots is the exact shape that
-- faulted the squads screen on a null dereference (fifa13.exe+0x5DF4C9,
-- 7 August 23:51).
--
-- The values are the ones the static route already uses: $script:SquadPlayers
-- (assetId / teamId / rating, from the FIFA 14 project's validated Icebreaker
-- squad) paired with $script:SlotPositions, and item_id = 1000 + slot_index
-- exactly as New-PlayerItem numbers them. The two lists are one contract:
-- change a player on one side and it must change on the other.
--
-- The payload mirrors New-PlayerItem's complete 38-field player document, not a
-- subset. A partial item makes the client treat the entry as an anonymous
-- object and write it back as id zero, which is the failure this seed exists to
-- prevent in the first place.
--
-- Two knowing differences from the static route, neither of them semantic:
--   * timestamp is frozen at seed time, where the static route stamps each
--     response with the current time. No client read of this field is known.
--   * payload is jsonb, which normalises key ORDER. The set of keys is
--     identical; only their order in the serialised document differs. jsonb
--     compares keys case-sensitively, so the deliberate teamid/teamId and
--     rareflag/rareFlag pairs both survive -- that was the property worth
--     confirming before keeping jsonb here.
--
-- DO UPDATE rather than DO NOTHING: if the roster or the document shape is
-- revised, re-running this schema must converge on the new payload instead of
-- leaving a stale one behind. Re-running with no change is harmless.
WITH roster(slot_index, asset_id, team_id, rating, slot_position) AS (
    VALUES
      ( 0, 167397,  69, 90, 'ST'),  ( 1, 158023, 241, 94, 'ST'),
      ( 2, 190871, 241, 84, 'LM'),  ( 3,  10535, 241, 89, 'CM'),
      ( 4,     41, 241, 89, 'CM'),  ( 5, 183898, 243, 86, 'RM'),
      ( 6, 197445,  21, 81, 'LB'),  ( 7, 139720,  10, 86, 'CB'),
      ( 8, 152729, 241, 86, 'CB'),  ( 9, 121939,  21, 87, 'RB'),
      (10, 167495,  21, 86, 'GK'),
      (11, 190813,  47, 81, 'SUB'), (12,  20801, 243, 92, 'SUB'),
      (13, 156616,  21, 90, 'SUB'), (14,   9014,  21, 88, 'SUB'),
      (15, 155862, 243, 86, 'SUB'), (16,  41236,  73, 89, 'SUB'),
      (17,  54050,  11, 87, 'SUB'),
      (18,   7826,  11, 89, 'RES'), (19, 146530, 241, 84, 'RES'),
      (20, 142784,  10, 82, 'RES'), (21, 189505, 241, 84, 'RES'),
      (22, 150724, 241, 83, 'RES')
)
INSERT INTO item (persona_id, item_id, asset_id, pile, payload)
SELECT 2000001,
       1000 + r.slot_index,
       r.asset_id,
       7,                       -- pile 7 = squad slot, as above
       jsonb_build_object(
         'id',                 1000 + r.slot_index,
         'itemId',             1000 + r.slot_index,
         'timestamp',          extract(epoch from now())::bigint,
         'itemType',           'player',
         'rating',             r.rating,
         'formation',          'f442',
         'lastSalePrice',      0,
         'owners',             1,
         'morale',             99,
         -- Both casings on purpose: the client reads both, so New-PlayerItem
         -- emits both and this document must too.
         'teamid',             r.team_id,
         'teamId',             r.team_id,
         'preferredPosition',  CASE WHEN r.slot_position IN ('SUB', 'RES') THEN 'CM'
                                    ELSE r.slot_position END,
         'untradeable',        true,
         'resourceId',         r.asset_id,
         'assetId',            r.asset_id,
         'itemState',          'free',
         'injuryType',         'none',
         'injuryGames',        0,
         'suspension',         0,
         'fitness',            99,
         'assists',            0,
         'training',           0,
         -- 0 for the goalkeeper (slot 10), 1 for outfield players.
         'cardsubtypeid',      CASE WHEN r.slot_position = 'GK' THEN 0 ELSE 1 END,
         'discardValue',       0,
         -- Five zeroed stats and six attributes mirroring the rating: the same
         -- fallback New-PlayerItem uses, there being no per-attribute data.
         'statsList',          '[{"index": 0, "value": 0}, {"index": 1, "value": 0},
                                 {"index": 2, "value": 0}, {"index": 3, "value": 0},
                                 {"index": 4, "value": 0}]'::jsonb,
         'attributeList',      (SELECT jsonb_agg(jsonb_build_object('index', g, 'value', r.rating)
                                                 ORDER BY g)
                                FROM generate_series(0, 5) AS g),
         'lifetimeStats',      '[{"index": 0, "value": 0}, {"index": 1, "value": 0},
                                 {"index": 2, "value": 0}, {"index": 3, "value": 0},
                                 {"index": 4, "value": 0}]'::jsonb,
         'contract',           99,
         'rareflag',           CASE WHEN r.rating >= 75 THEN 1 ELSE 0 END,
         'rareFlag',           CASE WHEN r.rating >= 75 THEN 1 ELSE 0 END,
         'playStyle',          0,
         'lifetimeAssists',    0,
         'loyaltyBonus',       1,
         'pile',               7,
         -- FIFA 13, not 2014 -- the one field that must not be copied verbatim
         -- from the FIFA 14 project.
         'resourceGameYear',   2013,
         'attributeArray',     to_jsonb(array_fill(r.rating, ARRAY[6])),
         'statsArray',         '[0, 0, 0, 0, 0]'::jsonb,
         'lifetimeStatsArray', '[0, 0, 0, 0, 0]'::jsonb)
FROM roster r
ON CONFLICT (persona_id, item_id) DO UPDATE
    SET asset_id = EXCLUDED.asset_id,
        pile     = EXCLUDED.pile,
        payload  = EXCLUDED.payload;

-- Point every slot at the item seeded for it. Kept as a separate statement
-- rather than folded into the squad_player INSERT above, because that INSERT is
-- ON CONFLICT DO NOTHING and so would never correct an already-seeded row.
-- The last predicate makes a repeat run a no-op instead of a rewrite.
UPDATE squad_player
   SET item_id = 1000 + slot_index
 WHERE persona_id = 2000001
   AND squad_id   = 1
   AND slot_index BETWEEN 0 AND 22
   AND item_id <> (1000 + slot_index);
