# NetPulse

A personal mobile app for checking your internet account status and paying your bill — built from scratch as an independent alternative to a slow, buggy ISP app.

> **Not affiliated with Fiberblaze / Dasca Cable Services.** This project was inspired by real usability issues found in that company's official app, but shares no code, data, or branding with it. All data in this project is either entered by you or fake demo data (see below).

## What it does

- Sign up / sign in, stay signed in across app restarts
- Link an account by account number + registered mobile number
- See plan, balance, due date, and account status at a glance
- Pay a bill through a real payment gateway (PayMongo — cards, GCash, QR Ph), with automatic confirmation once payment completes
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
| Payments | PayMongo (test mode) |
| Auth | JWT, scrypt password hashing |
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
│   ├── main.py                ← the entire API: models, routes, PayMongo integration
│   ├── requirements.txt
│   ├── config.example.json    ← template; copy to config.json and fill in your key
│   ├── .env.example            ← same idea, if you prefer this convention instead
│   └── app.db                  ← created automatically on first run (SQLite)
├── README.md                  ← this file
└── SUMMARY.md                  ← the full story of how this was built
```

## Getting started

### Prerequisites
- Flutter SDK + Android Studio (for the emulator and Android SDK)
- Python 3.10+
- A free [PayMongo](https://dashboard.paymongo.com) account for real test-mode payments (optional — without it, the app still runs using fake seeded data for everything except payments)

### 1. Backend

```
cd "API Server"
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

Optional — enable real payments by creating `config.json` (or `.env`) next to `main.py`:
```json
{ "PAYMONGO_SECRET_KEY": "sk_test_yourkeyhere" }
```

Then run it: press **Run/F5** on `main.py` in VS Code, or `uvicorn main:app --reload`. Either way, visit `http://127.0.0.1:8000/docs` to confirm it's up.

### 2. Flutter app

```
flutter pub get
```

Make sure an Android emulator is running, then press **F5** with `lib/main.dart` open. On a real device instead of the emulator, update `baseUrl` in `api.dart` to your computer's local network IP.

### 3. Try it

Sign up with any email, then link one of the seeded demo accounts:

| Account number | Mobile | Starting balance |
|---|---|---|
| `DEMO-000001` | `5550100001` | ₱999.00 due |
| `DEMO-000002` | `5550100002` | ₱4.00 credit |

## Configuration reference

| Variable | Purpose | Required? |
|---|---|---|
| `PAYMONGO_SECRET_KEY` | Enables real payments via PayMongo | No — falls back to a dev-only simulator if unset |
| `JWT_SECRET` | Signs login tokens | No — auto-generated and saved locally on first run |
| `WEBHOOK_SECRET` | Verifies the dev-mode payment webhook | No — auto-generated the same way |
| `DEV_MODE` | Enables the fake one-tap "payment succeeded" shortcut | No — off by default; set to `1` to turn it back on |

## Known limitations

- Account data is demo/seeded, not connected to a real ISP's systems
- Account linking uses a mobile number as a shared secret, not a real SMS verification code
- Payment confirmation is polling-based rather than via a real webhook, since this hasn't been deployed anywhere with a public URL yet
- Tested on an Android emulator only so far

See `SUMMARY.md` for the full story, including why things were built this way.