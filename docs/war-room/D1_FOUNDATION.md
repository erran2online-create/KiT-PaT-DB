# D1 Foundation — Launch War Room

## Rules
- A feature is not Built until UI + DB + backend + end-to-end journey are working and tested.
- Every production backend change is mirrored here by migration/function name and Git commit where possible.
- Themes are a first-class moat: game rules stay reliable while themes change language, prompts, visuals, calls, rewards and share outputs.

## Ledger
| Area | Task | Production reference | Git status |
|---|---|---|---|
| D1-A | Harden sensitive public functions | `harden_public_functions_phase1` | documented |
| D1-A/C | Attendance + game RLS | `game_engine_rls_and_attendance` | documented |
| D1-A | Secure AI Gateway | `ai-gateway` v3 | documented |
| D1-A/B | Secure Razorpay | `razorpay-payment` v3 | documented |
| D1-C | Game Engine v1 schema | `create_game_engine_v1` | documented |
| D1-C | Tambola core RPCs | `tambola_engine_core_v1` | documented |
| D1-C | Ticket distribution + claims | `tambola_ticket_distribution_and_claims_v1` | documented |
| D1-C | Fix valid 3x9/15-number generator | `fix_tambola_grid_generator_v1` | documented |

## Tambola variants
All variants use the same authoritative engine: tickets, manual/automatic draw, configurable prize slot counts, claims, verification, realtime state, winners and memory events.

- `classic` — traditional 1–90 Tambola.
- `quick_10` — fast preset, shorter cadence and compact default prize set; host may customise.
- `bollywood` — same fair number engine with Bollywood calls, visual/audio copy, prize naming and share theme.
- `kitty_special` — same fair engine with kitty-party calls, host personality, social prize naming and share theme.

## Five additional launch games
Game Engine should support at least five themed games beyond Tambola:
1. **Rapid Fire Circle** — timed prompts; themes: Bollywood, Kitty Gossip, Moms, Apartment, Women in Business, Festival.
2. **Who Knows Who?** — group-memory quiz about members; consent-safe prompts and opt-out; themes adapt to group type.
3. **Pass the Parcel Live** — server timer/random stop + challenge card; themed challenge decks.
4. **Emoji / Bollywood Guess** — timed clue rounds, individual/team scoring; theme packs.
5. **Spin & Dare / Challenge Wheel** — server-selected challenge with family-safe themed decks, skip rules and scoring.

## Remaining D1
### D1-A Security foundation
- Secure OTP architecture and abuse controls.
- Fix unsafe anonymous comment insert.
- Finish RLS/database permission audit.
- Review JWT strategy for public webhook/auth functions.

### D1-B Core data model
- Stabilise User → Group → Member → Event → RSVP → Attendance → Payment.
- Add constraints/indexes/idempotency where required.

### D1-C Game Engine
- Variant presets/localised rule content.
- Generic rounds/actions/scores/timers for 5 additional games.
- Realtime publication/subscriptions contract.
- End-game/winner/memory events.

### D1-D Media
- Cloudinary asset model, signed upload contract, transformations, moderation/status metadata and memory/share outputs.

### D1-E Observability
- Sentry integration contract.
- PostHog event taxonomy.
- Backend audit/event tracking.

### D1-F Frontend reconstruction
- Frontend API contracts and Lovable implementation spec.
- Consumer app repository remains separate from this backend repository.
