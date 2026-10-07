"""Starter billing API for an internet-subscription app (FastAPI + SQLite).

Run:  uvicorn main:app --reload      (or just press Run/F5 on this file in VS Code)
Docs / playground:  http://127.0.0.1:8000/docs

Money is stored as whole minor units (centavos), so there are no floating-point errors.
Balance > 0 means the customer owes money; balance < 0 means they have credit.
"""
import hashlib
import hmac
import json
import os
import secrets
import time
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import httpx
import jwt
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sqlalchemy import ForeignKey, String, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

# Anchored to this file's own folder, not the current working directory — otherwise running via
# `uvicorn` after cd-ing into this folder vs. via VS Code's Run/F5 button can silently resolve
# .env, config.json, and the database to two different places depending on how the process starts.
_BASE_DIR = Path(__file__).resolve().parent

load_dotenv(_BASE_DIR / ".env")  # reads .env into the environment, if the file exists


def _load_config() -> dict:
    """Reads config.json next to this script, if it exists. Lets you keep values like your
    PayMongo key persisted locally instead of retyping $env:... every time you open a new terminal."""
    path = _BASE_DIR / "config.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


_config = _load_config()


def config_value(name: str, default: str = "") -> str:
    """Checks the environment first (so a one-off $env:... override still wins), then config.json,
    then falls back to default."""
    return os.getenv(name) or _config.get(name, default)


def _get_or_create_secret(env_name: str, filename: str) -> str:
    """Uses an env var if one is set. Otherwise generates a random secret the first time this runs
    and reuses it from a local file after that, so a server restart doesn't log everyone out. Never
    hardcode a real secret in source — anyone reading the code (or a public repo) could forge tokens."""
    value = os.getenv(env_name)
    if value:
        return value
    path = _BASE_DIR / filename  # next to main.py, not the current working directory
    if path.exists():
        return path.read_text().strip()
    value = secrets.token_hex(32)
    path.write_text(value)
    return value


JWT_SECRET = _get_or_create_secret("JWT_SECRET", ".jwt_secret")
WEBHOOK_SECRET = _get_or_create_secret("WEBHOOK_SECRET", ".webhook_secret")
CURRENCY = "₱"

# Leave PAYMONGO_SECRET_KEY unset to keep using the dev-mode payment simulator below.
# Set it to your real sk_test_... key (Dashboard > Developers > API Keys) to take real test-mode payments.
PAYMONGO_SECRET_KEY = config_value("PAYMONGO_SECRET_KEY")
PAYMONGO_BASE = "https://api.paymongo.com/v2"

# Leave TEXTBEE_API_KEY unset to keep linking accounts with just a phone-number match (today's behavior,
# no SMS code). Set it to require an SMS code too, sent through your own Android phone acting as a free
# SMS gateway instead of a paid provider — sign up at textbee.dev, install their app on a spare phone,
# then generate an API key on the dashboard.
TEXTBEE_API_KEY = config_value("TEXTBEE_API_KEY")
TEXTBEE_SEND_URL = "https://api.textbee.dev/api/v1/gateway/send-sms"
OTP_TTL_SECONDS = 600  # textbee doesn't track an expiry itself, so this server enforces its own (10 min)

engine = create_engine(f"sqlite:///{(_BASE_DIR / 'app.db').as_posix()}", connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(engine, expire_on_commit=False)


# ---------- database models ----------
class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String, unique=True)
    password_hash: Mapped[str]


class Plan(Base):
    __tablename__ = "plans"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str]
    speed_mbps: Mapped[int]
    monthly_fee: Mapped[int]


class Account(Base):
    __tablename__ = "accounts"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_no: Mapped[str] = mapped_column(String, unique=True)
    holder_name: Mapped[str]
    mobile: Mapped[str]
    service_address: Mapped[str]
    status: Mapped[str] = mapped_column(default="ACTIVE")  # ACTIVE | SUSPENDED
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"))
    balance: Mapped[int] = mapped_column(default=0)
    due_date: Mapped[date]


