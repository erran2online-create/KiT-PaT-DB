# KiT-PaT — Lovable Reconstruction Build Spec v1

## Non-negotiable
This is a reconstruction, not a generic social-app template. Do not invent backend tables, winner logic, auth rules or duplicate state. Supabase is authoritative. Build mobile-first React suitable for Capacitor packaging to Android/iOS.

## Experience direction
KiT-PaT must feel alive, celebratory and social — not like a dashboard/SaaS product. Use cinematic AI-era visual language: immersive full-bleed backgrounds, layered depth, tasteful motion, glow/lighting, rich event imagery, animated celebration moments, tactile game interactions and strong typography. Keep text legible, navigation fast and mobile performance disciplined. Motion must support reduced-motion accessibility.

The emotional loop is: Belong → Plan → Gather → Play → Celebrate → Remember → Share → Repeat.

## Roles
Host and Member. Host controls group/event setup, game configuration, ticket distribution, number calling, claim checking and event completion. Members RSVP, play, claim prizes, contribute media and share memories.

## Killer journey to implement first
1. Sign in/onboarding.
2. Create or join Group.
3. Group home: identity, members, next party, history/memories.
4. Create Party: title/theme/date/time/venue/contribution/invite.
5. Member RSVP and attendance state.
6. Game lobby.
7. Tambola: Classic / Quick 10-Minute / Bollywood / Kitty Special.
8. Manual or Automatic mode.
9. Host configures prize quantities (e.g. 4 × Early Five, 8 × Top Line).
10. Host distributes 1–6 tickets/player to all or selected members.
11. Live game via Supabase Realtime.
12. Member marks called numbers; optional auto-highlight preference.
13. Member raises prize claim. Host sees claimant name/prize and taps Check. Backend validates; verified winner is celebrated, rejected/incomplete claim is returned. Never validate winners in frontend.
14. Prize closes only after configured winner slots are filled.
15. End-game winner/leaderboard experience.
16. Camera/gallery photo/video upload via signed Cloudinary flow.
17. Event Memory: winner card, recap/collage, attendance highlights and share action.
18. CTA to create next gathering.

## Tambola screen behaviour
### Variant selection
Show four rich visual cards: Classic, Quick 10-Minute, Bollywood, Kitty Special. Theme changes copy, backgrounds, calls, prize presentation, audio/celebration and share artifacts; fairness/game rules remain server-authoritative.

### Lobby
Show members, ticket-ready state, host controls, Rules in current screen language, play mode and theme identity.

### Manual host
Large tactile 1–90 board. Called numbers clearly disabled/highlighted. Tap an uncalled number to call it. Current number is the visual hero. Show called history, pause, rules, prizes and live claims.

### Automatic host
Current number hero, called history, countdown/cadence, pause/resume. Server state is authoritative; reconnect must restore state.

### Player
Ticket grid optimised for one-hand mobile use. Called/marked visual states must be unmistakable. Prize tray shows remaining slots. Claim is prominent but protected from accidental double submit.

### Claim celebration
Host gets a live claim panel with player name/avatar, prize and ticket. Check invokes backend verification. Verified: cinematic celebration + winner broadcast + remaining slots. Rejected: clear friendly feedback; game continues.

## Five additional game cards
Build discovery/lobby surfaces against backend `game_catalog`/`game_theme_packs`: Rapid Fire Circle, Who Knows Who?, Pass the Parcel Live, Emoji & Bollywood Guess, Spin & Challenge. Do not fake unfinished live engines; mark a game unavailable until its backend journey is wired.

## Backend contracts
Use existing Supabase schema and RPCs. Relevant Tambola RPCs include `host_create_tambola_session`, `host_distribute_tambola_tickets`, `host_start_tambola`, `host_pause_tambola`, `host_call_tambola_number`, `mark_tambola_number`, `claim_tambola_prize`, `host_check_tambola_claim`. Subscribe to authoritative Realtime game state/events. Respect RLS; never use service-role credentials in frontend.

## Media
Request signed upload parameters from `media-signature`; upload directly to Cloudinary; persist only asset metadata/URLs in Supabase. Camera and gallery both required. Never put Cloudinary API secret in client code.

## Quality gates
Every async action: loading, success, failure, retry. Live game: reconnecting/reconnected state. Prevent duplicate submissions. Empty states must be intentional. No dead buttons, placeholder routes or decorative features presented as working. Test host and member as separate sessions.

## Navigation
Keep primary mobile navigation small: Home, Groups, Play, Memories, Profile. Contextual host actions live inside Group/Party/Game rather than bloating global navigation.

## Build order
Build the killer journey end-to-end before secondary screens. First milestone is Group → Party → Members → RSVP → Tambola → Realtime → Tickets → Claims → Host Verification → Winner → Photo/Video → Memory. Do not spend build credits on marketplace, 15 games or admin UI during this milestone.
