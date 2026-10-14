# NetPulse

A personal mobile app for checking your internet account status and paying your bill — built from scratch as an independent alternative to a slow, buggy ISP app.

> **Not affiliated with Fiberblaze / Dasca Cable Services.** This project was inspired by real usability issues found in that company's official app, but shares no code, data, or branding with it. All data in this project is either entered by you or fake demo data (see below).

## What it does

- Sign up / sign in with email and a password, or sign in with Google — and stay signed in across app restarts
- Verify your email or phone number by SMS when you sign up, and confirm payments with a one-time code — each optional, depending on what's configured on the backend
- Link an account by account number + registered mobile number
- See plan, balance, due date, and account status at a glance
- Pay a bill through a real payment gateway (PayMongo — cards, GCash, QR Ph), confirmed automatically by a signature-verified webhook
- Billing history and payment history
- Upgrade your plan; subscribe to optional add-ons (static IP, mesh WiFi, etc.)
- Local notifications a few days before your bill is due
- Report an issue, from inside the app
- Light and dark mode, following your device's system setting

## Tech stack

| | |
|---|---|
| Mobile app | Flutter (Dart), Android |
| Backend | Python, FastAPI, SQLAlchemy, SQLite |
| Payments | PayMongo (test mode), with a signature-verified webhook |
| Auth | JWT, scrypt password hashing, Google Sign-In (`google_sign_in` + `google-auth`) |
| SMS | [textbee](https://textbee.dev) — free, self-hosted via a spare Android phone |
| Email | Gmail SMTP |
| Local notifications | flutter_local_notifications |
| Secure token storage | flutter_secure_storage |

## Project structure

```
mynet/                      ← Flutter project root
├── lib/
│   ├── main.dart            ← screens, navigation, app theme
│   ├── api.dart              ← HTTP client for the backend
│   └── notifications.dart    ← due-date reminder scheduling
├── android/                  ← standard Flutter Android project
├── API Server/                ← the backend, a separate Python project
│   ├── main.py                ← the entire API: models, routes, PayMongo/textbee/SMTP/Google integration
│   ├── requirements.txt
│   ├── config.example.json    ← template; copy to config.json and fill in your keys
│   ├── .env.example            ← same idea, if you prefer this convention instead
│   └── app.db                  ← created automatically on first run (SQLite)
├── README.md                  ← this file
└── SUMMARY.md                  ← the full story of how this was built
```

## Getting started

### Prerequisites
- Flutter SDK + Android Studio (for the emulator, the Android SDK, and `keytool` if you set up Google Sign-In)
- Python 3.10+
- A free [PayMongo](https://dashboard.paymongo.com) account for real test-mode payments (optional — without it, the app still runs using fake seeded data for everything except payments)

### 1. Backend

```
cd "API Server"
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

Optional — enable real payments, SMS/email verification, or Google Sign-In by creating `config.json` (or `.env`) next to `main.py` with any of the keys from Configuration reference below. Everything still runs in a simple, code-free dev mode with none of them set. Simplest example, just real payments:
```json
{ "PAYMONGO_SECRET_KEY": "sk_test_yourkeyhere" }
```

Then run it: press **Run/F5** on `main.py` in VS Code, or `uvicorn main:app --reload`. Either way, visit `http://127.0.0.1:8000/docs` to confirm it's up.

### 2. Flutter app

```
flutter pub get
```

Make sure an Android emulator is running, then press **F5** with `lib/main.dart` open. On a real device instead of the emulator, update `baseUrl` in `api.dart` to your computer's local network IP. To enable Sign in with Google, also set `googleServerClientId` in `main.dart` (see Configuration reference below).

### 3. Try it

Sign up with any email, then link one of the seeded demo accounts:

| Account number | Mobile | Starting balance |
|---|---|---|
| `DEMO-000001` | `5550100001` | ₱999.00 due |
| `DEMO-000002` | `5550100002` | ₱4.00 credit |

## Configuration reference

### Backend (`API Server/.env` or `config.json`)

| Variable | Purpose | Required? |
|---|---|---|
| `PAYMONGO_SECRET_KEY` | Enables real payments via PayMongo | No — falls back to a dev-only simulator if unset |
| `PAYMONGO_WEBHOOK_SECRET` | Verifies that an incoming payment webhook really came from PayMongo (from PayMongo's dashboard, once a webhook is registered) | No — needed only once you've set up a real webhook |
| `TEXTBEE_API_KEY` | Sends SMS verification codes (account linking, payments) via [textbee](https://textbee.dev), using a spare Android phone as a free SMS gateway | No — without it, account linking falls back to a phone-number match with no code |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Sends email verification codes via Gmail SMTP (use a Gmail [App Password](https://myaccount.google.com/apppasswords), not your real password) | No — without them, sign-up/login skips email verification |
| `SMTP_HOST` / `SMTP_PORT` | SMTP server details | No — default to Gmail's (`smtp.gmail.com`, `587`) |
| `GOOGLE_CLIENT_ID` | The Web OAuth client ID (from Google Cloud Console) that enables "Sign in with Google" | No — the Google button shows an error if unset |
| `JWT_SECRET` | Signs login tokens | No — auto-generated and saved locally on first run |
| `WEBHOOK_SECRET` | Verifies the *dev-mode* payment simulator's callback — unrelated to `PAYMONGO_WEBHOOK_SECRET` above | No — auto-generated the same way |
| `DEV_MODE` | Enables the fake one-tap "payment succeeded" shortcut | No — off by default; set to `1` to turn it back on |

### Flutter app (constants, not environment variables)

| Constant | File | Purpose |
|---|---|---|
| `baseUrl` | `lib/api.dart` | Your backend's address — `10.0.2.2` for the Android emulator, your PC's LAN IP for a real device |
| `googleServerClientId` | `lib/main.dart` | Same value as `GOOGLE_CLIENT_ID` above — the two must match exactly |
| `devSimulatePayments` | `lib/main.dart` | Set to `false` once `PAYMONGO_SECRET_KEY` is configured for real payments |

## Known limitations

- Account data is demo/seeded, not connected to a real ISP's systems
- The payment webhook needs a running [Cloudflare Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) pointed at the backend — free and needs no account, but its public URL changes every time it restarts, so it has to be re-entered in PayMongo's dashboard after each restart. Polling still works as a fallback regardless.
- Sign in with Google only works for Google accounts added as test users in Google Cloud Console, until the OAuth consent screen is published beyond "Testing" status
- No release build yet — everything has run through Flutter's debug mode so far

See `SUMMARY.md` for the full story, including why things were built this way.