class Link(Base):  # which user may see which account
    __tablename__ = "links"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"), primary_key=True)


class Bill(Base):
    __tablename__ = "bills"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    statement_date: Mapped[date]
    period_start: Mapped[date]
    period_end: Mapped[date]
    previous_balance: Mapped[int]
    charges: Mapped[int]


class Payment(Base):
    __tablename__ = "payments"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    amount: Mapped[int]
    status: Mapped[str] = mapped_column(default="PENDING")  # PENDING | PAID
    gateway_session_id: Mapped[str | None] = mapped_column(default=None)  # PayMongo checkout session id, if real
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))
    paid_at: Mapped[datetime | None] = mapped_column(default=None)


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    title: Mapped[str]
    body: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))


class Issue(Base):
    __tablename__ = "issues"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    category: Mapped[str]
    message: Mapped[str]
    status: Mapped[str] = mapped_column(default="OPEN")  # OPEN | RESOLVED
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))


class AddOn(Base):
    __tablename__ = "addons"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str]
    description: Mapped[str]
    monthly_fee: Mapped[int]


class AccountAddOn(Base):  # which add-ons are currently active on which account
    __tablename__ = "account_addons"
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"), primary_key=True)
    addon_id: Mapped[int] = mapped_column(ForeignKey("addons.id"), primary_key=True)


_rate_limit_attempts: dict[str, list[float]] = defaultdict(list)


def rate_limit(key: str, max_attempts: int = 5, window_seconds: int = 60) -> None:
    """Simple in-memory rate limit, e.g. 5 tries per key per minute. Resets on server restart and
    is per-process, not shared across multiple server instances — fine for a personal project, but
    swap in something like Redis-backed rate limiting before running this at real scale."""
    now = time.time()
    attempts = [t for t in _rate_limit_attempts[key] if now - t < window_seconds]
    if len(attempts) >= max_attempts:
        raise HTTPException(429, "Too many attempts. Please wait a bit and try again.")
    attempts.append(now)
    _rate_limit_attempts[key] = attempts


def seed() -> None:
    """Create tables and two fake demo accounts (no real customer data)."""
    Base.metadata.create_all(engine)
    with SessionLocal() as db:
        if not db.scalar(select(AddOn)):  # separate check: added after Plan seeding already existed for some installs
            db.add_all([
                AddOn(name="Static IP", description="A fixed public IP address for your connection", monthly_fee=19900),
                AddOn(name="WiFi Mesh Extender", description="Extra access point to cover more of your home", monthly_fee=29900),
                AddOn(name="Premium Support", description="Priority phone support, no hold queue", monthly_fee=14900),
                AddOn(name="Extra Device Slot", description="Register one more device on your plan", monthly_fee=9900),
            ])
            db.commit()
        if db.scalar(select(Plan)):
            return
        starter, boost, turbo = (
            Plan(name=n, speed_mbps=s, monthly_fee=f)
            for n, s, f in [("STARTER", 50, 79900), ("BOOST", 100, 99900), ("TURBO", 300, 149900)]
        )
        db.add_all([starter, boost, turbo])
        db.flush()
        today = date.today()
        demo = [
            ("DEMO-000001", "DEMO, JUAN D.", "09913187942", boost, 99900),  # owes one month; real number, for OTP testing
            ("DEMO-000002", "DEMO, MARIA S.", "5550100002", starter, -400),  # has a small credit
        ]
        for no, name, mobile, plan, balance in demo:
            acct = Account(account_no=no, holder_name=name, mobile=mobile, service_address="1 Sample Street",
                           plan_id=plan.id, balance=balance, due_date=today + timedelta(days=7))
            db.add(acct)
            db.flush()
            for m in (3, 2, 1):
                end = today - timedelta(days=30 * (m - 1))
                db.add(Bill(account_id=acct.id, statement_date=end, period_start=end - timedelta(days=29),
                            period_end=end, previous_balance=0, charges=plan.monthly_fee))
        db.commit()


