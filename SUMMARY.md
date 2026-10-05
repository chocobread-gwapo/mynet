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

- **Backend** (`API Server/main.py`) — a single-file FastAPI app. SQLite for storage, JWT for auth, PayMongo for payments. Deliberately simple: no ORM migrations, no background job queue, no microservices — a personal project doesn't need that complexity, and every added layer is something to set up and debug on a Windows dev machine.
- **App** (`lib/`) — Flutter, Android-first. Talks to the backend over plain HTTP in development (`10.0.2.2` to reach the host machine from the emulator).

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

## Notable decisions, and why

- **Demo data over scraping** — the alternative to seeded demo data was reverse-engineering Fiberblaze's private app or using real customer logins without authorization. That was ruled out from the very first conversation about this project, on both legal and ethical grounds, and that didn't change just because the rest of the app got more sophisticated. The honest path — asking Fiberblaze directly for API access — was drafted as an outreach message but intentionally left unsent while other work continued.
- **Polling over webhooks (for now)** — webhooks are the "correct" way to confirm a payment, but they need a public URL. Polling plus an app-resume check gets real functionality today without needing to deploy anything.
- **A single-file backend** — everything lives in one `main.py`. For a project at this scale, splitting into multiple modules would add navigation overhead without adding clarity.

## Current status

Feature-complete against the original plan. Real payments work end to end, including failure handling. Tested on an Android emulator throughout; not yet installed on a real device or published anywhere.

## Open items

- **Real Fiberblaze account data** — on hold by choice, pending a response to outreach that hasn't been sent yet
- **SMS OTP for account linking** — scoped but not started; roughly the same size of effort as the PayMongo integration was, since it needs its own external SMS provider
- **Real PayMongo webhooks** — straightforward once this has a public URL to deploy to
- **A real device, and eventually a release build** — everything so far has been emulator-only