---
name: lefan-launch-adruns-meta-adsets
description: Launch CAMP ad-agent runs as new (tracked) Meta ad sets under an existing live Meta campaign for a team — register outputs, pre-create ad-set aggregate drafts, publish via motion.net stateless-meta-publish with entityLinking. Handles style filtering, location targeting from Business Info, website vs Instant Form modes, and the CBO/tokenSource/aggregate gotchas that block naive attempts.
version: 1.0.0
---

# Launch CAMP ad runs as Meta ad sets (tracked) under an existing campaign

Reusable runbook to add N CAMP ad-agent runs (`aar_…`) as N new Meta ad sets to an **existing live Meta campaign** for a given team, with each ad set filtered to specific creative styles, tracked in Wonderly (entity-linking), and launched **PAUSED** so the operator sets budget + activates.

Repos: CAMP (F#, `internal-tool-customer-management`) + motion.net (C#, `backend-net`). This flow bypasses the CAMP UI and calls prod directly.

## When to use
- "Launch these ad runs as new ad sets for campaign `mpc_…` / Meta campaign `<id>`."
- One ad set per run; each ad set includes only the operator-named style slugs.
- Location comes from the team's Business Info; budget is set by the operator afterward.

## Inputs to gather from the operator
- **Team id** (`team_…`).
- **Target campaign**: the CAMP/backend aggregate id (`mpc_…`) OR the Meta campaign id. You will resolve both.
- **Ad runs** (`aar_…`) and, per run, the **style slugs** to include.
- **Mode** per ad set: website conversions (default) or Instant Form (needs `existingFormId`).
- Budget: operator sets it themselves later (do not set it).

## Credentials / access (ask the operator; never hardcode; treat as secrets; tell them to ROTATE after)
- `internal-tools` CLI logged in (`internal-tools whoami`) — reads/writes prod CAMP as the user.
- **motion.net admin bearer token** (scheme `AdminBearer`) — for `backend-net.wonderly.com` admin + impersonated endpoints. Store in a gitignored scratchpad file, reference via `$(cat)`, never echo.
- **Prod Postgres WRITE creds** (Citus coordinator, `motion` db) — only for the ad-set-draft INSERT/DELETE. Store as a clean libpq URL (`postgresql://user:pass@host:5431/motion?sslmode=require`) in a scratchpad file.
- `agent-gateway` MCP `database.prod.query_readonly` — for read-only prod inspection (schema, sibling rows, account provisioning).

Use the scratchpad dir for all payloads/creds. Keep the admin token and DB password out of command echo.

---

## Critical design facts (why the naive approach fails — read before doing anything)

1. **Only `stateless-meta-publish` adds ad sets to an existing campaign.** `campaigns/manual/from-agent` and `meta/campaigns/draft` always create a *new* campaign; the CSM `stateless-publish` proxy forces `adOutput` sources (rejects signedUrl). So go **direct to motion.net** `POST /api/admin/v1/stateless-meta-publish`.

2. **Tracking is all-or-nothing with the asset source (validator enforces):**
   - `lifecycle: entityLinking` (tracked in Wonderly) ⇒ **every ad must use `adOutput` source** (`adOutputId`+`adOutputVersion`), which requires registering the media first.
   - `signedUrl` asset source ⇒ **`lifecycle: none`** (Meta-only, NOT in CAMP/Wonderly). Simpler, one call, no registration — use only if the operator is OK with untracked ad sets.
   - You cannot mix. Default to **entityLinking + adOutput** (tracked).

3. **entityLinking needs pre-created `mpa_` ad-set aggregate rows under the SAME campaign as `lifecycle.campaignId`.** `UpsertAdSetAsync` (`MetaAdsResourceAggregateService.cs`) **does not create** ad-set rows (a novel id throws "MetaAdSet not found") and **refuses to re-parent** (draft's `meta_published_campaign_id` must equal `lifecycle.campaignId`, else "belongs to campaign row X"). There is **no API** to add ad-set drafts under an already-published campaign. So you **manually INSERT the `mpa_` draft rows** under the target campaign (see Step 5), then publish.

4. **tokenSource:**
   - Website: `systemUser` works (for a `child-business-manager` account it's the CBM system-user token — check `account_type`).
   - **Instant Form: MUST be `adAccount`** — the validator rejects `systemUser` + Instant Form (leadgen needs a Page token only `adAccount` supplies). Account must have a page token.

5. **CBO / bid strategy conflict (Instant Form under an existing website campaign):** a **lowest-cost CBO** campaign requires **all ad sets to share one `optimization_goal`**. Website = `OFFSITE_CONVERSIONS`; Instant Form `leads` = `LEAD_GENERATION`, `conversionLeads` = `QUALITY_LEAD`. These don't match, so **Instant Form ad sets cannot join a website CBO campaign** — Meta errors ("same optimization for ad delivery selection is required…"). Put Instant Form ad sets in a **separate new campaign**.

6. **Budget:** existing-campaign target carries **no budget** (CBO campaign owns it). Launch `PAUSED`; operator sets daily budget + activates. Website mode requires `metaPixelId`; Instant Form does not.

7. **Locations** serialize as snake_case `MetaCustomLocation`: `{latitude, longitude, radius(int), distance_unit}`.

8. **Signed GCS URLs expire (~1h).** Re-fetch run details right before registering.

9. **`workflowId` is the Temporal idempotency key** — a retried identical request attaches to the in-flight run (no double publish). Use a fresh id per distinct attempt.

10. **GATE each mutation on the previous succeeding.** (A publish fired before its draft rows existed once caused an avoidable failure — Temporal retried and it recovered only because the rows were inserted quickly.)

---

## Procedure

Work in the scratchpad dir. Build every payload as a file; **show the operator each mutating payload/SQL before sending** and get approval.

### Step 1 — Resolve identities
- **customerId** from team: `internal-tools sqlite query customer-management "SELECT CustomerId, TeamId FROM customer_details WHERE TeamId='<team>'"`.
- **motion userId** (for impersonated `/api/v1` calls): `curl -H "Authorization: AdminBearer <tok>" "https://backend-net.wonderly.com/admin/v1/internal/users/by-customer-id?customerId=<cus>"` → `{userId, teamId}`.

### Step 2 — Resolve target campaign state
`internal-tools call customer-management GET "/api/admin/csm/ad-engine/customers/<cus>/meta/campaigns/<mpc>"` →
- `metaCampaignId` (the live Meta id — required for `campaign.target=existing`; if null the campaign isn't on Meta yet).
- `effectiveStatus`, `syncStatus`, existing `adSets[]`.
- Confirm the `id` you'll use as `lifecycle.campaignId` is the aggregate `mpc_…` (its DB `meta_campaigns.id`).

### Step 3 — Meta account config + tokenSource
- `internal-tools call customer-management GET "/api/admin/csm/ad-engine/customers/<cus>/meta/account"` → `metaAdAccountId` (`act_…`), `facebookPageId`, `pixelId`.
- Provisioning via agent-gateway: `SELECT meta_ad_account_id, account_type, status, setup_status, (encrypted_page_access_token IS NOT NULL) has_page_tok FROM motion_net.meta_ad_accounts WHERE meta_ad_account_id='<act_…>' AND deleted_at IS NULL`. `child-business-manager` + website ⇒ `tokenSource: systemUser`. Instant Form ⇒ `tokenSource: adAccount` (needs `has_page_tok=true`).

### Step 4 — Runs → style-filtered outputs, copy, targeting
- **Re-fetch each run fresh** (signed URLs expire): `internal-tools call customer-management GET "/api/customers/<cus>/ad-runs/<aar>"`. Response has `output[]` ({outputId, copyId, type, style, status, url, mimeType, metadata}) and `copy[]` ({copyId, headline, primaryText, cta}).
- Per run, keep outputs whose `style` ∈ requested slugs and `status=="succeeded"`. Report any missing styles.
- Per output capture: `url` (signed), `mimeType`, `metadata.service.destinationPageUrl` (strip any `-old.wonderly.website` → `.wonderly.website` if the operator wants the current site), headline/primaryText via copyId, `style`, service `{name,slug,source,vertical}`.
- **Targeting** from Business Info: `GET "/api/admin/csm/ad-engine/customers/<cus>/business-info"` → `items[0].extractedData.advertisingPreferences.{includedLocations,excludedLocations}`. Map each to `{latitude, longitude, radius:int(round), distance_unit: distanceUnit||"mile"}`. Use `businessInfoId = items[0].id`. (The CAMP UI caps to 10 default locations; direct calls are not capped — confirm with operator how many to use.)

### Step 5 — Register outputs (get adOutputId/version) — motion.net, impersonated
`POST https://backend-net.wonderly.com/api/v1/ad-engine/ad-outputs/manual`
Headers: `Authorization: AdminBearer <tok>`, `x-user-id: <userId>`, `x-team-id: <team>`, `X-Wonderly-Internal-Tool: customer-management`, `X-Wonderly-Initiator-Email: <operator email>`, `Content-Type: application/json`.
Body:
```json
{ "businessInfoId": "<biz_…>",
  "items": [ { "imageUrl": "<signed url — for VIDEO too>", "mimeType": "image/png|video/mp4",
               "creativeMetadata": { /* the run output's metadata object; ensure source.teamId + source.customerId set */ } } ] }
```
Response is AllModels: `ids[]` (adOutputIds, in submission order) + `models.adEngineAdOutputs.<id>.version`. Zip by order; assert every `version` is an int > 0.

### Step 6 — Pre-create `mpa_` draft ad-set rows under the target campaign (DB write)
These rows must exist before publish (fact #3). Mirror a real sibling row exactly.
- Inspect: `information_schema.columns` for `motion_net.meta_ad_sets`; read an existing row under the target campaign (`SELECT … WHERE meta_published_campaign_id='<mpc>'`). Confirm `sync_status='draft'` is the encoding (lowercase) and the campaign row exists (FK).
- Required NOT-NULL/no-default cols: `id, team_id, meta_published_campaign_id, sync_status, daily_budget_cents, created_at`. Leave targeting null (written at publish).
- `id` = `mpa_` + **UUIDv7 hex** (48-bit ms ts, version nibble 7, variant 10, random). Generate one per ad set.
- INSERT (one per ad set), `sync_status='draft'`, `daily_budget_cents=0`, `meta_ad_set_id=NULL`, `created_at=now()`, `updated_at=now()`, `name='<label>'`. Wrap in a transaction with a verify SELECT. Show SQL, get approval, run via `psql "$(cat .pgconn)" -v ON_ERROR_STOP=1 -f insert.sql`.
- **Capture the new `mpa_` ids** — they become each ad set's `key` AND `lifecycle.adSets[].{key, adSetId}`.

### Step 7 — Publish — motion.net admin
`POST https://backend-net.wonderly.com/api/admin/v1/stateless-meta-publish`
Headers: `Authorization: AdminBearer <tok>`, `X-Wonderly-Internal-Tool`, `X-Wonderly-Initiator-Email`, `Content-Type`. (No impersonation headers — `[RequireAdminToken]`; team rides in lifecycle.)
Body (website mode shown; see Instant Form note):
```json
{
  "workflowId": "<unique-single-path-segment>",
  "campaign": {
    "target": { "type": "existing", "metaCampaignId": "<live meta campaign id>" },
    "nameKey": "<label>",
    "metaAdAccountId": "act_…", "facebookPageId": "…", "metaPixelId": "…",
    "tokenSource": "systemUser",
    "launchStatus": "PAUSED",
    "adSets": [
      { "key": "<mpa_ draft id>",
        "target": { "type": "new", "name": "<ad set name>",
                    "targeting": { "minimumAge": 18, "customLocations": [ {snake_case} ], "excludedCustomLocations": [] } },
        "ads": [
          { "key": "<adOutputId>", "headlines": ["…"], "primaryTexts": ["…"],
            "destinationUrl": "https://…",
            "asset": { "assetId": "<adOutputId>", "fileName": "<name>.png|mp4",
                       "source": { "type": "adOutput", "adOutputId": "<adOutputId>", "adOutputVersion": 1 } },
            "style": "<slug>", "service": { "name": null, "slug": null, "source": null, "vertical": null } }
        ] }
    ]
  },
  "lifecycle": { "type": "entityLinking", "teamId": "<team>", "campaignId": "<mpc aggregate id>",
                 "adSets": [ { "key": "<mpa_ id>", "adSetId": "<mpa_ id>" } ] }
}
```
Rules: `campaign.adSets[i].key` == `lifecycle.adSets[i].{key,adSetId}` == the `mpa_` id. Headlines/PrimaryTexts 1–5 each. `destinationUrl` absolute http(s). Response `{workflowId, status:"RUNNING"}`.

### Step 8 — Poll to terminal
`GET .../stateless-meta-publish/<workflowId>` until `status != RUNNING` (background loop; videos are slow). `SUCCEEDED` → ad sets created on Meta (PAUSED) + `mpa_` drafts flipped `draft→synced` under the target campaign. `FAILED` → read `errorMessage`; nothing partial is usually created if it fails on the first ad set (verify), fix, re-fire with a new `workflowId`.

### Step 9 — Report + hand-off
Operator actions: set the campaign daily budget (CBO), flip ad sets `PAUSED→active`, **rotate the DB creds + admin token**.

---

## Instant Form variant
- Each ad set adds `"instantForm": { "performanceGoal": "leads" | "conversionLeads", "existingFormId": "<form id>" }` (only valid on `target:new`).
- `tokenSource: "adAccount"` (mandatory), **omit `metaPixelId`**, form must belong to the campaign's `facebookPageId`.
- `leads`→`LEAD_GENERATION`; `conversionLeads`→`QUALITY_LEAD` (uses a `Schedule` conversion event; no pixel).
- **Cannot share a lowest-cost CBO website campaign** (fact #5) → launch as a **separate new campaign**: `campaign.target = { "type":"new", "dailyBudgetCents": <n> }`, ad set targets `new`, lifecycle `entityLinking` with a **new** `mpc_` aggregate + its own pre-created `mpa_` drafts. (Creating a new tracked campaign aggregate needs a `meta/campaigns/draft` call or an equivalent `mpc_`+`mpa_` insert; mirror Step 6.)

## Failure cleanup
Delete only unpublished drafts, guarded: `DELETE FROM motion_net.meta_ads WHERE meta_ad_set_id IN (<mpa ids>); DELETE FROM motion_net.meta_ad_sets WHERE id IN (<mpa ids>) AND sync_status='draft' AND meta_ad_set_id IS NULL RETURNING id,name;` inside a transaction. Never touch synced/live ad sets.

## Signed-URL-only (untracked) fast path
If the operator does NOT need Wonderly tracking: skip Steps 5–6, use `asset.source = { "type":"signedUrl", "readUrl":"<url>", "objectName":"<gcs path>", "contentType":"image/png|video/mp4" }` and `lifecycle: { "type":"none" }`. One publish call, no DB writes. Ad sets exist on Meta only (invisible to CAMP).

## Key references
- meta_ad_sets required cols: `id, team_id, meta_published_campaign_id(varchar, NOT NULL, = mpc_ id), meta_ad_set_id(null for draft), sync_status('draft'), daily_budget_cents(0), created_at, updated_at, name`.
- Aggregate guard: `MetaAdsResourceAggregateService.UpsertAdSetAsync` (no-create, no-reparent).
- Validator: `StatelessMetaPublishValidator` (entityLinking⇔adOutput, systemUser✗InstantForm, pixel-when-website, keys unique, headlines/primaryTexts 1–5).
- Modes: `StatelessMetaPublishMode` (WebsiteConversions=OFFSITE_CONVERSIONS+pixel; InstantForm=LEAD_GENERATION; InstantFormConversionLeads=QUALITY_LEAD; both InstantForm need page token).
