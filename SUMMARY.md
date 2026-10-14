# NetPulse — Project Summary

## Origin

This started from frustration with a real ISP's mobile app (Fiberblaze, a Cavite-based provider) — specifically, a billing screen that displayed a credit balance as a negative "amount due," among other rough edges. Rather than keep using it, the goal became: build a working, better alternative from scratch. Since there's no public API for a regional ISP this size, the app runs on an independent backend with realistic seeded demo data, built to be swapped for a real data source later if that ever becomes possible.

## Goals

- A real, working mobile billing app — not a mockup — with its own backend
- Real payment processing, not just a UI that pretends to charge a card
- Built and understood well enough to maintain and extend independently
- Its own identity: own name, own branding, no reuse of Fiberblaze's name or logo

## Architecture

Two independent pieces talking over HTTP:

- **Backend** (`API Server/main.py`) — a single-file FastAPI app. SQLite for storage, JWT for auth, PayMongo for payments, plus integrations with textbee (SMS), Gmail SMTP (email), and Google OAuth (sign-in) — each one entirely optional, active only once its own config value is set. Deliberately simple: no ORM migrations, no background job queue, no microservices — a personal project doesn't need that complexity, and every added layer is something to set up and debug on a Windows dev machine.
- **App** (`lib/`) — Flutter, Android-first. Talks to the backend over plain HTTP — `10.0.2.2` to reach the host machine from the emulator, or the PC's LAN IP for a real device.

## How it was built, in order

### 1. Core prototype
Login, account linking, home/bills/plans/account screens, backed by a FastAPI server with seeded demo accounts (`DEMO-000001` owing money, `DEMO-000002` with a credit — deliberately chosen to exercise both the "amount due" and "credit" display paths, since that distinction was the original bug that started this whole project). A full Flutter + Android dev environment was set up from zero along the way: Flutter SDK, Android Studio, the Android SDK, an emulator — each with its own setup hiccup resolved in turn (missing Android SDK, missing command-line tools, PowerShell's script-execution policy blocking the virtual environment, an NDK version Gradle couldn't auto-install).