@asynccontextmanager
async def lifespan(_: FastAPI):
    seed()
    yield


app = FastAPI(title="Internet Billing API (starter)", lifespan=lifespan)


# ---------- auth helpers ----------
def get_db():
    with SessionLocal() as db:
        yield db


def hash_pw(pw: str) -> str:
    salt = os.urandom(16)
    return salt.hex() + ":" + hashlib.scrypt(pw.encode(), salt=salt, n=2**14, r=8, p=1).hex()


def check_pw(pw: str, stored: str) -> bool:
    salt_hex, digest_hex = stored.split(":")
    digest = hashlib.scrypt(pw.encode(), salt=bytes.fromhex(salt_hex), n=2**14, r=8, p=1).hex()
    return hmac.compare_digest(digest, digest_hex)


def make_token(user_id: int) -> str:
    exp = datetime.now(timezone.utc) + timedelta(days=30)  # was 12 hours; mobile apps expect to stay signed in
    return jwt.encode({"sub": str(user_id), "exp": exp}, JWT_SECRET, algorithm="HS256")


bearer = HTTPBearer()


def current_user(creds: HTTPAuthorizationCredentials = Depends(bearer), db: Session = Depends(get_db)) -> User:
    try:
        user_id = int(jwt.decode(creds.credentials, JWT_SECRET, algorithms=["HS256"])["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(401, "Unknown user")
    return user


def my_account(account_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)) -> Account:
    acct = db.get(Account, account_id)
    if not acct or not db.get(Link, (user.id, account_id)):
        raise HTTPException(404, "Account not found")  # same answer whether it exists or not
    return acct


# ---------- response helpers ----------
def money(balance: int) -> dict:
    """Never show a negative 'amount due': credit is reported separately."""
    return {"balance": balance, "amount_due": max(balance, 0), "credit": max(-balance, 0)}


def account_view(a: Account, db: Session) -> dict:
    plan = db.get(Plan, a.plan_id)
    return {
        "id": a.id, "account_no": a.account_no, "holder_name": a.holder_name, "status": a.status,
        "service_address": a.service_address, "due_date": a.due_date.isoformat(),
        "plan": {"id": plan.id, "name": plan.name, "speed_mbps": plan.speed_mbps, "monthly_fee": plan.monthly_fee},
        **money(a.balance),
    }


def bill_view(b: Bill) -> dict:
    return {
        "id": b.id, "statement_date": b.statement_date.isoformat(), "period_start": b.period_start.isoformat(),
        "period_end": b.period_end.isoformat(), "previous_balance": b.previous_balance, "charges": b.charges,
        "total": b.previous_balance + b.charges,
    }


# ---------- auth ----------
class Credentials(BaseModel):
    email: str
    password: str


@app.post("/api/v1/auth/register", status_code=201)
def register(body: Credentials, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    if "@" not in email or len(body.password) < 8:
        raise HTTPException(422, "Enter a valid email and a password of at least 8 characters")
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, "Email already registered")
    user = User(email=email, password_hash=hash_pw(body.password))
    db.add(user)
    db.commit()
    return {"token": make_token(user.id)}


@app.post("/api/v1/auth/login")
def login(body: Credentials, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"login:{email}")
    user = db.scalar(select(User).where(User.email == email))
    if not user or not check_pw(body.password, user.password_hash):
        raise HTTPException(401, "Wrong email or password")
    return {"token": make_token(user.id)}


# ---------- accounts ----------
class LinkBody(BaseModel):
    account_no: str
    mobile: str  # must match the number on file; see /accounts/link/confirm for the SMS code step


class LinkConfirmBody(BaseModel):
    account_no: str
    mobile: str
    code: str


# textbee is a plain "send this text" API — no OTP concept of its own, so this server generates the code
# itself (unlike Semaphore, which generated one for us) and stores it with its own expiry, keyed by
# account_no. In-memory like _rate_limit_attempts above: fine for a personal project, lost on restart,
# not shared across multiple server instances.
_pending_otps: dict[str, tuple[str, float]] = {}


def _to_e164(mobile: str) -> str:
    """PH-only: turns a local 09XXXXXXXXX number into E.164 (+63XXXXXXXXXX), which is the format
    textbee's own examples use. Left as-is if it doesn't look like that shape (e.g. already has a +
    prefix) — this just lets demo/testing numbers still be typed the way people normally write them."""
    digits = mobile.strip()
    if digits.startswith("0") and len(digits) == 11 and digits.isdigit():
        return "+63" + digits[1:]
    return digits


async def _textbee_send_code(account_no: str, mobile: str) -> None:
    """Generates a code ourselves, sends it through your Android gateway phone, and remembers it for
    the matching /confirm call. Goes to whichever device is your default / most recently active —
    pass a specific device's id in the payload instead if you ever run more than one."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    payload = {
        "recipients": [_to_e164(mobile)],
        "message": f"Your NetPulse verification code is {code}. It expires in 10 minutes.",
    }
    headers = {"x-api-key": TEXTBEE_API_KEY}
    async with httpx.AsyncClient(timeout=15) as client:
        res = await client.post(TEXTBEE_SEND_URL, json=payload, headers=headers)
    if res.status_code >= 400:
        # Surface whatever textbee actually said is wrong (bad key, phone not connected, etc.) instead
        # of just the status code — that's the part that actually explains a failure like this.
        raise HTTPException(502, f"textbee rejected the request ({res.status_code}): {res.text[:300]}")
    _pending_otps[account_no] = (code, time.time() + OTP_TTL_SECONDS)


def _check_pending_otp(account_no: str, code: str) -> bool:
    """True only if a code was sent for this account_no, hasn't expired, and matches exactly. A correct
    match consumes it so it can't be reused; a wrong guess can still be retried until it expires, since
    rate_limit() above already caps how many guesses are allowed per minute."""
    pending = _pending_otps.get(account_no)
    if not pending:
        return False
    stored_code, expires_at = pending
    if time.time() >= expires_at:
        _pending_otps.pop(account_no, None)
        return False
    if not hmac.compare_digest(stored_code, code):
        return False
    _pending_otps.pop(account_no, None)  # one-time use once it succeeds
    return True


def _matching_account(db: Session, account_no: str, mobile: str) -> Account:
    acct = db.scalar(select(Account).where(Account.account_no == account_no))
    if not acct or acct.mobile != mobile:
        raise HTTPException(404, "No matching account")
    return acct


def _complete_link(db: Session, user: User, acct: Account) -> dict:
    if not db.get(Link, (user.id, acct.id)):
        db.add(Link(user_id=user.id, account_id=acct.id))
        db.commit()
    return account_view(acct, db)


@app.post("/api/v1/accounts/link/start", status_code=201)
async def start_link(body: LinkBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"link:{body.account_no}")
    acct = _matching_account(db, body.account_no, body.mobile)

    if not TEXTBEE_API_KEY:
        # Dev-mode fallback: no SMS gateway configured yet, so link immediately like before.
        return {"otp_required": False, **_complete_link(db, user, acct)}

    try:
        await _textbee_send_code(body.account_no, body.mobile)
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Could not reach the SMS gateway: {e}")
    return {"otp_required": True}


@app.post("/api/v1/accounts/link/confirm", status_code=201)
async def confirm_link(body: LinkConfirmBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"link-confirm:{body.account_no}")
    acct = _matching_account(db, body.account_no, body.mobile)

    if not TEXTBEE_API_KEY:
        return _complete_link(db, user, acct)  # nothing to confirm in dev mode

    if not _check_pending_otp(body.account_no, body.code):
        raise HTTPException(401, "Incorrect or expired code")
    return _complete_link(db, user, acct)


@app.get("/api/v1/accounts")
def list_accounts(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Account).join(Link, Link.account_id == Account.id).where(Link.user_id == user.id))
    return [account_view(a, db) for a in rows]


@app.get("/api/v1/accounts/{account_id}")
def get_account(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    return account_view(a, db)


@app.delete("/api/v1/accounts/{account_id}/link", status_code=204)
def unlink(account_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    link = db.get(Link, (user.id, account_id))
    if link:
        db.delete(link)
        db.commit()


# ---------- billing ----------
@app.get("/api/v1/accounts/{account_id}/bill")
def current_bill(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    latest = db.scalar(select(Bill).where(Bill.account_id == a.id).order_by(Bill.statement_date.desc()))
    return {"bill": bill_view(latest) if latest else None, "due_date": a.due_date.isoformat(), **money(a.balance)}


@app.get("/api/v1/accounts/{account_id}/bills")
def billing_history(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rows = db.scalars(select(Bill).where(Bill.account_id == a.id).order_by(Bill.statement_date.desc()))
    return [bill_view(b) for b in rows]


# ---------- payments ----------
class PayBody(BaseModel):
    amount: int  # minor units (centavos)


async def _create_paymongo_session(payment_id: int, amount: int, description: str) -> tuple[str, str]:
    """Creates a real PayMongo Hosted Checkout session. Returns (session_id, checkout_url)."""
    body = {
        "data": {
            "attributes": {
                "line_items": [{"currency": "PHP", "amount": amount, "name": description, "quantity": 1}],
                "payment_method_types": ["card", "gcash", "qrph"],
                # Not deep-linked back into the app yet — see the status-check endpoint below instead.
                "success_url": "https://paymongo.com/",
                "cancel_url": "https://paymongo.com/",
                "reference_number": str(payment_id),
                "description": description,
            }
        }
    }
    async with httpx.AsyncClient(timeout=15) as client:
        res = await client.post(f"{PAYMONGO_BASE}/checkout_sessions", json=body, auth=(PAYMONGO_SECRET_KEY, ""))
    res.raise_for_status()
    data = res.json()["data"]
    return data["id"], data["attributes"]["checkout_url"]


def _payment_entry_status(entry: dict) -> str:
    # Defensive: PayMongo's JSON:API responses usually nest fields under "attributes",
    # but handle a flat shape too in case a particular endpoint doesn't.
    return (entry.get("attributes") or {}).get("status") or entry.get("status") or ""


async def _paymongo_session_status(session_id: str) -> str:
    """Returns 'paid', 'failed', or 'pending'. PayMongo's own Payment Resource docs confirm these
    are the only three statuses a Payment can have, so this covers every case."""
    # Confirmed against PayMongo's own reference docs: retrieval lives on v1, unlike creation (v2).
    url = f"https://api.paymongo.com/v1/checkout_sessions/{session_id}"
    async with httpx.AsyncClient(timeout=15) as client:
        res = await client.get(url, auth=(PAYMONGO_SECRET_KEY, ""))
    res.raise_for_status()
    payments = res.json()["data"]["attributes"].get("payments") or []
    statuses = {_payment_entry_status(p) for p in payments}
    if "paid" in statuses:
        return "paid"
    if statuses and statuses == {"failed"}:  # every attempt so far failed, and nothing is still pending
        return "failed"
    return "pending"


def _mark_paid(db: Session, payment: Payment) -> None:
    """Shared by the webhook and the status-check endpoint. Idempotent: calling it twice changes nothing."""
    if payment.status == "PAID":
        return
    payment.status, payment.paid_at = "PAID", datetime.now(timezone.utc)
    acct = db.get(Account, payment.account_id)
    acct.balance -= payment.amount
    db.add(Notification(account_id=acct.id, title="Payment received",
                        body=f"We received {CURRENCY}{payment.amount / 100:,.2f}. Thank you!"))
    db.commit()


@app.post("/api/v1/accounts/{account_id}/payments", status_code=201)
async def start_payment(body: PayBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    if body.amount <= 0:
        raise HTTPException(422, "Amount must be greater than zero")
    payment = Payment(account_id=a.id, amount=body.amount)
    db.add(payment)
    db.commit()
    db.refresh(payment)

    if PAYMONGO_SECRET_KEY:
        plan = db.get(Plan, a.plan_id)
        try:
            session_id, checkout_url = await _create_paymongo_session(payment.id, body.amount, f"{plan.name} plan bill")
        except httpx.HTTPError as e:
            raise HTTPException(502, f"Could not reach the payment provider: {e}")
        payment.gateway_session_id = session_id
        db.commit()
        return {"payment_id": payment.id, "status": payment.status, "checkout_url": checkout_url, "real": True}

    # Dev-mode fallback: no PAYMONGO_SECRET_KEY configured yet, so keep the old one-tap simulator working.
    return {"payment_id": payment.id, "status": payment.status,
            "checkout_url": f"https://gateway.example/pay/{payment.id}", "real": False}


@app.post("/api/v1/accounts/{account_id}/payments/{payment_id}/check")
async def check_payment(payment_id: int, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    """Called by the app after the user says they've finished paying in the browser."""
    payment = db.get(Payment, payment_id)
    if not payment or payment.account_id != a.id:
        raise HTTPException(404, "Payment not found")
    if payment.status == "PAID":
        return {"payment_status": "paid", **account_view(a, db)}
    if not payment.gateway_session_id:
        raise HTTPException(409, "This payment isn't connected to a real payment session")
    try:
        gateway_status = await _paymongo_session_status(payment.gateway_session_id)
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Could not reach the payment provider: {e}")
    if gateway_status == "paid":
        _mark_paid(db, payment)
    # Named payment_status, not status, since account_view already has its own "status" (ACTIVE/SUSPENDED).
    return {"payment_status": gateway_status, **account_view(a, db)}


class WebhookBody(BaseModel):
    payment_id: int


@app.post("/api/v1/webhooks/payments")
def payment_webhook(body: WebhookBody, x_webhook_secret: str = Header(""), db: Session = Depends(get_db)):
    """Called by the dev-mode simulator below, never by PayMongo. A real PayMongo webhook needs a public
    URL and its own signature verification (HMAC-SHA256 over the Paymongo-Signature header) — a good next
    step once this is deployed somewhere reachable from the internet, instead of the status-check endpoint."""
    if not hmac.compare_digest(x_webhook_secret.encode(), WEBHOOK_SECRET.encode()):
        raise HTTPException(401, "Bad webhook secret")
    payment = db.get(Payment, body.payment_id)
    if not payment:
        raise HTTPException(404, "Unknown payment")
    _mark_paid(db, payment)
    return {"ok": True}


DEV_MODE = os.getenv("DEV_MODE", "0") == "1"  # off by default now; set DEV_MODE=1 locally if you want the
# one-tap payment shortcut back (e.g. to test without touching PayMongo) — never set it on a real deployment

if DEV_MODE:

    @app.post("/api/v1/dev/payments/{payment_id}/confirm")
    def dev_confirm(payment_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
        """Stand-in for the payment gateway while developing. Disabled when DEV_MODE=0."""
        payment = db.get(Payment, payment_id)
        if not payment or not db.get(Link, (user.id, payment.account_id)):
            raise HTTPException(404, "Payment not found")
        return payment_webhook(WebhookBody(payment_id=payment.id), WEBHOOK_SECRET, db)


@app.get("/api/v1/accounts/{account_id}/payments")
def payment_history(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rows = db.scalars(select(Payment).where(Payment.account_id == a.id, Payment.status == "PAID")
                      .order_by(Payment.paid_at.desc()))
    return [{"id": p.id, "amount": p.amount, "paid_at": p.paid_at.isoformat()} for p in rows]


# ---------- plans & notifications ----------
@app.get("/api/v1/plans")
def list_plans(db: Session = Depends(get_db)):
    rows = db.scalars(select(Plan).order_by(Plan.monthly_fee))
    return [{"id": p.id, "name": p.name, "speed_mbps": p.speed_mbps, "monthly_fee": p.monthly_fee} for p in rows]


class UpgradeBody(BaseModel):
    plan_id: int


@app.post("/api/v1/accounts/{account_id}/upgrade")
def upgrade_plan(body: UpgradeBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    if a.balance > 0:  # business rule lives on the server, not just in the app
        raise HTTPException(409, "Please settle your amount due before upgrading")
    plan = db.get(Plan, body.plan_id)
    if not plan:
        raise HTTPException(404, "Plan not found")
    a.plan_id = plan.id
    db.commit()
    return account_view(a, db)


@app.get("/api/v1/accounts/{account_id}/notifications")
def notifications(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rows = db.scalars(select(Notification).where(Notification.account_id == a.id)
                      .order_by(Notification.created_at.desc()))
    return [{"id": n.id, "title": n.title, "body": n.body, "created_at": n.created_at.isoformat()} for n in rows]


# ---------- issue reports ----------
ISSUE_CATEGORIES = {"Connection", "Billing", "Account", "Other"}


class IssueBody(BaseModel):
    category: str
    message: str


@app.post("/api/v1/accounts/{account_id}/issues", status_code=201)
def report_issue(body: IssueBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    if not body.message.strip():
        raise HTTPException(422, "Please describe the issue")
    category = body.category if body.category in ISSUE_CATEGORIES else "Other"
    issue = Issue(account_id=a.id, category=category, message=body.message.strip())
    db.add(issue)
    db.commit()
    return {"id": issue.id, "status": issue.status}


@app.get("/api/v1/accounts/{account_id}/issues")
def list_issues(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rows = db.scalars(select(Issue).where(Issue.account_id == a.id).order_by(Issue.created_at.desc()))
    return [{"id": i.id, "category": i.category, "message": i.message, "status": i.status,
             "created_at": i.created_at.isoformat()} for i in rows]


# ---------- add-ons ----------
def addon_view(a: AddOn) -> dict:
    return {"id": a.id, "name": a.name, "description": a.description, "monthly_fee": a.monthly_fee}


@app.get("/api/v1/addons")
def list_addons(db: Session = Depends(get_db)):
    rows = db.scalars(select(AddOn).order_by(AddOn.monthly_fee))
    return [addon_view(a) for a in rows]


@app.get("/api/v1/accounts/{account_id}/addons")
def account_addons(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rows = db.scalars(
        select(AddOn).join(AccountAddOn, AccountAddOn.addon_id == AddOn.id).where(AccountAddOn.account_id == a.id)
    )
    return [addon_view(x) for x in rows]


class AddOnBody(BaseModel):
    addon_id: int


@app.post("/api/v1/accounts/{account_id}/addons", status_code=201)
def subscribe_addon(body: AddOnBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    addon = db.get(AddOn, body.addon_id)
    if not addon:
        raise HTTPException(404, "Add-on not found")
    if db.get(AccountAddOn, (a.id, addon.id)):
        raise HTTPException(409, "Already subscribed to this add-on")
    db.add(AccountAddOn(account_id=a.id, addon_id=addon.id))
    a.balance += addon.monthly_fee  # simplified: added to the current bill rather than prorated to next cycle
    db.commit()
    return account_view(a, db)


@app.delete("/api/v1/accounts/{account_id}/addons/{addon_id}")
def unsubscribe_addon(addon_id: int, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    link = db.get(AccountAddOn, (a.id, addon_id))
    if not link:
        raise HTTPException(404, "Add-on not active on this account")
    addon = db.get(AddOn, addon_id)
    db.delete(link)
    a.balance -= addon.monthly_fee
    db.commit()
    return account_view(a, db)


if __name__ == "__main__":
    # Lets VS Code's Run/F5 button start the server directly — equivalent to running
    # `uvicorn main:app --reload` by hand. Only runs when this file is executed directly,
    # never when something else imports it (e.g. the test suite), so nothing else changes.
    import uvicorn

    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)