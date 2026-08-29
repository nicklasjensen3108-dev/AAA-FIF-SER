# FUT (RS4) HTTP endpoint for FIFA 13 — the service CardsDLLzf.dll talks to.
#
# The DLL's built-in base is http://easw.easports.com:8099/ and its route table
# (recovered from the DLL's own strings) is keyed by symbolic name:
#
#   AUTH          ut/auth                 CLIENTDATA   ut/%s/clientdata
#   DELETE_AUTH   ut/delete/auth          USER         ut/%s/user
#   PHISHING      ut/%s/phishing          CLUB         ut/%s/club
#   SQUAD         ut/%s/squad             ITEMS        ut/%s/item
#   STORE         ut/%s/store             TRADEPILE    ut/%s/tradePile
#   WATCHLIST     ut/%s/watchList         AUCTIONHOUSE ut/%s/auctionhouse
#   MATCH         ut/%s/match             SEASON       ut/%s/season
#   TOURNAMENT    ut/%s/tournament        LBDEFAULT    ut/%s/leaderboards
#
# with %s = "game/fifa13" (also a DLL string). Trusted device is
# "/trusteddevice?deviceId=%s" appended to the phishing route.
#
# Everything is logged, and anything unrecognised returns 404 with its path
# recorded — discovering the real routes matters more than guessing them.

param(
    [string] $BindAddress = '127.0.0.1',
    [int]    $Port = 8099,
    # PostgreSQL is optional. When it is unreachable the server falls back to the
    # static responses below, so a database outage degrades to the behaviour that
    # was already measured rather than taking FUT down entirely.
    [string] $DbConn = $(if ($env:FUT13_PG_CONN) { $env:FUT13_PG_CONN } else { 'postgresql://postgres@127.0.0.1:5432/fut13' }),
    # Absolute catalogue path supplied by restart_bridge.ps1. Keeping this
    # explicit prevents the launcher and the hidden RS4 process from silently
    # resolving two different package roots.
    [string] $FullClubCatalogPath,
    [string] $ItemCatalogPath,
    [string] $PythonPath,
    [string] $SavePath
)

$ErrorActionPreference = 'Stop'
$traceSession = $env:FUT13_TRACE_SESSION
$logName = if ($traceSession) { "fut13-rs4-$Port-$traceSession.log" } else { "fut13-rs4-$Port.log" }
$logPath = Join-Path $PSScriptRoot $logName

# The single local persona, matching bridge/Fut13BridgeSettings.cs.
$script:PersonaId = 2000001
$script:DbReady = $false
$script:BaseCardsByName = @{}
$script:NativePlayersByAsset = @{}
$script:FullClubCatalog = @()
$script:FullClubByItemId = @{}
$script:FullClubStats = @{ players=0; playersBronze=0; playersSilver=0; playersGold=0; rarePlayers=0 }

# v0.10: canonical club / league / nation / base rating comes from FIFA 13's
# own fifa_ng_db, not from the FIFA 14 Icebreaker fixture.
$nativeMapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\fifa13-native-player-map.json'
if (Test-Path -LiteralPath $nativeMapPath) {
    try {
        $nativeDoc = Get-Content -LiteralPath $nativeMapPath -Raw | ConvertFrom-Json
        foreach ($property in $nativeDoc.players.PSObject.Properties) {
            $script:NativePlayersByAsset[[string]$property.Name] = $property.Value
        }
    } catch {
        $script:NativePlayersByAsset = @{}
    }
}
$script:Coins = 100000000
$script:PurchasedItems = @()
$script:PurchasedDuplicatePairs = @()
$script:NextPackItemId = 20000
$script:Rng = [System.Random]::new()
$script:RatingDecay = @{ bronze=0.98; silver=0.94; gold=0.78 }
$script:TierFloor = @{ bronze=40; silver=65; gold=75 }
$script:SpecialChance = 0.07
# Relative rarity PER special card, ported from the working donor's FIFA 13
# pack model. The 7% special roll happens first; these weights then decide which
# treatment wins. Rating decay still applies inside the treatment.
$script:SpecialCardRarity = @{
    goldif=1.0; silverif=1.0; bronzeif=1.0
    motm=0.45
    goldblue=0.22; silverblue=0.22; bronzeblue=0.22
    toty=0.05
    special=0.05
}
$script:FullClubByResourceId = @{}
$script:PackPools = @{}
$script:FifaPoints = 0
$script:ClubExtraItems = @()
$script:TradePileItems = @()
$script:ClientDataBuckets = @{}

# Donor-port pack catalogue. These are the FIFA 13 base prices and the four
# familiar promo/player packs used by the working donor backend. Store wire
# fields are emitted by Get-StoreDocument below; do not add modern FUT fields.
$script:PackCatalog = @(
    # Exact storefront rows from the working donor backend. The previous local
    # build removed promo group 4 without evidence; donor renders/buys all ten.
    [ordered]@{ id=1;  name='Bronze Pack';               level='bronze'; coins=400; points=$null; rares=1;  premium=$false; size=12; group='bronze'; assetId=1 },
    [ordered]@{ id=2;  name='Premium Bronze Pack';       level='bronze'; coins=750; points=$null; rares=3;  premium=$true;  size=12; group='bronze'; assetId=1 },
    [ordered]@{ id=3;  name='Silver Pack';               level='silver'; coins=2500; points=50;    rares=1;  premium=$false; size=12; group='silver'; assetId=2 },
    [ordered]@{ id=4;  name='Premium Silver Pack';       level='silver'; coins=3750; points=75;    rares=3;  premium=$true;  size=12; group='silver'; assetId=2 },
    [ordered]@{ id=5;  name='Gold Pack';                 level='gold';   coins=5000; points=100;   rares=1;  premium=$false; size=12; group='gold';   assetId=3 },
    [ordered]@{ id=6;  name='Premium Gold Pack';         level='gold';   coins=7500; points=150;   rares=3;  premium=$true;  size=12; group='gold';   assetId=3 },
    [ordered]@{ id=7;  name='Premium Gold Players Pack'; level='gold';   coins=25000; points=300;   rares=3;  premium=$true;  size=12; group='promo';  assetId=4 },
    [ordered]@{ id=8;  name='Prime Gold Players Pack';   level='gold';   coins=45000; points=600;   rares=6;  premium=$true;  size=12; group='promo';  assetId=4 },
    [ordered]@{ id=9;  name='Rare Players Pack';         level='gold';   coins=50000; points=1000;  rares=12; premium=$true;  size=12; group='promo';  assetId=4 },
    [ordered]@{ id=10; name='Jumbo Rare Players Pack';   level='gold';   coins=100000; points=2000;  rares=24; premium=$true;  size=24; group='promo';  assetId=4 }
)

# Session-local mutable squad state. The trace on 14 August proved the FIFA 13
# client already computes chemistry before sending PUT /squad/<id>; the old
# server discarded that document and always returned the original hard-coded
# 100-chem squad, which made chemistry and player moves appear broken.
# v0.13.4: chemistry/rating/starRating are calculated by FIFA itself.
# Match the donor: omit them until the first authoritative client PUT.
$script:SquadChemistry = $null
$script:SquadRating = $null
$script:SquadStarRating = $null
$script:SquadFormation = 'f442'
$script:SquadName = 'FUT13 Local'
$script:SquadOrder = @(0..22 | ForEach-Object { 1000 + $_ })

function ConvertTo-CardNameKey([string] $Value) {
    if ($null -eq $Value) { return '' }
    $decomposed = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString().ToLowerInvariant()
}

# The bundled WeFUT scrape is normalized by tools/build_fifa13_base_catalog.py.
# Its page ids are intentionally never used here: they are not EA asset ids.
$baseCatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'data\wefut-fifa13-base.json'
if (Test-Path -LiteralPath $baseCatalogPath) {
    try {
        $baseCatalog = Get-Content -LiteralPath $baseCatalogPath -Raw | ConvertFrom-Json
        foreach ($card in $baseCatalog.cards) {
            # normalizedName is deliberately ASCII; Windows PowerShell 5.1 can
            # otherwise decode an un-BOMmed UTF-8 accented display name using
            # the active ANSI codepage and produce a different lookup key.
            $script:BaseCardsByName[[string]$card.normalizedName] = $card
        }
    } catch {
        # Server availability is more important than optional catalogue fidelity.
        $script:BaseCardsByName = @{}
    }
}