### 2. Feature completeness ("More features")
With the prototype running, four features were added to round out the basics:
- **Staying signed in** — the login token is now saved via `flutter_secure_storage` and checked on launch, instead of requiring login every time the app opens. The backend's token lifetime was also extended from 12 hours to 30 days to match.
- **Due-date reminders** — local notifications (not Firebase push, which would need its own backend infrastructure this project doesn't need) scheduled a few days before a bill is due.
- **Report an Issue** — a simple categorized report form, stored server-side.
- **Add-Ons** — a small catalog (static IP, mesh WiFi, premium support, an extra device slot) a subscriber can toggle, affecting their balance immediately rather than waiting for a billing cycle that doesn't really exist yet in a demo system.

### 3. Real payments
The biggest single piece of work. PayMongo was chosen as the gateway — it's the standard choice for a Philippines-based app, and test-mode keys are available immediately on sign-up, no waiting for approval. The flow: the backend creates a real PayMongo Checkout Session, the app opens it in the device browser, and since there's no deep link configured back into the app yet, completion is detected by polling the backend every few seconds plus checking immediately whenever the app returns to the foreground — with a manual "I've Completed Payment" button always available as a fallback. A real webhook (the more "correct" way to confirm payment) was deliberately deferred, since it needs a publicly reachable server, which this project doesn't have yet.

Along the way, this surfaced PayMongo's own API inconsistency: checkout sessions are *created* via their newer `v2` endpoint, but *retrieved* via the older `v1` endpoint — not documented together anywhere obvious, and only found by pulling up PayMongo's reference pages directly after a live test returned a 404. Payment failure detection was added after the fact too: PayMongo payments only ever have three states (`paid`, `pending`, `failed`), so the app now distinguishes "still waiting" from "that attempt failed, try again" instead of treating both the same.

### 4. Security, branding, and polish
Once the feature set was complete, this pass covered what was left from the start:
- **Security**: secrets (`JWT_SECRET`, `WEBHOOK_SECRET`) were hardcoded placeholder strings during development — now randomly generated on first run and persisted locally. The dev-only one-tap payment simulator used during early testing now defaults to *off* rather than on. Login and account-linking attempts are rate-limited, since account number + phone number is a fairly guessable credential pair (a proper SMS verification code is the real fix here, noted as future work, not yet built).
- **Branding**: the project carried a placeholder name ("MyNet") through most of development. It's now **NetPulse**, with a custom icon (a simple teal signal/pulse mark, generated and exported at every Android icon size).
- **Polish**: dark mode (follows the system setting), and client-side form validation on login and account-linking, so a typo or empty field is caught instantly instead of only after a round trip to the server.

### 5. Developer-experience fixes
A few issues surfaced purely from how the project is run day to day on Windows, worth recording since they could easily resurface:
- `config.json` and `.env` were both added as ways to store the PayMongo key locally instead of retyping a PowerShell environment variable every session.
- A real bug was found and fixed where `.env`, `config.json`, and the SQLite database all used paths relative to the *current working directory* — meaning running the server by typing `uvicorn` by hand versus clicking VS Code's Run/F5 button could silently read or write two different files depending on which one happened to be the working directory at the time. All three are now anchored to the script's own folder, regardless of how it's launched.
- A reminder worth keeping: the API and the Flutter app run from the same VS Code window, so anything that reloads that window (fixing a stuck extension, a VS Code update) silently stops the server without stopping the app.

### 6. Verification, everywhere it matters
The rate-limiting gap flagged back in section 4 — account number + phone number being a guessable credential pair with no real code behind it — finally got its proper fix, plus two more verification channels built alongside it:
- **SMS OTP for account linking** — the real code sent by text, not just a phone-number match. Getting here took a few dead ends: Twilio was the first choice, but its free trial isn't available to Philippines-based accounts; Semaphore (a Philippines-focused SMS API) worked technically, but required buying credits up front, which wasn't in the budget for a personal project. The solution that actually stuck was self-hosted: [textbee](https://textbee.dev), a free, open-source service that turns a spare Android phone into an SMS gateway — install their app on an old phone with a SIM in it, generate an API key, and the backend sends real texts through that phone instead of paying a provider per message.
- **Email verification** — a second, independent channel alongside SMS, using Gmail SMTP and a Gmail "App Password" (not the real account password). No signup or approval wait, unlike the SMS providers, which made it a quick addition once textbee was already working.
- **A verification code before payments** — a code (sent by whichever of SMS or email is configured) now has to be confirmed before a payment is allowed to proceed, not just at login or account-linking.

All three stay true to the project's existing convention: each is controlled by whether its own config value is set, so the app keeps working in a simple, code-free dev mode with nothing configured at all.

### 7. Polish pass on the verification screens
A short, focused UI pass over the three new code-entry flows (account linking, email verification, payment confirmation) once they were functionally done — smoothing transitions and tightening up the layout so entering a code feels like one consistent pattern across the app rather than three separately-bolted-on features.

### 8. A real PayMongo webhook, finally
The item deliberately deferred back in section 3. A real webhook endpoint now verifies PayMongo's signature on every incoming call — HMAC-SHA256 over the request body and timestamp, checked against the `Paymongo-Signature` header, using `PAYMONGO_WEBHOOK_SECRET` from PayMongo's own dashboard (a completely different value from the pre-existing `WEBHOOK_SECRET`, which is only for the local dev-mode simulator).

The remaining obstacle was the same one that deferred this in the first place: a webhook needs a public URL, and paid hosting wasn't an option ("i don't have the budget right now"). The fix was Cloudflare's free Quick Tunnel (`cloudflared tunnel --url http://localhost:8000`) — no account, no signup, and it punches a public HTTPS URL straight through to the API still running locally on the dev machine. The trade-off: that URL changes every time the tunnel restarts, so it has to be manually re-pasted into PayMongo's dashboard after every restart. Polling remains as a fallback, so a stale webhook URL doesn't break payments — it just means confirmation comes from polling instead of instantly from the webhook until the URL is updated.

### 9. The first real-device run
Everything had been emulator-only up to this point. Getting a real Android phone running surfaced a cluster of device- and OS-level snags, each fairly minor alone but easy to get stuck on in combination: a USB cable that turned out to be charge-only, a missing Windows USB driver, and two separate, easy-to-conflate Android developer-option toggles ("Install via USB" and "USB debugging") that both have to be on. On the networking side, the API had to bind to `0.0.0.0` instead of `127.0.0.1` to be reachable from another device at all, and `api.dart`'s `baseUrl` had to point at the PC's real LAN IP instead of the emulator-only `10.0.2.2`.

Once running, a full real-money-free test — login, linking, paying — worked end to end on the actual phone, including a real webhook round-trip. (One payment briefly left the app on a black screen after returning from the browser; it didn't reproduce on later runs, so it's noted here rather than left undocumented, in case it resurfaces.)

### 10. Sign in with Google (in progress)
Directly inspired by Fiberblaze's own login screen, which offers Facebook, Google, and Apple social sign-in. Scoped down to Google only: Apple Sign-In requires a $99/year Apple Developer account, which doesn't make sense to pay for an Android-only app with no iOS version, and Google alone covers the common case.

No Firebase involved — the backend verifies Google's ID token directly using Google's own `google-auth` Python library, checking it against a Web OAuth client ID from a plain Google Cloud Console project. A Google sign-in automatically links to an existing email/password account that shares the same email address, rather than creating a duplicate. As of this update: both sides of the code are written and delivered; what's left is the Google Cloud Console setup (OAuth consent screen, a Web client ID and an Android client ID keyed to the app's package name and debug SHA-1 fingerprint) and a confirming end-to-end test.

## Notable decisions, and why

- **Demo data over scraping** — the alternative to seeded demo data was reverse-engineering Fiberblaze's private app or using real customer logins without authorization. That was ruled out from the very first conversation about this project, on both legal and ethical grounds, and that didn't change just because the rest of the app got more sophisticated. The honest path — asking Fiberblaze directly for API access — was drafted as an outreach message but intentionally left unsent while other work continued.
- **Polling, backed up later by a real webhook** — webhooks are the "correct" way to confirm a payment, but they need a public URL. Polling plus an app-resume check got real functionality working first without needing to deploy anything; a real signature-verified webhook was added later once a free way to get a public URL (Cloudflare's Quick Tunnel) was found.
- **A single-file backend** — everything lives in one `main.py`. For a project at this scale, splitting into multiple modules would add navigation overhead without adding clarity.
- **A free, self-hosted SMS gateway over a paid API** — Twilio and Semaphore were both tried first; a free trial restriction (Twilio) and a budget constraint (Semaphore requiring purchased credits) ruled each out in turn. textbee — a spare Android phone acting as the gateway — gave working SMS verification with no ongoing cost.
- **A free tunnel over paid hosting, for the webhook** — the same budget constraint applied here. Cloudflare's Quick Tunnel makes the webhook genuinely real without deploying anywhere, at the cost of a URL that has to be re-pointed by hand after every restart.
- **Google only, not Google + Facebook + Apple** — narrowed down from Fiberblaze's three-button reference screenshot by cost and platform fit: Apple's $99/year developer fee isn't justified for an app with no iOS build.

## Current status

Feature-complete and then some. Real payments work end to end, confirmed by both polling and a real, signature-verified PayMongo webhook (reachable through a free Cloudflare tunnel rather than paid hosting). Account linking, sign-up/login, and payments can each require a one-time verification code — by SMS (through a self-hosted free gateway), by email, or both, depending on what's configured — with no cost either way. Successfully tested end to end on a real Android device, not just the emulator. Sign in with Google is implemented on both the backend and the app and is currently being wired up in Google Cloud Console, with a confirming test still to come.

## Open items

- **Real Fiberblaze account data** — on hold by choice, pending a response to outreach that hasn't been sent yet
- **Sign in with Google** — code is done; Google Cloud Console setup (OAuth consent screen, Web and Android client IDs) and an end-to-end test are in progress
- **A stable webhook URL** — today's Cloudflare Quick Tunnel is free and reliable while it's running, but its URL changes on every restart and has to be re-entered in PayMongo's dashboard by hand each time; worth revisiting if the API ever needs to stay reachable unattended for longer stretches
- **A release build** — everything so far has run in Flutter's debug mode (via `flutter run` / VS Code's F5); signing and testing an actual release build is still ahead