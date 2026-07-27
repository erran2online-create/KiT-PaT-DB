# KiT-PaT Frontend / Lovable Contract

Frontend must consume the backend; it must not invent duplicate game or security logic.

## Primary journey
Sign in → create/join group → create party → RSVP → start live game → celebrate winner → upload photos/video → generate/share memory → create next party.

## Tambola screens
1. Variant: Classic / Quick 10-Minute / Bollywood / Kitty Special.
2. Play mode: Manual / Automatic.
3. Prize setup: every pattern has editable winner quantity (`4 × Early Five`, etc.).
4. Ticket distribution: all members or selected members; 1–6 tickets/player.
5. Lobby: joined players + tickets-ready state + localised Rules button.
6. Live host: 1–90 board in Manual; current number, called history, pause/resume, auto cadence in Automatic.
7. Live player: ticket(s), manual mark or auto-highlight preference, open prize claims.
8. Claim moment: pending/verified/rejected feedback; winner broadcast; prize slot count and closed state.
9. Finish: winners + recap + memory/share output.

Never determine a winner in frontend code. Backend state is authoritative.

## Additional games
Expose five game cards backed by `game_catalog`: Rapid Fire Circle, Who Knows Who?, Pass the Parcel Live, Emoji & Bollywood Guess, Spin & Challenge. Theme selection is shown before lobby and rules are displayed in the active UI language.

## Media
Camera/gallery → request `media-signature` → direct signed Cloudinary upload → save returned asset metadata in `media`. Never expose Cloudinary API secret in frontend.

## Analytics
Send PostHog events using names in `analytics_event_catalog`. Never include OTP, secrets, full payment credentials or unnecessary PII.

## Error UX
Every network action needs loading, retry, offline/error copy and idempotent behaviour where applicable. Live games must show reconnecting/reconnected state instead of silently diverging.