# The Windows installer does not put psql on the PATH of already-running shells,
# so look in the standard install location too rather than declaring PostgreSQL
# absent when it is merely unlisted.
function Resolve-Psql {
    $onPath = Get-Command psql -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending
    foreach ($dir in $candidates) {
        $exe = Join-Path $dir.FullName 'bin\psql.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# Shaping is done by PostgreSQL itself (json_build_object / json_agg) rather than
# assembled in PowerShell: the client is picky about document shape, and one SQL
# statement per route keeps the shape in one readable place.
#
# -w everywhere: without it psql blocks on a password prompt, and this server runs
# with no console attached, so a missing credential would hang the request instead
# of failing it. Credentials come from libpq's own password file
# (%APPDATA%\postgresql\pgpass.conf) -- never from this repository.
function Invoke-Sql([string] $Sql) {
    if (-not $script:DbReady) { return $null }
    try {
        $out = & $script:Psql -w $DbConn -t -A -v ON_ERROR_STOP=1 -c $Sql 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $text = ($out | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text
    } catch { return $null }
}

function Test-Database {
    $script:Psql = Resolve-Psql
    if (-not $script:Psql) { return $false }
    $env:PGCONNECT_TIMEOUT = '5'
    try {
        & $script:Psql -w $DbConn -t -A -c 'SELECT 1' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Write-Log([string] $Message) {
    $line = '[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}' -f (Get-Date), $Message
    [Console]::WriteLine($line)
    Add-Content -LiteralPath $logPath -Value $line
}

# Responses use only keys the FIFA 13 parsers are known to read. The FIFA 14
# revival project recovered the Authentication parser as accepting exactly
# sid / serverTime / lastOnlineTime, and the trusted-console parser as reading
# trusted / changed / exists / locked.
# One squad, every slot empty.
#
# MEASURED 7 August 23:27: an empty squad list is fatal. fcc_login2's
# DownloadActiveSquadDeck() does
#     m_Squads.length < 1 / not / jumpIfTrue -> LoadActiveSquad
#     (fall through) -> OnError()
# so zero squads calls OnError() outright: popup Unknown_FCC_Error, then
# POST /ut/delete/auth 650 ms later, with no 404 anywhere. Returning
# {"squadList":[],"squad":[]} was the abort.
#
# Shape follows the FIFA 14 revival project's squad_list(), which never returns
# an empty list either: id/squadId/squadName/formation/active plus players[] of
# {index, itemData}, with {"id":0} standing for an empty slot.
function Get-SquadList {
    # The item payloads this reads are seeded by schema/fut13-schema.sql, which
    # carries the same 23 players as Build-SquadDocument below. That is not a
    # convenience: the two routes must emit the same document, and an unseeded
    # database made this one return 23 empty slots while the fallback returned a
    # full squad -- a downgrade with nothing failing loudly to announce it.
    $sql = @"
SELECT json_build_object('squad', json_agg(s))::text
FROM (
  SELECT sq.squad_id AS id, sq.squad_name AS "squadName", sq.formation,
         sq.chemistry, sq.rating
  FROM squad sq WHERE sq.persona_id = $($script:PersonaId)
) s
/* Return no row at all when the persona owns no squad, so Invoke-Sql yields null
   and the static builder takes over. The previous COALESCE to an empty array
   turned that case into a squadList of length zero, which is exactly the
   document measured above as calling OnError() outright. */
HAVING count(*) > 0;
"@
    $row = Invoke-Sql $sql
    if ($row) { return $row }
    return (Build-SquadListDocument)
}

# 23 slots: eleven starters, seven substitutes, five reserves. Taken from the
# FIFA 14 project's _slot_position table and confirmed by its Icebreaker fixture,
# whose squad array is exactly 23 long. The earlier 18 was a guess and is retired.
$script:SlotPositions = @(
    'ST','ST','LM','CM','CM','RM','LB','CB','CB','RB','GK',
    'SUB','SUB','SUB','SUB','SUB','SUB','SUB','RES','RES','RES','RES','RES')

# v0.10: the starter/test squad now uses FIFA 13-native identity values.
# asset, team, rating, FUT position, league, nation, name
$script:SquadPlayers = @(
    @(167397,240,88,'ST',53,56,'Radamel Falcao'),
    @(158023,241,94,'CF',53,52,'Lionel Messi'),
    @(190871,1053,85,'LW',7,54,'Neymar'),
    @(10535,241,90,'CM',53,45,'Xavi'),
    @(41,241,90,'CM',53,45,'Andres Iniesta'),
    @(183898,243,86,'RM',53,52,'Angel Di Maria'),
    @(197445,21,77,'LB',19,4,'David Alaba'),
    @(139720,10,85,'CB',13,7,'Vincent Kompany'),
    @(152729,241,86,'CB',53,45,'Gerard Pique'),
    @(121939,21,87,'RB',19,21,'Philipp Lahm'),
    @(167495,21,87,'GK',19,21,'Manuel Neuer'),
    @(190813,47,76,'LW',31,27,'Stephan El Shaarawy'),
    @(20801,243,92,'LW',53,38,'Cristiano Ronaldo'),
    @(156616,21,90,'LM',19,18,'Franck Ribery'),
    @(9014,21,88,'RM',19,34,'Arjen Robben'),
    @(155862,243,87,'CB',53,45,'Sergio Ramos'),
    @(41236,73,88,'ST',16,46,'Zlatan Ibrahimovic'),
    @(54050,11,89,'CF',13,14,'Wayne Rooney'),
    @(7826,11,88,'ST',13,34,'Robin van Persie'),
    @(146530,241,84,'RB',53,54,'Dani Alves'),
    @(142784,10,79,'RB',13,52,'Pablo Zabaleta'),
    @(189505,241,84,'LW',53,45,'Pedro'),
    @(150724,10,84,'GK',13,14,'Joe Hart'))

# v0.14.1 full-club seed. The cache is generated by the launcher from the
# user's own cards0.big -> cards_ng_db -> fcc_playercards, so every resourceId
# is a native FIFA 13 base-card id the installed client can render. Existing
# squad cards keep their historical 1000..1022 item ids; every other base card
# gets a deterministic synthetic *copy id* while retaining its native asset id
# as resourceId.
$fullClubPath = if ($FullClubCatalogPath) {
    [System.IO.Path]::GetFullPath($FullClubCatalogPath)
} elseif ($env:FUT13_FULL_CLUB_CATALOG) {
    [System.IO.Path]::GetFullPath([string]$env:FUT13_FULL_CLUB_CATALOG)
} else {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'data\fifa13-full-player-catalog.json'
}
Write-Log ("FULL CLUB v0.14.1: load path={0} exists={1}" -f $fullClubPath,(Test-Path -LiteralPath $fullClubPath))
if (Test-Path -LiteralPath $fullClubPath) {
    try {
        $fullDoc = Get-Content -LiteralPath $fullClubPath -Raw | ConvertFrom-Json
        $squadItemByAsset = @{}
        for ($i=0; $i -lt $script:SquadPlayers.Count; $i++) {
            $squadItemByAsset[[string][int]$script:SquadPlayers[$i][0]] = 1000 + $i
        }
        $rows = New-Object System.Collections.Generic.List[object]
        $bronze = 0; $silver = 0; $gold = 0; $rare = 0; $baseCards = 0; $specialCards = 0
        foreach ($card in @($fullDoc.players)) {
            $resource = if ($null -ne $card.resourceId) { [long]$card.resourceId } else { [long]$card.assetId }
            $baseAsset = if ($null -ne $card.baseAssetId) { [int]$card.baseAssetId } else { [int]($resource -band 0xFFFFFF) }
            $isSpecial = [bool]$card.isSpecial
            if ($resource -le 0 -or $baseAsset -le 0) { continue }
            $itemId = if ((-not $isSpecial) -and $squadItemByAsset.ContainsKey([string]$baseAsset)) {
                [int]$squadItemByAsset[[string]$baseAsset]
            } elseif ($isSpecial) {
                [int](700000000 + $resource)
            } else {
                [int](500000000 + $resource)
            }
            $rating = [int]$card.rating
            $row = [pscustomobject]@{
                itemId = $itemId
                assetId = [long]$resource
                baseAssetId = $baseAsset
                isSpecial = $isSpecial
                cardType = if ($null -ne $card.cardType) { [string]$card.cardType } else { '' }
                attributes = if ($null -ne $card.attributes) { @($card.attributes | ForEach-Object { [int]$_ }) } else { @() }
                teamId = [int]$card.teamId
                leagueId = [int]$card.leagueId
                nationId = [int]$card.nationId
                rating = $rating
                position = [string]$card.position
                rareFlag = [int]$card.rareFlag
            }
            $rows.Add($row)
            $script:FullClubByItemId[[string]$itemId] = $row
            $script:FullClubByResourceId[[string]$resource] = $row
            if ($isSpecial) { $specialCards++ } else { $baseCards++ }
            if ($rating -le 64) { $bronze++ }
            elseif ($rating -le 74) { $silver++ }
            else { $gold++ }
            if ([int]$card.rareFlag -gt 0) { $rare++ }
        }
        $script:FullClubCatalog = $rows.ToArray()
        $script:FullClubStats = @{
            players=$script:FullClubCatalog.Count
            playersBronze=$bronze
            playersSilver=$silver
            playersGold=$gold
            rarePlayers=$rare
            baseCards=$baseCards
            specialCards=$specialCards
        }
    } catch {
        Write-Log ("FULL CLUB LOAD ERROR v0.14.1: {0}: {1}" -f $_.Exception.GetType().FullName,$_.Exception.Message)
        $script:FullClubCatalog = @()
        $script:FullClubByItemId = @{}
        $script:FullClubByResourceId = @{}
    }
} else {
    Write-Log ("FULL CLUB LOAD ERROR v0.14.1: catalogue file does not exist: {0}" -f $fullClubPath)
}


# v0.14.1 pack pools. Packs now draw from the exact same catalogue that the
# Club screen already proved the matched CL1298564 CardsDLL can render.
if ($script:FullClubCatalog.Count -gt 0) {
    foreach ($level in @('bronze','silver','gold')) {
        $common = New-Object System.Collections.Generic.List[object]
        $rare = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:FullClubCatalog) {
            $rating = [int]$row.rating
            $rowLevel = if ($rating -le 64) { 'bronze' } elseif ($rating -le 74) { 'silver' } else { 'gold' }
            if ($rowLevel -ne $level -or [bool]$row.isSpecial) { continue }
            if ([int]$row.rareFlag -gt 0) { $rare.Add($row) } else { $common.Add($row) }
        }
        $script:PackPools["$level|common"] = $common.ToArray()
        $script:PackPools["$level|rare"] = $rare.ToArray()

        foreach ($kind in @('goldif','silverif','bronzeif','motm','goldblue','silverblue','bronzeblue','toty','special')) {
            $special = New-Object System.Collections.Generic.List[object]
            foreach ($row in $script:FullClubCatalog) {
                if (-not [bool]$row.isSpecial) { continue }
                $rating = [int]$row.rating
                $rowLevel = if ($rating -le 64) { 'bronze' } elseif ($rating -le 74) { 'silver' } else { 'gold' }
                if ($rowLevel -eq $level -and ([string]$row.cardType).ToLowerInvariant() -eq $kind) {
                    $special.Add($row)
                }
            }
            $script:PackPools["$level|special|$kind"] = $special.ToArray()
        }
    }
    Write-Log ("PACK POOL v0.14.1: bronze common={0} rare={1}; silver common={2} rare={3}; gold common={4} rare={5}; specials={6}" -f `
        @($script:PackPools['bronze|common']).Count,@($script:PackPools['bronze|rare']).Count,`
        @($script:PackPools['silver|common']).Count,@($script:PackPools['silver|rare']).Count,`
        @($script:PackPools['gold|common']).Count,@($script:PackPools['gold|rare']).Count,`
        [int]$script:FullClubStats.specialCards)
}

# The complete player discriminator contract, not a partial one.
#
# The FIFA 14 project records why this matters: its V28 emitted enough to draw a
# generic card but omitted itemType and several player-only members, and the
# retail client then treated squad entries as anonymous items and wrote them back
# as id zero. Our {"id":0} slots were the extreme case of that, and the squads
# screen faulted on a null dereference (fifa13.exe+0x5DF4C9, 7 August 23:51).
function New-PlayerItem(
    [int] $ItemId, [long] $AssetId, [int] $TeamId, [int] $Rating,
    [string] $Position, [int] $LeagueId, [int] $Nation, [string] $Name,
    [int] $RareFlag = -1, [switch] $ExactCardFacts,
    [switch] $IsSpecial, [object[]] $Attributes = $null) {

    # Existing 23-player seed keeps the now-proven v0.14.1 identity path.
    # Full-club rows pass -ExactCardFacts because cards_ng_db is CardsDLL's own
    # authoritative card table and must not be overwritten by fifa_ng_db.
    if (-not $ExactCardFacts) {
        $native = $script:NativePlayersByAsset[[string]$AssetId]
        if ($null -ne $native) {
            if ([int]$native.teamId -gt 0) { $TeamId = [int]$native.teamId }
            if ([int]$native.rating -gt 0) { $Rating = [int]$native.rating }
        }
    }

    $rare = if ($RareFlag -ge 0) { [int]$RareFlag } elseif ($Rating -ge 75) { 1 } else { 0 }

    $out = [ordered]@{
        id = [long]$ItemId
        resourceId = [long]$AssetId
        itemType = 'player'
        rareflag = [int]$rare

        # Proven provenance/condition fields from the donor serializer.
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        owners = 1
        lastSalePrice = 0
        discardValue = [Math]::Max(0,[Math]::Min(65535,([int]$Rating * 5)))

        # Donor NEW_ITEM_STATE defaults. Do not send "free" itemState for
        # normal players; that field is reserved for actual equipped states.
        contract = 7
        fitness = 99
        morale = 50
        injuryGames = 0
        injuryType = 0

        # Formation is mandatory for cards shown by the squad UI.
        preferredPosition = [string]$Position
        formation = 'f442'
        teamid = [int]$TeamId
    }

    # FIFA 13's variant nibble bypasses fcc_playercards entirely. A special
    # therefore MUST carry its own rating, team and six attributes; omitting
    # them produces the old bronze/0-stat phantom card. Base cards deliberately
    # continue to let CardsDLL resolve these fields from cards_ng_db.
    if ($IsSpecial) {
        $out['rating'] = [int]$Rating
        $out['teamid'] = [int]$TeamId
        $wireAttributes = @()
        $i = 0
        foreach ($value in @($Attributes)) {
            if ($i -ge 6) { break }
            $wireAttributes += [ordered]@{ index=$i; value=[Math]::Max(0,[Math]::Min(65535,[int]$value)) }
            $i++
        }
        if ($wireAttributes.Count -eq 6) { $out['attributeList'] = $wireAttributes }
    }
    return $out
}

function Get-SquadPlayerByItemId([int] $ItemId) {
    if ($ItemId -lt 1000 -or $ItemId -ge (1000 + $script:SquadPlayers.Count)) { return $null }
    $sourceIndex = $ItemId - 1000
    $p = $script:SquadPlayers[$sourceIndex]
    return (New-PlayerItem -ItemId $ItemId -AssetId $p[0] -TeamId $p[1] `
                           -Rating $p[2] -Position $p[3] -LeagueId $p[4] `
                           -Nation $p[5] -Name $p[6])
}

function Get-FullClubPlayerByItemId([int] $ItemId) {
    $row = $script:FullClubByItemId[[string]$ItemId]
    if ($null -eq $row) { return $null }
    # Squad ids are handled first by Get-OwnedPlayerByItemId so this branch is
    # normally only reached for deterministic 500M+asset copies.
    return (New-PlayerItem -ItemId $ItemId -AssetId ([long]$row.assetId) `
                           -TeamId ([int]$row.teamId) -Rating ([int]$row.rating) `
                           -Position ([string]$row.position) -LeagueId ([int]$row.leagueId) `
                           -Nation ([int]$row.nationId) -Name '' -RareFlag ([int]$row.rareFlag) `
                           -ExactCardFacts -IsSpecial:([bool]$row.isSpecial) -Attributes @($row.attributes))
}

function Test-IsFullClubSeedItem([int] $ItemId) {
    return $script:FullClubByItemId.ContainsKey([string]$ItemId)
}

# v0.13: chemistry and star/rating are client-owned. The client computes them
# over the squad and PUTs them; the server persists only fully-recognised writes.

function Get-OwnedPlayerByItemId([int] $ItemId) {
    $seed = Get-SquadPlayerByItemId $ItemId
    if ($null -ne $seed) { return $seed }
    $fullSeed = Get-FullClubPlayerByItemId $ItemId
    if ($null -ne $fullSeed) { return $fullSeed }
    foreach ($item in @($script:ClubExtraItems) + @($script:TradePileItems) + @($script:PurchasedItems)) {
        if ([int]$item.id -eq $ItemId) { return $item }
    }
    return $null
}

function Build-SquadRecord {
    $players = @()
    for ($i = 0; $i -lt 23; $i++) {
        $itemId = if ($i -lt $script:SquadOrder.Count) { [int]$script:SquadOrder[$i] } else { 0 }
        $item = Get-OwnedPlayerByItemId $itemId
        $players += [ordered]@{
            index = $i
            itemData = if ($null -eq $item) { [ordered]@{ id = 0 } } else { $item }
        }
    }

    # Exact donor rule: do not invent client-calculated arithmetic before FIFA
    # has actually sent it to us.
    $squad = [ordered]@{
        id = 1
        squadName = $script:SquadName
        formation = $script:SquadFormation
        manager = @([ordered]@{ id = 0 })
        players = $players
        personaId = [long]$script:PersonaId
    }

    if ($null -ne $script:SquadChemistry) {
        $squad['chemistry'] = [int]$script:SquadChemistry
    }
    if ($null -ne $script:SquadStarRating) {
        $squad['starRating'] = [int]$script:SquadStarRating
    }

    # rating belongs to squad/list's compact parser, not the active/full parser.
    return $squad
}

function Update-SquadFromRequest([string] $JsonBody) {
    if ([string]::IsNullOrWhiteSpace($JsonBody)) { return '{}' }
    try {
        $doc = $JsonBody | ConvertFrom-Json
        if ($doc.squadName -and -not [string]::IsNullOrWhiteSpace([string]$doc.squadName)) {
            $script:SquadName = [string]$doc.squadName
        }

        $placements = @{}
        $emptySlots = @()
        $named = 0
        $recognised = 0
        foreach ($slot in @($doc.players)) {
            if ($null -eq $slot) { continue }
            $index = [int]$slot.index
            if ($index -lt 0 -or $index -ge 23) { continue }
            $itemId = 0
            if ($slot.itemData -and $null -ne $slot.itemData.id) { $itemId = [int]$slot.itemData.id }
            if ($itemId -eq 0) { $emptySlots += $index; continue }
            $named++
            if ($null -ne (Get-OwnedPlayerByItemId $itemId)) {
                $recognised++
                $placements[$index] = $itemId
            }
        }

        # A client view containing none of our item ids is not authoritative.
        if ($recognised -gt 0) {
            if ($doc.formation -and -not [string]::IsNullOrWhiteSpace([string]$doc.formation)) {
                $script:SquadFormation = [string]$doc.formation
            }

            if ($recognised -eq $named) {
                # Fully recognised: the body is authoritative, including id:0 slots.
                $newOrder = @(0) * 23
                foreach ($index in $placements.Keys) { $newOrder[[int]$index] = [int]$placements[$index] }
                $script:SquadOrder = $newOrder

                # Chemistry/starRating/rating belong to the CLIENT. These are the
                # exact numbers FIFA computed over the cards and PUT back to us.
                if ($null -ne $doc.chemistry) { $script:SquadChemistry = [int]$doc.chemistry }
                if ($null -ne $doc.starRating) { $script:SquadStarRating = [int]$doc.starRating }
                if ($null -ne $doc.rating) { $script:SquadRating = [int]$doc.rating }
            } else {
                # Partially recognised body: place only cards we own and preserve
                # everything else; do not accept arithmetic over foreign cards.
                foreach ($index in $placements.Keys) { $script:SquadOrder[[int]$index] = [int]$placements[$index] }
            }
        }
        Write-Log ("SQUAD DONOR v0.14.1: named={0} recognised={1} clientChem={2} clientStar={3} clientRating={4} formation={5}" -f `
            $named,$recognised,$script:SquadChemistry,$script:SquadStarRating,$script:SquadRating,$script:SquadFormation)
    } catch {
        Write-Log ("SQUAD parse error: {0}" -f $_.Exception.Message)
    }
    # v0.14.1: the client owns the arithmetic; SQLite owns its lifetime.
    Persist-SaveState
    # Working donor returns {} to a save; the client already owns the edit.
    return '{}'
}

function Get-ClubSearchDocument([string] $Path) {
    $type = if ($Path -match '(?:\?|&)type=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { 'player' }
    if ($type -ne 'player') { return '{"itemData":[]}' }

    $position = if ($Path -match '(?:\?|&)position=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]).ToUpperInvariant() } else { '' }
    $level = if ($Path -match '(?:\?|&)level=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]).ToLowerInvariant() } else { 'any' }
    $nation = if ($Path -match '(?:\?|&)nation=(\d+)') { [int]$Matches[1] } else { 0 }
    $league = if ($Path -match '(?:\?|&)league=(\d+)') { [int]$Matches[1] } else { 0 }
    $team = if ($Path -match '(?:\?|&)team=(\d+)') { [int]$Matches[1] } else { 0 }
    $start = if ($Path -match '(?:\?|&)start=(\d+)') { [int]$Matches[1] } else { 0 }
    $count = if ($Path -match '(?:\?|&)(?:count|num)=(\d+)') { [Math]::Max(1,[Math]::Min(100,[int]$Matches[1])) } else { 100 }

    $records = New-Object System.Collections.Generic.List[object]

    if ($script:FullClubCatalog.Count -gt 0) {
        foreach ($row in $script:FullClubCatalog) {
            $pRating = [int]$row.rating
            if ($position -and [string]$row.position -ne $position) { continue }
            if ($team -gt 0 -and [int]$row.teamId -ne $team) { continue }
            if ($league -gt 0 -and [int]$row.leagueId -ne $league) { continue }
            if ($nation -gt 0 -and [int]$row.nationId -ne $nation) { continue }
            if ($level -eq 'bronze' -and $pRating -gt 64) { continue }
            if ($level -eq 'silver' -and ($pRating -lt 65 -or $pRating -gt 74)) { continue }
            if ($level -eq 'gold' -and $pRating -lt 75) { continue }
            $records.Add([pscustomobject]@{ Rating=$pRating; Id=[long]$row.itemId; Seed=$true; Doc=$null })
        }
    } else {
        # Graceful fallback if a user's cards0.big could not be decoded: keep the
        # v0.14.1 23-player club rather than making FUT unavailable.
        for ($i=0; $i -lt $script:SquadPlayers.Count; $i++) {
            $p = $script:SquadPlayers[$i]
            $asset = [int]$p[0]
            $native = $script:NativePlayersByAsset[[string]$asset]
            $pTeam = if ($native -and [int]$native.teamId -gt 0) { [int]$native.teamId } else { [int]$p[1] }
            $pLeague = if ($native -and [int]$native.leagueId -gt 0) { [int]$native.leagueId } else { [int]$p[4] }
            $pNation = if ($native -and [int]$native.nationId -gt 0) { [int]$native.nationId } else { [int]$p[5] }
            $pRating = if ($native -and [int]$native.rating -gt 0) { [int]$native.rating } else { [int]$p[2] }
            if ($position -and [string]$p[3] -ne $position) { continue }
            if ($team -gt 0 -and $pTeam -ne $team) { continue }
            if ($league -gt 0 -and $pLeague -ne $league) { continue }
            if ($nation -gt 0 -and $pNation -ne $nation) { continue }
            if ($level -eq 'bronze' -and $pRating -gt 64) { continue }
            if ($level -eq 'silver' -and ($pRating -lt 65 -or $pRating -gt 74)) { continue }
            if ($level -eq 'gold' -and $pRating -lt 75) { continue }
            $records.Add([pscustomobject]@{ Rating=$pRating; Id=[long](1000+$i); Seed=$true; Doc=$null })
        }
    }

    # Pack/new-item cards moved into the club remain visible alongside the
    # complete base pool. They are few, so sorting the combined metadata is
    # cheap even with ~11k shipped cards.
    foreach ($item in @($script:ClubExtraItems)) {
        $asset = ([long]$item.resourceId -band 0xFFFFFF)
        $native = $script:NativePlayersByAsset[[string]$asset]
        $pTeam = if ($item.teamid) { [int]$item.teamid } elseif ($native) { [int]$native.teamId } else { 0 }
        $pLeague = if ($native) { [int]$native.leagueId } else { 0 }
        $pNation = if ($native) { [int]$native.nationId } else { 0 }
        $pRating = if ($native) { [int]$native.rating } else { 0 }
        if ($position -and [string]$item.preferredPosition -ne $position) { continue }
        if ($team -gt 0 -and $pTeam -ne $team) { continue }
        if ($league -gt 0 -and $pLeague -ne $league) { continue }
        if ($nation -gt 0 -and $pNation -ne $nation) { continue }
        if ($level -eq 'bronze' -and $pRating -gt 64) { continue }
        if ($level -eq 'silver' -and ($pRating -lt 65 -or $pRating -gt 74)) { continue }
        if ($level -eq 'gold' -and $pRating -lt 75) { continue }
        $records.Add([pscustomobject]@{ Rating=$pRating; Id=[long]$item.id; Seed=$false; Doc=$item })
    }

    $sorted = @($records | Sort-Object `
        @{ Expression = { [int]$_.Rating }; Descending = $true }, `
        @{ Expression = { [long]$_.Id }; Ascending = $true })
    $selected = @($sorted | Select-Object -Skip $start -First $count)
    $page = @()
    foreach ($record in $selected) {
        if ($record.Seed) {
            $doc = Get-OwnedPlayerByItemId ([int]$record.Id)
            if ($null -ne $doc) { $page += $doc }
        } else {
            $page += $record.Doc
        }
    }

    Write-Log ("CLUB FULL v0.14.1: source={0} totalBase={1} type={2} pos={3} level={4} nation={5} league={6} team={7} start={8} count={9} matched={10} returned={11}" -f `
        $(if($script:FullClubCatalog.Count -gt 0){'cards_ng_db'}else{'fallback-23'}),$script:FullClubCatalog.Count,$type,$position,$level,$nation,$league,$team,$start,$count,$sorted.Count,$page.Count)

    return ([ordered]@{ itemData=$page } | ConvertTo-Json -Depth 10 -Compress)
}

function Build-SquadListDocument {
    $compact = [ordered]@{
        id = 1
        formation = $script:SquadFormation
        squadName = $script:SquadName
    }

    # Optional until the client has calculated/saved them.
    if ($null -ne $script:SquadChemistry) {
        $compact['chemistry'] = [int]$script:SquadChemistry
    }
    if ($null -ne $script:SquadRating) {
        $compact['rating'] = [int]$script:SquadRating
    }

    return ([ordered]@{ squad = @($compact) } | ConvertTo-Json -Depth 5 -Compress)
}

function Build-SquadDetailDocument {
    $squad=Build-SquadRecord
    # Working donor shape: BOTH wrapped and bare. One FIFA 13 call site consumes
    # the wrapper while another reads the same fields from the root.
    $root=New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::Ordinal)
    $root.Add('squad',$squad)
    foreach ($key in $squad.Keys) { $root.Add([string]$key,$squad[$key]) }
    return ($root | ConvertTo-Json -Depth 10 -Compress)
}

function Get-DetectedRuntimeBuild {
    # autoattach.py records the actual Blaze runtime build before FUT is allowed
    # to load. Read it at request time because RS4 itself starts before FIFA.
    try {
        $root = Split-Path -Parent $PSScriptRoot
        $settingsPath = Join-Path $root 'local.settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $runtime = [string]$settings.gameRuntimeVersion
            if ($runtime) { return $runtime.Trim() }
        }
    } catch {
        Write-Log ("STORE runtime detection warning: {0}" -f $_.Exception.Message)
    }
    return ''
}

function Get-StoreDocument {
    $runtime = Get-DetectedRuntimeBuild
    $isCl1217703 = ($runtime -eq '1217703')

    # CL1217703 is the January retail CardsDLL that the donor RS4 schemas were
    # recovered from. On real 1217703 PCs the 10-pack catalogue completes every
    # HTTP request but the frontend never leaves its spinner after doing a second
    # wallet refresh. Two things in our extended catalogue are not part of the
    # original six-pack flow: the PROMO display group (asset 4), and FIFA-Points
    # prices which involve the first-party commerce singleton we do not run.
    # Keep the newer CL1298564 path unchanged, but give 1217703 the conservative
    # six original packs and coins-only prices. This also means it only asks for
    # backgrounds 1/2/3, all of which are already proven content paths.
    $packs = @($script:PackCatalog)
    # if ($isCl1217703) {
#         $packs = @($script:PackCatalog | Where-Object { [int]$_.id -le 6 })
#     }
# 
    $purchase=@()
    foreach ($pack in $packs) {
        $currencies=@([ordered]@{ name='coins'; funds=[int]$pack.coins; finalFunds=[int]$pack.coins })
        if (-not $isCl1217703 -and $null -ne $pack.points) {
            $currencies += [ordered]@{ name='points'; funds=[int]$pack.points; finalFunds=[int]$pack.points }
        }
        $purchase += [ordered]@{
            id=[int]$pack.id
            packType=([string]$pack.level).ToUpperInvariant()
            assetId=[int]$pack.assetId
            displayGroupAssetId=[int]$pack.assetId
            description=[string]$pack.name
            currencies=$currencies
            displayGroup=[ordered]@{
                priority=[int]$pack.assetId
                value=([string]$pack.group).ToUpperInvariant()
            }
            sortPriority=[int]$pack.id
            state='active'
            visible=1
            saleType='NONE'
            purchaseCount=0
            purchaseLimit=-1
            isPremium=[bool]$pack.premium
            unopened=$false
        }
    }

    if ($isCl1217703) {
        Write-Log ("STORE CL1217703 COMPAT v0.14.1.11: serving {0} original packs; coins-only; category assets=1,2,3" -f $purchase.Count)
    } else {
        Write-Log ("STORE CL1298564 v0.14.1.11: serving {0} packs; category assets=1,2,3,4" -f $purchase.Count)
    }
    return ([ordered]@{
        purchase=$purchase
        timestamp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Depth 8 -Compress)
}

function Get-PurchasedItemsDocument {
    # The duplicate list must be repeated on the GET that redraws the unassigned
    # tray. FIFA 13 does not derive duplicates from the item JSON itself.
    return ([ordered]@{
        itemData=@($script:PurchasedItems)
        duplicateItemIdList=@($script:PurchasedDuplicatePairs)
    } | ConvertTo-Json -Depth 12 -Compress)
}

function Get-CardLevel([int] $Rating) {
    if ($Rating -le 64) { return 'bronze' }
    if ($Rating -le 74) { return 'silver' }
    return 'gold'
}

function Select-WeightedCard([object[]] $Candidates, [string] $Level, [hashtable] $TakenBase) {
    $free = @($Candidates | Where-Object { -not $TakenBase.ContainsKey([string][int]$_.baseAssetId) })
    if ($free.Count -eq 0) { $free = @($Candidates) }
    if ($free.Count -eq 0) { return $null }

    $decay = [double]$script:RatingDecay[$Level]
    $floor = [int]$script:TierFloor[$Level]
    $total = 0.0
    $weights = New-Object System.Collections.Generic.List[double]
    foreach ($card in $free) {
        $power = [Math]::Max(0,([int]$card.rating - $floor))
        $weight = [Math]::Pow($decay,$power)
        $weights.Add($weight)
        $total += $weight
    }
    if ($total -le 0) { return $free[$script:Rng.Next(0,$free.Count)] }

    $pick = $script:Rng.NextDouble() * $total
    $running = 0.0
    for ($i=0; $i -lt $free.Count; $i++) {
        $running += [double]$weights[$i]
        if ($pick -le $running) { return $free[$i] }
    }
    return $free[$free.Count - 1]
}

function Select-SpecialCard([string] $Level, [hashtable] $TakenBase) {
    # First choose treatment by donor per-card rarity * treatment population.
    # Then rating-weight within that treatment. This keeps ordinary IFs much
    # more common than MOTM/TOTS/TOTY/Record Breaker without making 95+ cards
    # common merely because the catalogue contains them.
    $types = New-Object System.Collections.Generic.List[object]
    $total = 0.0
    foreach ($kind in $script:SpecialCardRarity.Keys) {
        $pool = @($script:PackPools["$Level|special|$kind"])
        if ($pool.Count -eq 0) { continue }
        $available = @($pool | Where-Object { -not $TakenBase.ContainsKey([string][int]$_.baseAssetId) })
        if ($available.Count -eq 0) { $available = $pool }
        $weight = [double]$script:SpecialCardRarity[$kind] * [double]$available.Count
        if ($weight -le 0) { continue }
        $types.Add([pscustomobject]@{ kind=$kind; pool=$available; weight=$weight })
        $total += $weight
    }
    if ($types.Count -eq 0 -or $total -le 0) { return $null }

    $pick = $script:Rng.NextDouble() * $total
    $running = 0.0
    $selected = $types[$types.Count - 1]
    foreach ($entry in $types) {
        $running += [double]$entry.weight
        if ($pick -le $running) { $selected = $entry; break }
    }
    return (Select-WeightedCard -Candidates @($selected.pool) -Level $Level -TakenBase $TakenBase)
}

function Get-OwnedDuplicateItemId([long] $ResourceId, [long] $NewItemId) {
    # The complete seeded club is canonical. This is O(1) and preserves the
    # older item's deterministic id, exactly what duplicateItemIdList wants.
    $seed = $script:FullClubByResourceId[[string]$ResourceId]
    if ($null -ne $seed -and [long]$seed.itemId -ne $NewItemId) {
        return [long]$seed.itemId
    }
    foreach ($item in @($script:ClubExtraItems) + @($script:TradePileItems) + @($script:PurchasedItems)) {
        if ([long]$item.id -eq $NewItemId) { continue }
        if ([long]$item.resourceId -eq $ResourceId) { return [long]$item.id }
    }
    return [long]0
}

function New-PackPurchaseDocument([string] $RequestBody='', [string] $Path='') {
    $req=$null
    try { if (-not [string]::IsNullOrWhiteSpace($RequestBody)) { $req=$RequestBody | ConvertFrom-Json } } catch { $req=$null }
    $packId=0
    if ($req) {
        foreach ($key in @('packId','purchasePackType','purchasedPackId','id','packType','itemId')) {
            if ($req.PSObject.Properties.Name -contains $key) {
                $raw=$req.$key
                if ($raw -as [int]) { $packId=[int]$raw; break }
            }
        }
    }
    if ($packId -le 0 -and $Path -match '/items/(\d+)') { $packId=[int]$Matches[1] }
    $pack=@($script:PackCatalog | Where-Object { [int]$_.id -eq $packId } | Select-Object -First 1)
    if ($pack.Count -eq 0) { return '{"itemList":[],"numberItems":0}' }
    $pack=$pack[0]

    $currency='coins'
    if ($req -and $req.currency -and ([string]$req.currency).ToLowerInvariant() -eq 'points') { $currency='points' }
    if ($currency -eq 'points') {
        if ($null -eq $pack.points -or $script:FifaPoints -lt [int]$pack.points) {
            Write-Log ("PACK refused id={0}: points unavailable/insufficient" -f $packId)
            return '{"itemList":[],"numberItems":0}'
        }
        $script:FifaPoints -= [int]$pack.points
    } else {
        if ($script:Coins -lt [int]$pack.coins) {
            Write-Log ("PACK refused id={0}: need {1} coins, have {2}" -f $packId,$pack.coins,$script:Coins)
            return '{"itemList":[],"numberItems":0}'
        }
        $script:Coins -= [int]$pack.coins
    }

    if ($script:FullClubCatalog.Count -eq 0) {
        # Do not ever go back to the old flattened SquadPlayers draw that sent
        # resourceIds such as 10/54/78 and caused CardsDLL to reject the pack.
        Write-Log "PACK refused: full FIFA 13 card catalogue is unavailable"
        if ($currency -eq 'points') { $script:FifaPoints += [int]$pack.points } else { $script:Coins += [int]$pack.coins }
        return '{"itemList":[],"numberItems":0}'
    }

    $size = [int]$pack.size
    $rareCount = [Math]::Min($size,[int]$pack.rares)
    $rareSlots = @{}
    while ($rareSlots.Count -lt $rareCount) {
        $rareSlots[[string]$script:Rng.Next(0,$size)] = $true
    }

    $items = New-Object System.Collections.Generic.List[object]
    $duplicatePairs = New-Object System.Collections.Generic.List[object]
    $takenBase = @{}
    $specialsDrawn = 0
    $ratingSummary = New-Object System.Collections.Generic.List[int]

    for ($n=0; $n -lt $size; $n++) {
        $rare = $rareSlots.ContainsKey([string]$n)
        $card = $null

        # Any rare PLAYER slot can become a special. All four promo player
        # packs are gold-only, and the 100k pack therefore yields 24 rare gold
        # players with specials mixed in by this exact path.
        if ($rare -and $script:Rng.NextDouble() -lt [double]$script:SpecialChance) {
            $card = Select-SpecialCard -Level ([string]$pack.level) -TakenBase $takenBase
            if ($null -ne $card) { $specialsDrawn++ }
        }
        if ($null -eq $card) {
            $rarityBucket = if ($rare) { 'rare' } else { 'common' }
            $key = "{0}|{1}" -f ([string]$pack.level),$rarityBucket
            $card = Select-WeightedCard -Candidates @($script:PackPools[$key]) -Level ([string]$pack.level) -TakenBase $takenBase
        }
        # A tiny tier may have no common rows; preserve pack size by falling
        # back to its rare base pool, never by inventing an id.
        if ($null -eq $card) {
            $card = Select-WeightedCard -Candidates @($script:PackPools["$($pack.level)|rare"]) -Level ([string]$pack.level) -TakenBase $takenBase
        }
        if ($null -eq $card) {
            Write-Log ("PACK generation failed id={0}: no renderable {1} player" -f $packId,$pack.level)
            if ($currency -eq 'points') { $script:FifaPoints += [int]$pack.points } else { $script:Coins += [int]$pack.coins }
            return '{"itemList":[],"numberItems":0}'
        }

        $itemId = [long]$script:NextPackItemId
        $script:NextPackItemId++
        $item = New-PlayerItem -ItemId $itemId -AssetId ([long]$card.assetId) `
            -TeamId ([int]$card.teamId) -Rating ([int]$card.rating) `
            -Position ([string]$card.position) -LeagueId ([int]$card.leagueId) `
            -Nation ([int]$card.nationId) -Name '' -RareFlag ([int]$card.rareFlag) `
            -ExactCardFacts -IsSpecial:([bool]$card.isSpecial) -Attributes @($card.attributes)
        $items.Add($item)
        $takenBase[[string][int]$card.baseAssetId] = $true
        $ratingSummary.Add([int]$card.rating)

        $older = Get-OwnedDuplicateItemId -ResourceId ([long]$card.assetId) -NewItemId $itemId
        if ($older -gt 0) {
            $duplicatePairs.Add([ordered]@{
                itemId=[long]$itemId
                duplicateItemId=[long]$older
            })
        }
    }

    $script:PurchasedItems = $items.ToArray()
    $script:PurchasedDuplicatePairs = $duplicatePairs.ToArray()

    $ratings = @($ratingSummary.ToArray() | Sort-Object -Descending)
    $top = if ($ratings.Count -gt 0) { [int]$ratings[0] } else { 0 }
    Write-Log ("PACK v0.14.1: opened {0} ({1}) -> {2} real cards, rares={3}, specials={4}, duplicates={5}, topRating={6}, coins={7}" -f `
        $pack.name,$currency,$items.Count,$rareCount,$specialsDrawn,$duplicatePairs.Count,$top,$script:Coins)

    # Exact FutCreatePackServerResponse. duplicateItemIdList elements are
    # {itemId, duplicateItemId}, both 64-bit; this is the ONLY duplicate flag
    # the FIFA 13 frontend reads for a freshly opened pack.
    return ([ordered]@{
        itemList=$items.ToArray()
        numberItems=$items.Count
        purchasedPackId=[long]$pack.id
        duplicateItemIdList=$duplicatePairs.ToArray()
    } | ConvertTo-Json -Depth 12 -Compress)
}

function Get-UserInfo {
    # v0.13.2 bootstrap-parity contract. This is the direct FutGetUserInfo
    # object used by the last build that reliably completed FUT login.
    return ([ordered]@{
        personaId = [long]$script:PersonaId
        clubName = 'FUT13 Local'
        clubAbbr = 'LFT'
        clubNameChangeAllowed = $false
        established = 2012
        divisionOffline = 10
        divisionOnline = 10
        won = 0
        draw = 0
        loss = 0
        seasonTicket = $false
        fifaPointsFromLastYear = 0
        fifaPointsTransferredStatus = 0
        coins = [int]$script:Coins
        credits = [int]$script:Coins
        points = [int]$script:FifaPoints
        fifaPoints = [int]$script:FifaPoints
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Get-CreditsDocument {
    # Exact FutGetUserCredits container. CL1217703 uses a coins-only compatibility
    # wallet so entering Store cannot start the unimplemented first-party FIFA
    # Points commerce path. CL1298564 keeps the already-proven two-currency shape.
    $currencies = @(
        [ordered]@{name='coins';funds=[int]$script:Coins;finalFunds=[int]$script:Coins}
    )
    if ((Get-DetectedRuntimeBuild) -ne '1217703') {
        $currencies += [ordered]@{name='points';funds=[int]$script:FifaPoints;finalFunds=[int]$script:FifaPoints}
    }
    return ([ordered]@{ currencies=$currencies } | ConvertTo-Json -Depth 5 -Compress)
}

function Get-HubDocument {
    $baseClubCount = if ($script:FullClubCatalog.Count -gt 0) { $script:FullClubCatalog.Count } else { $script:SquadPlayers.Count }
    $clubCount=$baseClubCount + (@($script:ClubExtraItems).Count)
    $tradeCount=@($script:TradePileItems).Count
    return ([ordered]@{
        auctionCount=0
        clubPlayers=$clubCount
        onlineSeason=[ordered]@{divisionId=6; points=$null;gamesPlayed=0;totalGames=10}
        offlineSeason=[ordered]@{divisionId=6; points=$null;gamesPlayed=0;totalGames=10}
        tradePile=[ordered]@{count=$tradeCount;selling=0;sold=0}
        watchlist=[ordered]@{count=0;outbid=0;winning=0}
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-ClubStatsDocument {
    if ($script:FullClubCatalog.Count -gt 0) {
        $counts=@{
            players=[int]$script:FullClubStats.players
            playersBronze=[int]$script:FullClubStats.playersBronze
            playersSilver=[int]$script:FullClubStats.playersSilver
            playersGold=[int]$script:FullClubStats.playersGold
            rarePlayers=[int]$script:FullClubStats.rarePlayers
        }
    } else {
        # Preserve the old fallback counts if full-club extraction failed.
        $bronze=0; $silver=0; $gold=0; $rare=0
        foreach($p in $script:SquadPlayers) {
            $rating=[int]$p[2]
            if($rating -le 64){$bronze++}elseif($rating -le 74){$silver++}else{$gold++}
            if($rating -ge 75){$rare++}
        }
        $counts=@{players=$script:SquadPlayers.Count;playersBronze=$bronze;playersSilver=$silver;playersGold=$gold;rarePlayers=$rare}
    }
    foreach ($item in @($script:ClubExtraItems)) {
        $asset = ([long]$item.resourceId -band 0xFFFFFF)
        $native = $script:NativePlayersByAsset[[string]$asset]
        $rating = if ($native) { [int]$native.rating } else { 0 }
        $counts['players'] = [int]$counts['players'] + 1
        if ($rating -le 64) { $counts['playersBronze'] = [int]$counts['playersBronze'] + 1 }
        elseif ($rating -le 74) { $counts['playersSilver'] = [int]$counts['playersSilver'] + 1 }
        else { $counts['playersGold'] = [int]$counts['playersGold'] + 1 }
        if ([int]$item.rareflag -gt 0) { $counts['rarePlayers'] = [int]$counts['rarePlayers'] + 1 }
    }
    $types=@('players','playersBronze','playersSilver','playersGold','rarePlayers','kits','badges','balls','stadia','leagueLogos','staff','staffManager','staffHeadCoach','staffGKCoach','staffPhysio','staffFitnessCoach','consumables','consumablesContract','consumablesTraining','consumablesTeamTalks','consumablesFitness','consumablesHealing','trophies','trophiesOffline','trophiesOnline')
    $stat=@($types | ForEach-Object {[ordered]@{contextId=1;contextValue=0;type=$_;typeValue=$(if($counts.ContainsKey($_)){$counts[$_]}else{0})}})
    return ([ordered]@{stat=$stat}|ConvertTo-Json -Depth 5 -Compress)
}

function Get-ClientDataDocument([string]$Bucket) {
    $key=$Bucket.ToLowerInvariant()
    $entries=if($script:ClientDataBuckets.ContainsKey($key)){@($script:ClientDataBuckets[$key])}else{@()}
    return ([ordered]@{entries=$entries}|ConvertTo-Json -Depth 5 -Compress)
}
function Save-ClientDataDocument([string]$Bucket,[string]$JsonBody) {
    $key=$Bucket.ToLowerInvariant(); $entries=@()
    try { $doc=$JsonBody|ConvertFrom-Json; foreach($e in @($doc.entries)){ if($null -ne $e.key -and $null -ne $e.value){$entries += [ordered]@{key=[int]$e.key;value=[int]$e.value}} } } catch {}
    $script:ClientDataBuckets[$key]=$entries
    return (Get-ClientDataDocument $Bucket)
}

function Get-TradePileDocument {
    # Exact donor FutGetTradePileServerResponse envelope. An empty object is
    # NOT safe for this response class: the retail parser leaves its internal
    # auction vector uninitialised. The post-pack New Items transition asks
    # for tradePile before redrawing purchased/items, so a 404/{} here causes
    # TradePile_InitCB -> FAILURE and FIFA unloads FUT with the generic
    # connection-error popup even though the pack purchase itself succeeded.
    $rows = @()
    foreach ($item in @($script:TradePileItems)) {
        $rows += [ordered]@{
            tradeId = 0
            itemData = $item
        }
    }
    return ([ordered]@{ auctionInfo=@($rows) } | ConvertTo-Json -Depth 12 -Compress)
}

function Get-EmptyLeaderboardDocument {
    # The post-pack hub refresh also asks the user's all-time leaderboard row.
    # The leaderboard member is an array; an explicit empty array is the safe
    # no-data state and avoids turning an optional hub refresh into a 404.
    return '{"leaderboard":[]}'
}

function Move-ItemsDocument([string]$JsonBody) {
    $out=@()
    try {$doc=$JsonBody|ConvertFrom-Json} catch {$doc=$null}
    foreach($row in @($doc.itemData)){
        if($null -eq $row.id){continue}; $id=[int]$row.id; $pile=([string]$row.pile).ToLowerInvariant()
        $item=Get-OwnedPlayerByItemId $id
        if($null -eq $item){$out += [ordered]@{id=$id;pile=$pile;success=$false;reason='item not found'};continue}
        if((Test-IsFullClubSeedItem $id) -and $pile -eq 'club') {
            $out += [ordered]@{id=$id;pile=$pile;success=$true;reason=''}
            continue
        }
        if((Test-IsFullClubSeedItem $id) -and $pile -eq 'trade') {
            $out += [ordered]@{id=$id;pile=$pile;success=$false;reason='full-club seeded copy stays in club'}
            continue
        }
        if($pile -eq 'club'){
            $script:PurchasedItems=@($script:PurchasedItems|Where-Object { [int]$_.id -ne $id })
            $script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object { [long]$_.itemId -ne [long]$id })
            $script:TradePileItems=@($script:TradePileItems|Where-Object { [int]$_.id -ne $id })
            if(-not(@($script:ClubExtraItems|Where-Object { [int]$_.id -eq $id }).Count)){ $script:ClubExtraItems += $item }
        } elseif($pile -eq 'trade'){
            $script:PurchasedItems=@($script:PurchasedItems|Where-Object { [int]$_.id -ne $id })
            $script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object { [long]$_.itemId -ne [long]$id })
            $script:ClubExtraItems=@($script:ClubExtraItems|Where-Object { [int]$_.id -ne $id })
            if(-not(@($script:TradePileItems|Where-Object { [int]$_.id -eq $id }).Count)){ $script:TradePileItems += $item }
        } else {
            $out += [ordered]@{id=$id;pile=$pile;success=$false;reason='unsupported pile'};continue
        }
        $out += [ordered]@{id=$id;pile=$pile;success=$true;reason=''}
    }
    return ([ordered]@{itemData=$out}|ConvertTo-Json -Depth 6 -Compress)
}

function Quick-SellDocument([string]$Path) {
    $ids=@()
    if($Path -match '(?:\?|&)itemIds=([^&]+)'){foreach($x in $Matches[1].Split(',')){if($x -match '^\d+$'){$ids += [int]$x}}}
    if($Path -match '/item/(\d+)(?:\?|$)'){$ids += [int]$Matches[1]}
    foreach($id in @($ids|Select-Object -Unique)){
        $item=Get-OwnedPlayerByItemId $id
        if($null -eq $item){continue}
        # Full-club base copies are a permanent testing catalogue: do not let a
        # quick sell silently remove one of the requested every-player entries.
        if(Test-IsFullClubSeedItem $id){
            Write-Log ("FULL CLUB: ignored quick-sell of seeded item {0}" -f $id)
            continue
        }
        $script:Coins += [int]$item.discardValue
        $script:PurchasedItems=@($script:PurchasedItems|Where-Object { [int]$_.id -ne $id })
        $script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object { [long]$_.itemId -ne [long]$id })
        $script:ClubExtraItems=@($script:ClubExtraItems|Where-Object { [int]$_.id -ne $id })
        $script:TradePileItems=@($script:TradePileItems|Where-Object { [int]$_.id -ne $id })
    }
    return ('{"totalCredits":'+[int]$script:Coins+'}')
}

function Get-Body([string] $Path, [string] $Method = 'GET', [string] $RequestBody = '') {
    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $clean = ($Path -split '\?')[0]

    # -----------------------------------------------------------------------
    # v0.13.2 BOOTSTRAP PARITY ZONE
    #
    # These responses are intentionally the shapes from v0.11.1, the last
    # always-on trace that proceeded from tutorialpopups into purchased/items,
    # pileSize, squad/list, squad/active and the FUT hub.
    #
    # Do not replace these with donor equivalents merely because the donor's
    # deserialiser accepts those fields. Our exact CardsDLL/frontend state
    # machine proved these values/order are load-bearing.
    # -----------------------------------------------------------------------
    if ($clean -eq '/ut/auth') {
        return ('{"sid":"FUT13-LOCAL-SID","serverTime":"' + $now + '","lastOnlineTime":"' + $now + '"}')
    }
    if ($clean -match '/trusteddevice$') {
        return '{"trusted":true,"exists":true,"changed":false}'
    }
    if ($clean -match '/phishing/question$') {
        return '{"attempts":0,"question":""}'
    }
    if ($clean -match '/phishing/validate$') {
        return '{"debug":"","string":"","token":"FUT13-LOCAL-PHISH"}'
    }
    if ($clean -match '/user/accountinfo$') {
        return '{"userAccountInfo":{"personas":[{"personaId":2000001,"personaName":"FUT13 Local","isReturningUser":true,"onlineAccess":true,"trial":false,"userState":null,"userClubList":[{"year":"2013","assetId":1,"teamId":1,"lastAccessTime":1,"platform":"pc","clubName":"FUT13 Local","clubAbbr":"LFT","established":2012,"divisionOnline":10,"badgeId":0,"skuAccessList":{"FFA13PC":1}}],"trialFree":false}]}}'
    }
    if ($clean -match '/settings$') {
        # v0.14.1: exact FIFA 13 FutGetSettingsServerResponse shape recovered
        # by the working donor. The retail parser iterates configs[] and string-
        # compares these five type names. In particular, commerce flow version
        # 1 keeps the old Store purchase path; value 2 enables the transaction
        # flow. Our previous flat object was not the FIFA 13 wire contract.
        return '{"configs":[{"type":"maximumTradePileSize","value":100},{"type":"getOperationTimeoutSec","value":30},{"type":"clubCreateThreshold","value":0},{"type":"fifaPointsCancelTransactionFix","value":1},{"type":"firstPartyCommerceFlowVersion","value":1}]}'
    }
    if ($clean -eq '/ut/delete/auth') { return '{}' }
    if ($clean -match '/match/reset$') { return '{}' }

    # Keep the proven bootstrap envelopes. Transaction is the one exception:
    # v0.14.1 deliberately matches the donor's empty real-money state machine.
    if ($clean -match '/userdata$') {
        return '{"userData":[]}'
    }
    if ($clean -match '/store/transaction(?:/\d+)?$') {
        # Exact donor behavior: this is the unimplemented real-money transaction
        # state machine. The working donor deliberately lets both GET and PUT
        # fall through to an empty object instead of inventing transaction state.
        return '{}'
    }
    if ($clean -match '/clientdata/tutorialpopups$') {
        return '{"entries":[]}'
    }
    if ($clean -match '/clientdata/managerquest$') {
        return '{"entries":[]}'
    }

    # Direct user info is also restored to the known-working parser shape.
    if ($clean -match '/fifa13/user$') {
        return (Get-UserInfo)
    }

    # -----------------------------------------------------------------------
    # DONOR FUNCTIONALITY ZONE
    # From here onward keep the donor-derived FIFA 13 contracts for actual FUT
    # features, while retaining proven stable envelopes where already measured.
    # -----------------------------------------------------------------------

    # Purchased/New Items. This MUST remain before broad store/item routes.
    if ($clean -match '/(?:purchased|store)/items(?:/\d+)?$') {
        if ($Method -in @('POST','PUT')) {
            return (New-PackPurchaseDocument $RequestBody $Path)
        }
        if ($clean -match '/purchased/items$') {
            return (Get-PurchasedItemsDocument)
        }
    }

    # Store catalogue: exact donor parser contract. v0.14.1 removes the
    # artificial 350 ms pacing experiment; the matched CL1298564 CardsDLL now
    # receives the response using its own native callback/ABI layout.
    if ($clean -match '/store/purchasegroup(?:/all)?$') {
        return (Get-StoreDocument)
    }

    # Post-pack transition dependencies. These are requested immediately
    # after FutCreatePackServerResponse, before the New Items tray is redrawn.
    if ($clean -match '/tradePile$') {
        return (Get-TradePileDocument)
    }
    if ($clean -match '/leaderboards/period/[^/]+/user/\d+$' -or $clean -match '/leaderboards(?:/options)?$') {
        return (Get-EmptyLeaderboardDocument)
    }

    # Club/search/item operations.
    if ($clean -match '/club/stats/staff$') {
        return (Get-StaffStatsDocument)
    }
    if ($clean -match '/club/stats/(?:year|newcards)$') {
        return (Get-ClubStatsDocument)
    }
    if ($clean -match '/club/stats/(?:country|league)/\d+$') {
        return '{"stat":[]}'
    }
    if ($clean -match '/clubUser$') {
        return '{"user":[{"persona":"FUT13 Local","personaId":2000001,"public":false}]}'
    }
    if ($clean -match '/fifa13/club$') {
        return (Get-ClubSearchDocument $Path)
    }
    if ($clean -match '/ut/delete/game/fifa13/item(?:/\d+)?$') {
        return (Quick-SellDocument $Path)
    }
    if ($clean -match '/game/fifa13/item$' -and $Method -eq 'PUT') {
        return (Move-ItemsDocument $RequestBody)
    }

    # Squads: donor's decoded active/full envelope and compact list.
    if ($clean -match '/squad/list$') {
        return (Build-SquadListDocument)
    }
    if ($clean -match '/squad/active$') {
        return (Build-SquadDetailDocument)
    }
    if ($clean -match '/squad/\d+$') {
        if ($Method -in @('POST','PUT')) {
            return (Update-SquadFromRequest $RequestBody)
        }
        return (Build-SquadDetailDocument)
    }
    if ($clean -match '/squad$') {
        if ($Method -in @('POST','PUT')) {
            return (Update-SquadFromRequest $RequestBody)
        }
        return (Build-SquadDetailDocument)
    }

    # Wallet/hub/post-login data.
    if ($clean -match '/user/credits$' -or $clean -match '/credits$') {
        return (Get-CreditsDocument)
    }
    if ($clean -match '/eventfeed$') {
        return '{"events":[]}'
    }
    if ($clean -match '/hub$') {
        return (Get-HubDocument)
    }

    # Stable capacity contract measured in the working hub.
    if ($clean -match '/clientdata/pileSize$') {
        return '{"entries":[{"key":2,"value":30},{"key":3,"value":100},{"key":4,"value":30}]}'
    }

    # Other clientdata buckets can use donor persistence, but the two bootstrap
    # buckets above are explicit arrays and never flow through this generic code.
    if ($clean -match '/clientdata/([^/]+)$') {
        $bucket = $Matches[1]
        if ($Method -in @('POST','PUT')) {
            return (Save-ClientDataDocument $bucket $RequestBody)
        }
        return (Get-ClientDataDocument $bucket)
    }

    if ($clean -match '/user/historical$') {
        return '{"clubName":"FUT13 Local","clubAbbr":"LFT","ItemType":0}'
    }
    if ($clean -match '/user/action$' -or $clean -match '/useraction$') {
        return '{"userActions":[]}'
    }
    if ($clean -match '/user/club$') {
        return (Get-UserInfo)
    }
    if ($clean -match '/user/list$') {
        return '{"userInfo":[]}'
    }

    return $null
}

# ===========================================================================
# v0.14.1 SHIP BASELINE: EMPTY SQLITE CLUB + FULL NATIVE ITEM PACKS
# ===========================================================================
# The 12,115-card player catalogue below is a DRAW POOL only. It is not an
# ownership seed. The player's actual club starts empty and is persisted in a
# local SQLite database through tools/fut13_save.py.

$rootDirectory = Split-Path -Parent $PSScriptRoot
if (-not $PythonPath) {
    try {
        $settingsPath = Join-Path $rootDirectory 'local.settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            if ($settings.python) { $PythonPath = [string]$settings.python }
        }
    } catch {}
}
if (-not $PythonPath) {
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) { $PythonPath = $py.Source }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
    throw 'v0.14.1 save-state requires Python 3.10+. Run INSTALL_PREREQUISITES.cmd first.'
}
if (-not $SavePath) { $SavePath = Join-Path $rootDirectory 'save\fut13-local.sqlite3' }
if (-not $ItemCatalogPath) { $ItemCatalogPath = Join-Path $rootDirectory 'data\fifa13-native-item-catalog.json' }
$script:SaveHelper = Join-Path $rootDirectory 'tools\fut13_save.py'
if (-not (Test-Path -LiteralPath $script:SaveHelper)) { throw "Save helper missing: $script:SaveHelper" }

# Native non-player/manager pool generated from cards0.big on this machine.
$script:ItemCatalog = @()
$script:ItemByResourceId = @{}
$script:ItemPools = @{}
if (Test-Path -LiteralPath $ItemCatalogPath) {
    try {
        $itemDoc = Get-Content -LiteralPath $ItemCatalogPath -Raw | ConvertFrom-Json
        $script:ItemCatalog = @($itemDoc.items)
        foreach ($entry in $script:ItemCatalog) {
            $script:ItemByResourceId[[string][long]$entry.resourceId] = $entry
            $rarity = if ([bool]$entry.rare) { 'rare' } else { 'common' }
            $key = "{0}|{1}|{2}" -f ([string]$entry.level),$rarity,([string]$entry.kind)
            if (-not $script:ItemPools.ContainsKey($key)) {
                # Windows PowerShell 5.1 can throw "Argument types do not match"
                # when a List[object] containing PSCustomObject rows is expanded.
                # Plain arrays are safer for these small native item pools.
                $script:ItemPools[$key] = @()
            }
            $script:ItemPools[$key] += ,$entry
        }
        Write-Log ("ITEM POOL v0.14.1: loaded {0} native non-player/staff cards from cards_ng_db" -f $script:ItemCatalog.Count)
    } catch {
        Write-Log ("ITEM POOL LOAD ERROR v0.14.1: {0}" -f $_.Exception.Message)
        $script:ItemCatalog=@(); $script:ItemByResourceId=@{}; $script:ItemPools=@{}
    }
} else {
    Write-Log ("ITEM POOL LOAD ERROR v0.14.1: missing {0}" -f $ItemCatalogPath)
}

# Normal-pack composition, ported from the donor's measured/authored FUT 13
# model. Promo player packs remain player-only by definition.
$script:PlayerCountWeights = @{ '1'=2; '2'=16; '3'=38; '4'=34; '5'=8; '6'=2 }
$script:ItemKindWeights = [ordered]@{
    contract=20; health=16; training=15; coins=1; pack=1
    kit=13; badge=11; stadium=6; ball=4; manager=5
    headCoach=2; gkCoach=2; physio=2; fitnessCoach=2
}
$script:UniqueKinds = @{
    player=$true; kit=$true; badge=$true; stadium=$true; ball=$true
    manager=$true; headCoach=$true; gkCoach=$true; physio=$true; fitnessCoach=$true
}
$script:OffTierChance = 0.15

function Get-WeightedPlayerCount {
    $total=0; foreach($w in $script:PlayerCountWeights.Values){$total += [int]$w}
    $pick=$script:Rng.Next(0,$total); $run=0
    foreach($k in $script:PlayerCountWeights.Keys){$run += [int]$script:PlayerCountWeights[[string]$k]; if($pick -lt $run){return [int]$k}}
    return 3
}

function Get-ItemTierValue([object]$row) {
    if ($null -ne $row.rating -and [int]$row.rating -gt 0) { return [int]$row.rating }
    if ($null -ne $row.value -and [int]$row.value -gt 0) { return [int]$row.value }
    return 0
}

function New-NativeCatalogItem([long]$ItemId,[object]$row) {
    $tier = Get-ItemTierValue $row
    $rare = if ([bool]$row.rare) { 1 } else { 0 }
    $out=[ordered]@{
        id=[long]$ItemId
        resourceId=[long]$row.resourceId
        itemType=[string]$row.itemType
        rareflag=$rare
        timestamp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        owners=1
        lastSalePrice=0
        discardValue=[Math]::Max(0,[Math]::Min(65535,$tier*5))
    }
    if ($null -ne $row.cardsubtypeid -and [int]$row.cardsubtypeid -gt 0) { $out['cardsubtypeid']=[int]$row.cardsubtypeid }
    if ($null -ne $row.teamId -and [int]$row.teamId -gt 0) { $out['teamid']=[int]$row.teamId }
    if ($row.formation) { $out['formation']=[string]$row.formation }
    elseif ([string]$row.kind -in @('manager','headCoach','gkCoach','physio','fitnessCoach')) { $out['formation']='f442' }
    # Staff/managers use the ordinary condition-bearing card path. Vanity and
    # consumables deliberately omit these fields; sending condition state on a
    # contract/kit writes into unrelated native card members.
    if ([string]$row.kind -in @('manager','headCoach','gkCoach','physio','fitnessCoach')) {
        $out['contract']=7; $out['fitness']=99; $out['morale']=50; $out['injuryGames']=0; $out['injuryType']=0
    }
    return $out
}

function Select-NativeItem([string]$Level,[bool]$Rare,[hashtable]$TakenResource) {
    $rarity=if($Rare){'rare'}else{'common'}
    $availableKinds=@()
    $total=0.0
    foreach($kind in $script:ItemKindWeights.Keys){
        $key="$Level|$rarity|$kind"
        if(-not $script:ItemPools.ContainsKey($key)){continue}
        $pool=@($script:ItemPools[$key])
        if($pool.Count -eq 0){continue}
        $w=[double]$script:ItemKindWeights[$kind]
        $availableKinds += ,[pscustomobject]@{kind=[string]$kind;pool=$pool;weight=$w}
        $total += $w
    }
    if($availableKinds.Count -eq 0 -or $total -le 0){return $null}

    $pick=$script:Rng.NextDouble()*$total
    $run=0.0
    $selected=$availableKinds[$availableKinds.Count-1]
    foreach($x in $availableKinds){
        $run += [double]$x.weight
        if($pick -le $run){$selected=$x;break}
    }

    $pool=@($selected.pool)
    if($script:UniqueKinds.ContainsKey([string]$selected.kind)){
        $free=@($pool|Where-Object{-not $TakenResource.ContainsKey([string][long]$_.resourceId)})
        if($free.Count -gt 0){$pool=$free}
    }
    if($pool.Count -eq 0){return $null}

    if($Rare){
        $sum=0.0
        $weights=@()
        foreach($r in $pool){
            $w=[double][Math]::Max(1,[int]$r.rareWeight)
            $weights += $w
            $sum += $w
        }
        if($sum -gt 0){
            $q=$script:Rng.NextDouble()*$sum
            $acc=0.0
            for($i=0;$i -lt $pool.Count;$i++){
                $acc += [double]$weights[$i]
                if($q -le $acc){return [pscustomobject]@{kind=[string]$selected.kind;row=$pool[$i]}}
            }
        }
    }
    return [pscustomobject]@{kind=[string]$selected.kind;row=$pool[$script:Rng.Next(0,$pool.Count)]}
}

function Get-ResourceFacts([long]$ResourceId) {
    $p=$script:FullClubByResourceId[[string]$ResourceId]
    if($null -ne $p){return [pscustomobject]@{kind='player';level=(Get-CardLevel ([int]$p.rating));rating=[int]$p.rating;teamId=[int]$p.teamId;leagueId=[int]$p.leagueId;nationId=[int]$p.nationId;position=[string]$p.position}}
    $m=$script:ItemByResourceId[[string]$ResourceId]
    if($null -ne $m){return [pscustomobject]@{kind=[string]$m.kind;level=[string]$m.level;rating=(Get-ItemTierValue $m);teamId=[int]$m.teamId;leagueId=[int]$m.leagueId;nationId=[int]$m.nationId;position=''}}
    return $null
}

# ---------------------------------------------------------------------------
# SQLite save state
# ---------------------------------------------------------------------------
function Load-SaveState {
    $raw = & $PythonPath $script:SaveHelper --db $SavePath load 2>&1
    if($LASTEXITCODE -ne 0){throw ("Could not load SQLite save: {0}" -f (($raw|Out-String).Trim()))}
    $doc=(($raw|Out-String).Trim()|ConvertFrom-Json)
    $script:Coins=[int64]$doc.club.coins
    $script:FifaPoints=[int]$doc.club.fifa_points
    $script:SquadName=[string]$doc.club.squad_name
    $script:SquadFormation=[string]$doc.club.formation
    $script:SquadChemistry=if($null -eq $doc.club.chemistry){$null}else{[int]$doc.club.chemistry}
    $script:SquadStarRating=if($null -eq $doc.club.star_rating){$null}else{[int]$doc.club.star_rating}
    $script:SquadRating=if($null -eq $doc.club.rating){$null}else{[int]$doc.club.rating}
    $script:SquadOrder=@(0)*23
    for($i=0;$i -lt [Math]::Min(23,@($doc.squadOrder).Count);$i++){$script:SquadOrder[$i]=[int]$doc.squadOrder[$i]}
    $script:ClubExtraItems=@();$script:TradePileItems=@();$script:PurchasedItems=@();$script:PurchasedDuplicatePairs=@()
    foreach($wrapped in @($doc.items)){
        $it=$wrapped.item;$pile=([string]$wrapped.pile).ToLowerInvariant()
        if($pile -eq 'club'){$script:ClubExtraItems += $it}
        elseif($pile -in @('trade','tradepile')){$script:TradePileItems += $it}
        elseif($pile -in @('unassigned','purchased')){$script:PurchasedItems += $it}
    }
    $script:ClientDataBuckets=@{}
    if($doc.clientData){foreach($prop in $doc.clientData.PSObject.Properties){$script:ClientDataBuckets[[string]$prop.Name]=@($prop.Value)}}
    $script:NextPackItemId=[Math]::Max(20000,[int64]$doc.nextItemId)
    # Recompute duplicate pairs for a tray restored after restart.
    $pairs=@()
    foreach($it in @($script:PurchasedItems)){
        $facts=Get-ResourceFacts ([long]$it.resourceId)
        $kind=if($facts){[string]$facts.kind}else{'player'}
        $older=Get-OwnedDuplicateItemId -ResourceId ([long]$it.resourceId) -NewItemId ([long]$it.id) -Kind $kind
        if($older -gt 0){$pairs += [ordered]@{itemId=[long]$it.id;duplicateItemId=[long]$older}}
    }
    $script:PurchasedDuplicatePairs=$pairs
    Write-Log ("SQLITE SAVE v0.14.1: {0}; club={1} items; unassigned={2}; trade={3}; coins={4}" -f $SavePath,@($script:ClubExtraItems).Count,@($script:PurchasedItems).Count,@($script:TradePileItems).Count,$script:Coins)
}

function Persist-SaveState {
    try{
        $items=@()
        foreach($it in @($script:ClubExtraItems)){$items += ,[pscustomobject][ordered]@{pile='club';item=$it}}
        foreach($it in @($script:TradePileItems)){$items += ,[pscustomobject][ordered]@{pile='tradepile';item=$it}}
        foreach($it in @($script:PurchasedItems)){$items += ,[pscustomobject][ordered]@{pile='unassigned';item=$it}}
        $doc=[ordered]@{
            club=[ordered]@{coins=[int64]$script:Coins;fifaPoints=[int]$script:FifaPoints;squadName=$script:SquadName;formation=$script:SquadFormation;chemistry=$script:SquadChemistry;starRating=$script:SquadStarRating;rating=$script:SquadRating}
            items=@($items);squadOrder=@($script:SquadOrder);clientData=$script:ClientDataBuckets;nextItemId=[int64]$script:NextPackItemId
        }
        $saveDir=Split-Path -Parent $SavePath;New-Item -ItemType Directory -Force -Path $saveDir|Out-Null
        $tmp=Join-Path $saveDir ("snapshot-{0}-{1}.json" -f $PID,[Guid]::NewGuid().ToString('N'))
        $doc|ConvertTo-Json -Depth 20 -Compress|Set-Content -LiteralPath $tmp -Encoding UTF8
        $out=& $PythonPath $script:SaveHelper --db $SavePath snapshot --input $tmp 2>&1
        $code=$LASTEXITCODE;Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if($code -ne 0){throw (($out|Out-String).Trim())}
    }catch{Write-Log ("SQLITE SAVE ERROR v0.14.1: {0}" -f $_.Exception.Message)}
}

# Full 12,115-card catalogue remains a pool, NOT owned inventory.
$script:ClubExtraItems=@();$script:TradePileItems=@();$script:PurchasedItems=@();$script:PurchasedDuplicatePairs=@();$script:SquadOrder=@(0)*23

# The old full-club test build treated every pool row as owned. Disable that
# identity path completely while retaining FullClubByResourceId for pack facts.
function Test-IsFullClubSeedItem([int]$ItemId){return $false}
function Get-OwnedPlayerByItemId([int]$ItemId){
    foreach($item in @($script:ClubExtraItems)+@($script:TradePileItems)+@($script:PurchasedItems)){if([int64]$item.id -eq [int64]$ItemId){return $item}}
    return $null
}

function Get-OwnedDuplicateItemId([long]$ResourceId,[long]$NewItemId,[string]$Kind='player'){
    if(-not $script:UniqueKinds.ContainsKey($Kind)){return [long]0}
    foreach($item in @($script:ClubExtraItems)+@($script:TradePileItems)+@($script:PurchasedItems)){
        if([long]$item.id -eq $NewItemId){continue}
        if([long]$item.resourceId -eq $ResourceId){return [long]$item.id}
    }
    return [long]0
}

Load-SaveState

function Get-ClubSearchDocument([string]$Path){
    $type=if($Path -match '(?:\?|&)type=([^&]+)'){[Uri]::UnescapeDataString($Matches[1]).ToLowerInvariant()}else{'player'}
    $position=if($Path -match '(?:\?|&)position=([^&]+)'){[Uri]::UnescapeDataString($Matches[1]).ToUpperInvariant()}else{''}
    $level=if($Path -match '(?:\?|&)level=([^&]+)'){[Uri]::UnescapeDataString($Matches[1]).ToLowerInvariant()}else{'any'}
    $nation=if($Path -match '(?:\?|&)nation=(\d+)'){[int]$Matches[1]}else{0};$league=if($Path -match '(?:\?|&)league=(\d+)'){[int]$Matches[1]}else{0};$team=if($Path -match '(?:\?|&)team=(\d+)'){[int]$Matches[1]}else{0}
    $start=if($Path -match '(?:\?|&)start=(\d+)'){[int]$Matches[1]}else{0};$count=if($Path -match '(?:\?|&)(?:count|num)=(\d+)'){[Math]::Max(1,[Math]::Min(100,[int]$Matches[1]))}else{100}
    $wanted=switch($type){'badge'{@('custom')};'custom'{@('custom')};'healing'{@('health')};'development'{@('training','contract','health','misc')};'staff'{@('manager','headCoach','gkCoach','physio','fitnessCoach')};default{@($type)}}
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($item in @($script:ClubExtraItems)){
        if($wanted.Count -gt 0 -and ([string]$item.itemType) -notin $wanted){continue}
        $facts=Get-ResourceFacts ([long]$item.resourceId);if($null -eq $facts){continue}
        if($position -and [string]$facts.position -ne $position){continue}
        if($level -ne 'any' -and [string]$facts.level -ne $level){continue}
        if($nation -gt 0 -and [int]$facts.nationId -ne $nation){continue};if($league -gt 0 -and [int]$facts.leagueId -ne $league){continue};if($team -gt 0 -and [int]$facts.teamId -ne $team){continue}
        $rows.Add([pscustomobject]@{Rating=[int]$facts.rating;Id=[long]$item.id;Doc=$item})
    }
    $selected=@($rows|Sort-Object @{Expression={[int]$_.Rating};Descending=$true},@{Expression={[long]$_.Id};Ascending=$true}|Select-Object -Skip $start -First $count)
    return ([ordered]@{itemData=@($selected|ForEach-Object{$_.Doc})}|ConvertTo-Json -Depth 14 -Compress)
}

function Get-HubDocument{
    $playerCount=@($script:ClubExtraItems|Where-Object{[string]$_.itemType -eq 'player'}).Count
    return ([ordered]@{auctionCount=0;clubPlayers=$playerCount;onlineSeason=[ordered]@{divisionId=6;points=$null;gamesPlayed=0;totalGames=10};offlineSeason=[ordered]@{divisionId=6;points=$null;gamesPlayed=0;totalGames=10};tradePile=[ordered]@{count=@($script:TradePileItems).Count;selling=0;sold=0};watchlist=[ordered]@{count=0;outbid=0;winning=0}}|ConvertTo-Json -Depth 6 -Compress)
}

function Get-ClubStatsDocument{
    $counts=@{players=0;playersBronze=0;playersSilver=0;playersGold=0;rarePlayers=0;kits=0;badges=0;balls=0;stadia=0;leagueLogos=0;staff=0;staffManager=0;staffHeadCoach=0;staffGKCoach=0;staffPhysio=0;staffFitnessCoach=0;consumables=0;consumablesContract=0;consumablesTraining=0;consumablesTeamTalks=0;consumablesFitness=0;consumablesHealing=0;trophies=0;trophiesOffline=0;trophiesOnline=0}
    foreach($it in @($script:ClubExtraItems)){
        $facts=Get-ResourceFacts ([long]$it.resourceId);$kind=if($facts){[string]$facts.kind}else{''}
        if($kind -eq 'player'){$counts.players++;if($facts.level -eq 'bronze'){$counts.playersBronze++}elseif($facts.level -eq 'silver'){$counts.playersSilver++}else{$counts.playersGold++};if([int]$it.rareflag -gt 0){$counts.rarePlayers++}}
        elseif($kind -eq 'kit'){$counts.kits++}elseif($kind -eq 'badge'){$counts.badges++}elseif($kind -eq 'ball'){$counts.balls++}elseif($kind -eq 'stadium'){$counts.stadia++}
        elseif($kind -in @('manager','headCoach','gkCoach','physio','fitnessCoach')){$counts.staff++;$key=switch($kind){'manager'{'staffManager'};'headCoach'{'staffHeadCoach'};'gkCoach'{'staffGKCoach'};'physio'{'staffPhysio'};'fitnessCoach'{'staffFitnessCoach'}};$counts[$key]++}
        elseif($kind -in @('training','contract','health','coins','pack')){$counts.consumables++;if($kind -eq 'contract'){$counts.consumablesContract++}elseif($kind -eq 'training'){$counts.consumablesTraining++}elseif($kind -eq 'health'){$counts.consumablesHealing++}}
    }
    $stat=@();foreach($key in $counts.Keys){$stat += [ordered]@{contextId=1;contextValue=0;type=$key;typeValue=[int]$counts[$key]}}
    return ([ordered]@{stat=$stat}|ConvertTo-Json -Depth 5 -Compress)
}

function Get-StaffStatsDocument {
    # FIFA 13's FutStaffBonus response is an ARRAY named `bonus`. A flat object
    # or an unrelated itemData envelope leaves the retail parser in the wrong
    # element loop. Only owned staff contributes; the amount is read from the
    # same native cards_ng_db row used to build the pack item.
    $bonus = @{
        contract=0; fitness=0; managerTalk=0
        pace=0; shooting=0; passing=0; dribbling=0; defending=0; heading=0
        gkDiving=0; gkHandling=0; gkKicking=0; gkOneOnOne=0; gkPositioning=0; gkReflexes=0
        physioArm=0; physioBack=0; physioFoot=0; physioHead=0; physioHip=0; physioLeg=0; physioShoudler=0
    }
    $staffFields = @{
        headCoach=@('pace','shooting','passing','dribbling','defending','heading')
        gkCoach=@('gkDiving','gkHandling','gkKicking','gkOneOnOne','gkPositioning','gkReflexes')
        fitnessCoach=@('fitness')
        physio=@('physioArm','physioBack','physioFoot','physioHead','physioHip','physioLeg','physioShoudler')
    }
    foreach ($item in @($script:ClubExtraItems)) {
        $row = $script:ItemByResourceId[[string][long]$item.resourceId]
        if ($null -eq $row) { continue }
        $kind = [string]$row.kind
        if (-not $staffFields.ContainsKey($kind)) { continue }
        $amount = if ($null -ne $row.amount) { [int]$row.amount } else { 0 }
        if ($amount -le 0) { continue }
        foreach ($field in @($staffFields[$kind])) {
            $bonus[$field] = [Math]::Min(99, [int]$bonus[$field] + $amount)
        }
    }
    $entries = @()
    foreach ($field in @('contract','fitness','managerTalk','pace','shooting','passing','dribbling','defending','heading','gkDiving','gkHandling','gkKicking','gkOneOnOne','gkPositioning','gkReflexes','physioArm','physioBack','physioFoot','physioHead','physioHip','physioLeg','physioShoudler')) {
        if ([int]$bonus[$field] -gt 0) { $entries += [ordered]@{type=$field;value=[int]$bonus[$field]} }
    }
    return ([ordered]@{bonus=$entries} | ConvertTo-Json -Depth 5 -Compress)
}

function New-PackPurchaseDocument([string]$RequestBody='', [string]$Path='') {
    $req = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($RequestBody)) { $req = $RequestBody | ConvertFrom-Json }
    } catch { $req = $null }

    $packId = 0
    if ($req) {
        foreach ($key in @('packId','purchasePackType','purchasedPackId','id','packType','itemId')) {
            if ($req.PSObject.Properties.Name -contains $key) {
                $raw = $req.$key
                $parsed = 0
                if ([int]::TryParse([string]$raw, [ref]$parsed)) { $packId = $parsed; break }
            }
        }
    }
    if ($packId -le 0 -and $Path -match '/items/(\d+)') { $packId = [int]$Matches[1] }

    $found = @($script:PackCatalog | Where-Object { [int]$_.id -eq $packId } | Select-Object -First 1)
    if ($found.Count -eq 0) {
        Write-Log ("PACK v0.14.1: unknown pack id {0}" -f $packId)
        return '{"itemList":[],"numberItems":0}'
    }
    $pack = $found[0]

    $currency = 'coins'
    if ($req -and $req.currency -and ([string]$req.currency).ToLowerInvariant() -eq 'points') { $currency = 'points' }
    $price = if ($currency -eq 'points') { if ($null -eq $pack.points) { -1 } else { [int]$pack.points } } else { [int]$pack.coins }
    if ($price -lt 0) { return '{"itemList":[],"numberItems":0}' }
    if ($currency -eq 'points') {
        if ($script:FifaPoints -lt $price) { return '{"itemList":[],"numberItems":0}' }
    } elseif ($script:Coins -lt $price) {
        return '{"itemList":[],"numberItems":0}'
    }

    $oldNextItemId = [int64]$script:NextPackItemId
    try {
        $size = [int]$pack.size
        $rareCount = [Math]::Min($size, [int]$pack.rares)
        $rareSlots = @{}
        while ($rareSlots.Count -lt $rareCount) {
            $rareSlots[[string]$script:Rng.Next(0, $size)] = $true
        }

        # Promo packs 7-10 are explicitly player-only. The six ordinary packs
        # use the donor's measured distribution: usually 3-4 players and the
        # remaining slots are native contracts, health/training, staff and club
        # cosmetics from cards_ng_db.
        $playerOnly = ([int]$pack.id -ge 7)
        $playerCount = if ($playerOnly) { $size } else { [Math]::Min($size, (Get-WeightedPlayerCount)) }
        $slotKinds = @()
        for ($i=0; $i -lt $playerCount; $i++) { $slotKinds += 'player' }
        for ($i=$playerCount; $i -lt $size; $i++) { $slotKinds += 'item' }
        $slotKinds = @($slotKinds | Sort-Object { $script:Rng.Next() })

        $items = @()
        $dups = @()
        $takenBase = @{}
        $takenResource = @{}
        $specials = 0
        $offTierUsed = $false
        $actualPlayers = 0

        for ($n=0; $n -lt $size; $n++) {
            $rare = $rareSlots.ContainsKey([string]$n)
            $kind = [string]$slotKinds[$n]
            $item = $null
            $resourceKind = $kind

            if ($kind -eq 'player') {
                $level = [string]$pack.level
                $card = $null

                if ($rare -and -not $playerOnly -and -not $offTierUsed -and
                    $level -in @('gold','silver') -and
                    $script:Rng.NextDouble() -lt $script:OffTierChance) {
                    $off = if ($level -eq 'gold') { 'silver' } else { 'bronze' }
                    $floor = if ($level -eq 'gold') { 70 } else { 60 }
                    $cand = @($script:PackPools["$off|rare"] | Where-Object { [int]$_.rating -ge $floor })
                    $card = Select-WeightedCard -Candidates $cand -Level $off -TakenBase $takenBase
                    if ($null -ne $card) { $offTierUsed = $true }
                }

                if ($null -eq $card -and $rare -and $script:Rng.NextDouble() -lt [double]$script:SpecialChance) {
                    $card = Select-SpecialCard -Level $level -TakenBase $takenBase
                    if ($null -ne $card) { $specials++ }
                }

                if ($null -eq $card) {
                    $bucket = if ($rare) { 'rare' } else { 'common' }
                    $card = Select-WeightedCard -Candidates @($script:PackPools["$level|$bucket"]) -Level $level -TakenBase $takenBase
                }
                if ($null -eq $card) {
                    $card = Select-WeightedCard -Candidates @($script:PackPools["$level|rare"]) -Level $level -TakenBase $takenBase
                }

                # If that tier genuinely lacks a player for this rarity, spend
                # the slot on a same-rarity native item. This preserves the
                # advertised rare count instead of silently returning common.
                if ($null -eq $card) {
                    $kind = 'item'
                    $resourceKind = 'item'
                } else {
                    $id = [long]$script:NextPackItemId; $script:NextPackItemId++
                    $item = New-PlayerItem -ItemId $id -AssetId ([long]$card.assetId) `
                        -TeamId ([int]$card.teamId) -Rating ([int]$card.rating) `
                        -Position ([string]$card.position) -LeagueId ([int]$card.leagueId) `
                        -Nation ([int]$card.nationId) -Name '' -RareFlag ([int]$card.rareFlag) `
                        -ExactCardFacts -IsSpecial:([bool]$card.isSpecial) -Attributes @($card.attributes)
                    $takenBase[[string][int]$card.baseAssetId] = $true
                    $actualPlayers++
                }
            }

            if ($null -eq $item) {
                if ($script:ItemCatalog.Count -eq 0) { throw 'Native item catalogue unavailable' }
                $draw = Select-NativeItem -Level ([string]$pack.level) -Rare:$rare -TakenResource $takenResource
                if ($null -eq $draw) {
                    # Extremely defensive final fallback: if cards_ng_db has no
                    # item at this exact tier/rarity, use a player so the pack
                    # still contains exactly N valid cards.
                    $bucket = if ($rare) { 'rare' } else { 'common' }
                    $card = Select-WeightedCard -Candidates @($script:PackPools["$($pack.level)|$bucket"]) `
                        -Level ([string]$pack.level) -TakenBase $takenBase
                    if ($null -eq $card) {
                        $card = Select-WeightedCard -Candidates @($script:PackPools["$($pack.level)|rare"]) `
                            -Level ([string]$pack.level) -TakenBase $takenBase
                    }
                    if ($null -eq $card) { throw "No valid pack candidate for $($pack.level)/rare=$rare" }
                    $id = [long]$script:NextPackItemId; $script:NextPackItemId++
                    $item = New-PlayerItem -ItemId $id -AssetId ([long]$card.assetId) `
                        -TeamId ([int]$card.teamId) -Rating ([int]$card.rating) `
                        -Position ([string]$card.position) -LeagueId ([int]$card.leagueId) `
                        -Nation ([int]$card.nationId) -Name '' -RareFlag ([int]$card.rareFlag) `
                        -ExactCardFacts -IsSpecial:([bool]$card.isSpecial) -Attributes @($card.attributes)
                    $resourceKind = 'player'
                    $takenBase[[string][int]$card.baseAssetId] = $true
                    $actualPlayers++
                } else {
                    $resourceKind = [string]$draw.kind
                    $id = [long]$script:NextPackItemId; $script:NextPackItemId++
                    $item = New-NativeCatalogItem -ItemId $id -row $draw.row
                    if ($script:UniqueKinds.ContainsKey($resourceKind)) {
                        $takenResource[[string][long]$draw.row.resourceId] = $true
                    }
                }
            }

            $items += ,$item
            $older = Get-OwnedDuplicateItemId -ResourceId ([long]$item.resourceId) `
                -NewItemId ([long]$item.id) -Kind $resourceKind
            if ($older -gt 0) {
                $dups += ,[pscustomobject][ordered]@{ itemId=[long]$item.id; duplicateItemId=[long]$older }
            }
        }

        # Commit the purchase only after every slot was successfully generated.
        if ($currency -eq 'points') { $script:FifaPoints -= $price } else { $script:Coins -= $price }
        $script:PurchasedItems = @($items)
        $script:PurchasedDuplicatePairs = @($dups)
        Persist-SaveState

        Write-Log ("PACK v0.14.1: {0} -> items={1}, players={2}, nonPlayers={3}, rares={4}, specials={5}, duplicates={6}, coins={7}" -f `
            $pack.name,$items.Count,$actualPlayers,($items.Count-$actualPlayers),$rareCount,$specials,$dups.Count,$script:Coins)
        return ([ordered]@{
            itemList=@($items)
            numberItems=$items.Count
            purchasedPackId=[long]$pack.id
            duplicateItemIdList=@($dups)
        } | ConvertTo-Json -Depth 14 -Compress)
    } catch {
        $script:NextPackItemId = $oldNextItemId
        Write-Log ("PACK ERROR v0.14.1: pack={0} error={1} at={2}" -f $pack.name,$_.Exception.Message,$_.InvocationInfo.PositionMessage)

        # Never let a mixed-pack implementation error create a successful
        # zero-card response: FIFA's New Items screen cannot recover from it.
        # Fall back to the already-proven player-card contract for this one pack.
        try {
            $size=[int]$pack.size
            $rareCount=[Math]::Min($size,[int]$pack.rares)
            $rareSlots=@{}
            while($rareSlots.Count -lt $rareCount){$rareSlots[[string]$script:Rng.Next(0,$size)]=$true}
            $fallbackItems=@();$fallbackDups=@();$takenBase=@()
            for($n=0;$n -lt $size;$n++){
                $rare=$rareSlots.ContainsKey([string]$n)
                $bucket=if($rare){'rare'}else{'common'}
                $card=Select-WeightedCard -Candidates @($script:PackPools["$($pack.level)|$bucket"]) -Level ([string]$pack.level) -TakenBase $takenBase
                if($null -eq $card){$card=Select-WeightedCard -Candidates @($script:PackPools["$($pack.level)|rare"]) -Level ([string]$pack.level) -TakenBase $takenBase}
                if($null -eq $card){throw "No safe fallback player for $($pack.level)/$bucket"}
                $id=[long]$script:NextPackItemId;$script:NextPackItemId++
                $item=New-PlayerItem -ItemId $id -AssetId ([long]$card.assetId) `
                    -TeamId ([int]$card.teamId) -Rating ([int]$card.rating) `
                    -Position ([string]$card.position) -LeagueId ([int]$card.leagueId) `
                    -Nation ([int]$card.nationId) -Name '' -RareFlag ([int]$card.rareFlag) `
                    -ExactCardFacts -IsSpecial:([bool]$card.isSpecial) -Attributes @($card.attributes)
                $fallbackItems += ,$item
                $takenBase[[string][int]$card.baseAssetId]=$true
                $older=Get-OwnedDuplicateItemId -ResourceId ([long]$item.resourceId) -NewItemId ([long]$item.id) -Kind 'player'
                if($older -gt 0){$fallbackDups += ,[pscustomobject][ordered]@{itemId=[long]$item.id;duplicateItemId=[long]$older}}
            }
            if($currency -eq 'points'){$script:FifaPoints-=$price}else{$script:Coins-=$price}
            $script:PurchasedItems=@($fallbackItems)
            $script:PurchasedDuplicatePairs=@($fallbackDups)
            Persist-SaveState
            Write-Log ("PACK SAFE FALLBACK v0.14.1: {0} -> {1} valid player cards" -f $pack.name,$fallbackItems.Count)
            return ([ordered]@{
                itemList=@($fallbackItems)
                numberItems=$fallbackItems.Count
                purchasedPackId=[long]$pack.id
                duplicateItemIdList=@($fallbackDups)
            }|ConvertTo-Json -Depth 14 -Compress)
        } catch {
            $script:NextPackItemId=$oldNextItemId
            Write-Log ("PACK FATAL v0.14.1: fallback also failed: {0}" -f $_.Exception.Message)
            return '{"error":"PACK_GENERATION_FAILED","itemList":[],"numberItems":0}'
        }
    }
}

function Move-ItemsDocument([string]$JsonBody){
    $out=@();try{$doc=$JsonBody|ConvertFrom-Json}catch{$doc=$null}
    foreach($row in @($doc.itemData)){if($null -eq $row.id){continue};$id=[int64]$row.id;$pile=([string]$row.pile).ToLowerInvariant();$item=Get-OwnedPlayerByItemId $id;if($null -eq $item){$out += [ordered]@{id=$id;pile=$pile;success=$false;reason='item not found'};continue}
        if($pile -eq 'club'){$script:PurchasedItems=@($script:PurchasedItems|Where-Object{[int64]$_.id -ne $id});$script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object{[int64]$_.itemId -ne $id});$script:TradePileItems=@($script:TradePileItems|Where-Object{[int64]$_.id -ne $id});$alreadyInClub = @($script:ClubExtraItems | Where-Object { [int64]$_.id -eq $id }).Count -gt 0; if(-not $alreadyInClub){$script:ClubExtraItems += $item}}
        elseif($pile -eq 'trade'){$script:PurchasedItems=@($script:PurchasedItems|Where-Object{[int64]$_.id -ne $id});$script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object{[int64]$_.itemId -ne $id});$script:ClubExtraItems=@($script:ClubExtraItems|Where-Object{[int64]$_.id -ne $id});$alreadyInTrade = @($script:TradePileItems | Where-Object { [int64]$_.id -eq $id }).Count -gt 0; if(-not $alreadyInTrade){$script:TradePileItems += $item}}
        else{$out += [ordered]@{id=$id;pile=$pile;success=$false;reason='unsupported pile'};continue};$out += [ordered]@{id=$id;pile=$pile;success=$true;reason=''}
    };Persist-SaveState;return ([ordered]@{itemData=$out}|ConvertTo-Json -Depth 6 -Compress)
}

function Quick-SellDocument([string]$Path){
    $ids=@();if($Path -match '(?:\?|&)itemIds=([^&]+)'){foreach($x in $Matches[1].Split(',')){if($x -match '^\d+$'){$ids += [int64]$x}}};if($Path -match '/item/(\d+)(?:\?|$)'){$ids += [int64]$Matches[1]}
    foreach($id in @($ids|Select-Object -Unique)){$item=Get-OwnedPlayerByItemId $id;if($null -eq $item){continue};$script:Coins += [int64]$item.discardValue;$script:PurchasedItems=@($script:PurchasedItems|Where-Object{[int64]$_.id -ne $id});$script:PurchasedDuplicatePairs=@($script:PurchasedDuplicatePairs|Where-Object{[int64]$_.itemId -ne $id});$script:ClubExtraItems=@($script:ClubExtraItems|Where-Object{[int64]$_.id -ne $id});$script:TradePileItems=@($script:TradePileItems|Where-Object{[int64]$_.id -ne $id});for($i=0;$i -lt $script:SquadOrder.Count;$i++){if([int64]$script:SquadOrder[$i] -eq $id){$script:SquadOrder[$i]=0}}}
    Persist-SaveState;return ('{"totalCredits":'+[int64]$script:Coins+'}')
}

function Save-ClientDataDocument([string]$Bucket,[string]$JsonBody){$key=$Bucket.ToLowerInvariant();$entries=@();try{$doc=$JsonBody|ConvertFrom-Json;foreach($e in @($doc.entries)){if($null -ne $e.key -and $null -ne $e.value){$entries += [ordered]@{key=[int]$e.key;value=[int]$e.value}}}}catch{};$script:ClientDataBuckets[$key]=$entries;Persist-SaveState;return (Get-ClientDataDocument $Bucket)}



# v0.13.2: restored proven RS4 socket runtime accidentally omitted from v0.13.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($BindAddress), $Port)
$listener.Start()
Write-Log ("FUT RS4 server on http://{0}:{1}/" -f $BindAddress, $Port)
if ($script:FullClubCatalog.Count -gt 0) {
    Write-Log ("FULL CLUB v0.14.1: loaded {0} player cards (base={1}, special={2}) from cards_ng_db/WeFUT" -f $script:FullClubCatalog.Count,$script:FullClubStats.baseCards,$script:FullClubStats.specialCards)
} else {
    Write-Log ("FULL CLUB v0.14.1: native catalogue unavailable; using {0}-player fallback" -f $script:SquadPlayers.Count)
}
if ($script:ItemCatalog.Count -gt 0) {
    Write-Log ("ITEM POOL v0.14.1 CONFIRMED: {0} usable native consumable/staff/club cards" -f $script:ItemCatalog.Count)
} else {
    Write-Log 'ITEM POOL v0.14.1 ERROR: native non-player catalogue is empty'
}
Write-Log ("SAVE v0.14.1 CONFIRMED: club={0}; unassigned={1}; trade={2}; coins={3}; db={4}" -f @($script:ClubExtraItems).Count,@($script:PurchasedItems).Count,@($script:TradePileItems).Count,$script:Coins,$SavePath)

$script:DbReady = Test-Database
if ($script:DbReady) {
    Write-Log ("PostgreSQL: connected ({0})" -f $DbConn)
} else {
    Write-Log 'PostgreSQL: unavailable -- static responses (fallback)'
}

# Cap on the request head. A single Read() returns whatever one TCP segment
# carried, which is not necessarily the whole head: a request whose headers span
# two segments used to be truncated mid-line, so the request line could be read
# before the rest arrived and, worse, a short read could leave the path
# incomplete and route the request to the wrong handler (or to the 404 branch).
# The loop below reads until the CRLFCRLF terminator instead. The cap stops a
# client that never sends one from growing the buffer without bound; the
# ReadTimeout stops one that stops sending halfway.
$script:MaxHeadBytes = 16384

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        # Dirtysock sends the request head immediately after connect.  Keep the
        # initial timeout short so a connect-only health probe cannot monopolise
        # this single-threaded listener and make the real FUT request time out in
        # the accept queue.  Once bytes arrive, each subsequent read gets a more
        # generous timeout for a split header.
        $stream.ReadTimeout = 350
        $buffer = New-Object byte[] $script:MaxHeadBytes
        $read = 0
        $headEnd = -1
        $lineEnd = -1
        while ($read -lt $buffer.Length) {
            $got = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($got -le 0) { break }
            $stream.ReadTimeout = 2000
            # Rescan only the tail: the terminator can straddle the boundary
            # between two reads, so start three bytes before the new data.
            $scanFrom = [Math]::Max(0, $read - 3)
            $read += $got
            $received = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            $headEnd = $received.IndexOf("`r`n`r`n", $scanFrom)
            $lineEnd = $received.IndexOf("`r`n")
            if ($lineEnd -lt 0) { $lineEnd = $received.IndexOf("`n") }
            # Every implemented route is selected solely from the request line
            # and ignores the body. ProtoHttp's keep-alive GET can withhold the
            # final blank line while waiting for a response, so waiting for the
            # complete header creates a deadlock. Route once line 1 is complete.
            if ($headEnd -ge 0 -or $lineEnd -ge 0) { break }
        }
        if ($read -le 0) { continue }
        if ($headEnd -lt 0 -and $lineEnd -lt 0) {
            Write-Log ("DROP malformed request: no complete request line within {0} bytes ({1} read)" -f $buffer.Length, $read)
            continue
        }

        # Parse line 1 first. GETs can be answered from it alone, but writes need
        # their JSON payload: chemistry/squad changes live in that body.
        $requestLineBytes = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        $requestLine = ($requestLineBytes -split "`r`n")[0]
        $requestParts = $requestLine -split ' '
        $method = $requestParts[0].ToUpperInvariant()
        $path = $requestParts[1]

        # For POST/PUT/PATCH, finish the header and Content-Length body. Do not do
        # this for GET: this old ProtoHttp can wait for a response before sending
        # the final blank line, which is why the server originally routed on line 1.
        if ($method -in @('POST','PUT','PATCH')) {
            while ($headEnd -lt 0 -and $read -lt $buffer.Length) {
                $stream.ReadTimeout = 2000
                $got = $stream.Read($buffer, $read, $buffer.Length - $read)
                if ($got -le 0) { break }
                $scanFrom = [Math]::Max(0, $read - 3)
                $read += $got
                $received = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                $headEnd = $received.IndexOf("`r`n`r`n", $scanFrom)
            }
            if ($headEnd -ge 0) {
                $headerText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $headEnd)
                $contentLength = 0
                if ($headerText -match '(?im)^Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
                $bodyStart = $headEnd + 4
                $required = $bodyStart + $contentLength
                while ($read -lt $required -and $read -lt $buffer.Length) {
                    $stream.ReadTimeout = 2000
                    $got = $stream.Read($buffer, $read, [Math]::Min($buffer.Length - $read, $required - $read))
                    if ($got -le 0) { break }
                    $read += $got
                }
            }
        }

        $requestLength = if ($headEnd -ge 0) { $headEnd } else { $read }
        $request = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $requestLength)
        foreach ($header in ($request -split "`r`n")) {
            if ($header -match '^(X-UT-|Content-Length|Content-Type|User-Agent|Cookie|Accept)') {
                Write-Log ("REQHDR {0}" -f $header)
            }
        }

        $requestBody = ''
        if ($headEnd -ge 0) {
            $bodyStart = $headEnd + 4
            if ($read -gt $bodyStart) {
                $bodyCount = $read - $bodyStart
                $requestBody = [System.Text.Encoding]::UTF8.GetString($buffer, $bodyStart, $bodyCount).TrimEnd([char]0)
                $requestBodyPreview = $requestBody
                if ($requestBodyPreview.Length -gt 8192) { $requestBodyPreview = $requestBodyPreview.Substring(0, 8192) + '...[truncated]' }
                Write-Log ("REQBODY {0}" -f ($requestBodyPreview -replace "`r|`n", ' '))
            }
        }

        $body = Get-Body $path $method $requestBody
        if ($null -ne $body) {
            $status = '200 OK'
            Write-Log ("200  {0}  -> {1}" -f $requestLine, $body)
        } else {
            $status = '404 Not Found'
            $body = '{}'
            Write-Log ("404  {0}   <-- UNKNOWN ROUTE, to be implemented" -f $requestLine)
            # Header dump: the parsers are picky and the session id travels here.
            foreach ($header in ($request -split "`r`n")) {
                if ($header -match '^(X-UT-|Content-Type|User-Agent|Cookie|Accept)') { Write-Log ("     | {0}" -f $header) }
            }
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $head = "HTTP/1.1 $status`r`nContent-Type: text/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($headBytes, 0, $headBytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        Write-Log ("error: {0}" -f $_.Exception.Message)
    } finally {
        $client.Close()
    }
}
