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
import re
import secrets
import smtplib
import time
from collections import defaultdict
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path

import httpx
import jwt
from dotenv import load_dotenv
from google.auth.transport import requests as google_auth_transport
from google.oauth2 import id_token as google_id_token
from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException, Request
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

# Leave unset until you register a real webhook (Dashboard > Developers > Webhooks). This is the secret
# PayMongo shows you there when you create it — a completely different value from WEBHOOK_SECRET above,
# which is only for the local dev-mode simulator and is never involved in a real webhook at all.
PAYMONGO_WEBHOOK_SECRET = config_value("PAYMONGO_WEBHOOK_SECRET")

# Leave TEXTBEE_API_KEY unset to keep linking accounts with just a phone-number match (today's behavior,
# no SMS code). Set it to require an SMS code too, sent through your own Android phone acting as a free
# SMS gateway instead of a paid provider — sign up at textbee.dev, install their app on a spare phone,
# then generate an API key on the dashboard.
TEXTBEE_API_KEY = config_value("TEXTBEE_API_KEY")
TEXTBEE_SEND_URL = "https://api.textbee.dev/api/v1/gateway/send-sms"
OTP_TTL_SECONDS = 180  # textbee doesn't track an expiry itself, so this server enforces its own (3 min)

# Leave SMTP_USERNAME unset to keep registering/logging in without email verification (today's
# behavior). Set SMTP_USERNAME + SMTP_PASSWORD to require it. Easiest option: a Gmail address with an
# "App Password" (Google Account > Security > 2-Step Verification > App passwords) — not your real
# Gmail password, which won't work here. No signup, no approval wait, unlike the SMS providers.
SMTP_USERNAME = config_value("SMTP_USERNAME")
SMTP_PASSWORD = config_value("SMTP_PASSWORD")
SMTP_HOST = config_value("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(config_value("SMTP_PORT", "587"))

# Leave unset to keep "Sign in with Google" disabled server-side (the app's button will show an error
# if tapped). Set it to the Web OAuth client ID from Google Cloud Console (APIs & Services >
# Credentials) — the SAME value the Flutter app uses as its serverClientId. This has to be the Web
# client, not the Android one: Google signs the token for whichever client requested it, and the
# Android google_sign_in setup is built around requesting it for the paired web client, so the ID
# token's audience always comes back as the web client's ID.
GOOGLE_CLIENT_ID = config_value("GOOGLE_CLIENT_ID")

engine = create_engine(f"sqlite:///{(_BASE_DIR / 'app.db').as_posix()}", connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(engine, expire_on_commit=False)


# ---------- database models ----------
class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String, unique=True)
    # Optional now: a user created through Google sign-in has no password at all (nothing to check
    # against), rather than a hash of some random value nobody will ever type.
    password_hash: Mapped[str | None] = mapped_column(default=None)
    email_verified: Mapped[bool] = mapped_column(default=False)
    # Google's stable per-account ID ("sub" in the ID token) for a user who has ever signed in with
    # Google. Deliberately not the email: a Google account's email can change, sub never does.
    google_sub: Mapped[str | None] = mapped_column(String, unique=True, default=None)
    # Collected on the registration form (absent for older users and for Google sign-ups).
    first_name: Mapped[str | None] = mapped_column(String, default=None)
    last_name: Mapped[str | None] = mapped_column(String, default=None)
    mobile: Mapped[str | None] = mapped_column(String, default=None)


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


class LinkRequest(Base):  # a user asking to be linked to an account; approved by hand
    __tablename__ = "link_requests"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    status: Mapped[str] = mapped_column(default="PENDING")  # PENDING | APPROVED | REJECTED
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))
    # Filled in when staff decide it (see the staff section further down).
    decided_by: Mapped[int | None] = mapped_column(ForeignKey("staff.id"), default=None)
    decided_at: Mapped[datetime | None] = mapped_column(default=None)
    reason: Mapped[str | None] = mapped_column(default=None)  # why it was declined, shown to the customer


class Staff(Base):  # people who work for the service provider and use the staff dashboard
    __tablename__ = "staff"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String, unique=True)
    name: Mapped[str]
    password_hash: Mapped[str]
    role: Mapped[str] = mapped_column(default="support")  # admin | support
    active: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))


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
    # create_all never alters an existing table, so add the registration columns to an older database.
    with engine.begin() as conn:
        have = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(users)")}
        for col in ("first_name", "last_name", "mobile"):
            if col not in have:
                conn.exec_driver_sql(f"ALTER TABLE users ADD COLUMN {col} VARCHAR")
        have = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(link_requests)")}
        for col, kind in (("decided_by", "INTEGER"), ("decided_at", "DATETIME"), ("reason", "VARCHAR")):
            if col not in have:
                conn.exec_driver_sql(f"ALTER TABLE link_requests ADD COLUMN {col} {kind}")
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


def _pw_version(user: User) -> str:
    """A short fingerprint of the user's current password hash, stamped into every login token. Changing
    the password changes the hash (fresh random salt each time), so every token issued before the change
    stops matching and is rejected — that's what signs a user out everywhere after a password reset,
    without needing a new database column."""
    return hashlib.sha256((user.password_hash or "").encode()).hexdigest()[:16]


def make_token(user: User) -> str:
    exp = datetime.now(timezone.utc) + timedelta(days=30)  # was 12 hours; mobile apps expect to stay signed in
    return jwt.encode({"sub": str(user.id), "exp": exp, "pv": _pw_version(user)}, JWT_SECRET, algorithm="HS256")


bearer = HTTPBearer()


def current_user(creds: HTTPAuthorizationCredentials = Depends(bearer), db: Session = Depends(get_db)) -> User:
    try:
        payload = jwt.decode(creds.credentials, JWT_SECRET, algorithms=["HS256"])
        user_id = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if payload.get("typ") == "staff":  # a staff login is not a customer login
        raise HTTPException(401, "Invalid or expired token")
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(401, "Unknown user")
    # A token from before the password last changed (or from before this check existed) doesn't match.
    if payload.get("pv") != _pw_version(user):
        raise HTTPException(401, "Invalid or expired token")
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
        "service_address": a.service_address, "mobile": a.mobile, "due_date": a.due_date.isoformat(),
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


class RegisterBody(Credentials):
    first_name: str
    last_name: str
    mobile: str
    accepted_terms: bool = False


def _password_problem(pw: str) -> str | None:
    """The rule for a NEW password (registration, reset, change). Logging in doesn't use it, so people
    who signed up under the old 8-character rule can still sign in."""
    if len(pw) < 8 or not any(c.isupper() for c in pw) or not any(c.isdigit() for c in pw):
        return "Password must be 8 characters or more with an uppercase character and a number"
    return None


class EmailVerifyBody(BaseModel):
    email: str
    code: str


# Same shape as _pending_otps for SMS, but a separate dict keyed by email instead of account_no — the
# two verification flows are unrelated and shouldn't share a namespace.
_pending_email_otps: dict[str, tuple[str, float]] = {}


def _deliver_email_code(email: str, code: str, subject: str = "Your NetPulse verification code",
                        message: str | None = None) -> None:
    """Just sends the email — callers generate the code and decide where to remember it, so this can
    be reused for other things that need an emailed code besides registration/login."""
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_USERNAME
    msg["To"] = email
    msg.set_content(message or f"Your NetPulse verification code is {code}. It expires in 3 minutes.")
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as server:
            server.starttls()
            server.login(SMTP_USERNAME, SMTP_PASSWORD)
            server.send_message(msg)
    except Exception as e:
        # smtplib raises several different exception types (auth failure, connection refused, DNS
        # issues...) — catching broadly and surfacing the real message beats guessing which one to expect.
        raise HTTPException(502, f"Could not send verification email: {e}")


def _send_email_code(email: str) -> None:
    """Generates a code, emails it, and remembers it for the matching /verify-email call."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    _deliver_email_code(email, code)
    _pending_email_otps[email] = (code, time.time() + OTP_TTL_SECONDS)


def _check_pending_email_otp(email: str, code: str) -> bool:
    """Same logic as _check_pending_otp for SMS: a correct match consumes it, a wrong guess can be
    retried until it expires, rate-limited by the caller."""
    pending = _pending_email_otps.get(email)
    if not pending:
        return False
    stored_code, expires_at = pending
    if time.time() >= expires_at:
        _pending_email_otps.pop(email, None)
        return False
    if not hmac.compare_digest(stored_code, code):
        return False
    _pending_email_otps.pop(email, None)
    return True


@app.post("/api/v1/auth/register", status_code=201)
def register(body: RegisterBody, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    if "@" not in email:
        raise HTTPException(422, "Enter a valid email")
    problem = _password_problem(body.password)
    if problem:
        raise HTTPException(422, problem)
    first, last = body.first_name.strip(), body.last_name.strip()
    if not first or not last:
        raise HTTPException(422, "Enter your first and last name")
    mobile = _normalize_mobile(body.mobile)
    if not mobile:
        raise HTTPException(422, "Enter a valid mobile number")
    if not body.accepted_terms:
        raise HTTPException(422, "Please accept the Privacy Policy and the Terms & Conditions")
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, "Email already registered")
    user = User(email=email, password_hash=hash_pw(body.password), email_verified=not SMTP_USERNAME,
                first_name=first, last_name=last, mobile=mobile)
    db.add(user)
    db.commit()
    if not SMTP_USERNAME:
        # Dev-mode fallback: no email provider configured yet, so sign in immediately like before.
        return {"verification_required": False, "token": make_token(user)}
    _send_email_code(email)
    return {"verification_required": True}


@app.post("/api/v1/auth/login")
def login(body: Credentials, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"login:{email}")
    user = db.scalar(select(User).where(User.email == email))
    # A Google-only account has no password_hash to check against — same error either way, so this
    # doesn't leak whether the account exists at all, let alone how it was created.
    if not user or not user.password_hash or not check_pw(body.password, user.password_hash):
        raise HTTPException(401, "Wrong email or password")
    if SMTP_USERNAME and not user.email_verified:
        _send_email_code(email)  # also doubles as "resend" if they never finished verifying
        return {"verification_required": True}
    return {"verification_required": False, "token": make_token(user)}


@app.post("/api/v1/auth/verify-email", status_code=201)
def verify_email(body: EmailVerifyBody, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"verify-email:{email}")
    user = db.scalar(select(User).where(User.email == email))
    if not user:
        raise HTTPException(404, "No account with that email")
    if not _check_pending_email_otp(email, body.code):
        raise HTTPException(401, "Incorrect or expired code")
    user.email_verified = True
    db.commit()
    return {"token": make_token(user)}


class ForgotPasswordBody(BaseModel):
    email: str


class ResetPasswordBody(BaseModel):
    email: str
    code: str
    new_password: str


# Reset codes, kept apart from the registration-verification ones above: unrelated flows, and a code
# emailed for one must never work for the other.
_pending_reset_otps: dict[str, tuple[str, float]] = {}


def _check_pending_reset_otp(email: str, code: str) -> bool:
    """Same expire/consume logic as _check_pending_email_otp, against the reset codes."""
    pending = _pending_reset_otps.get(email)
    if not pending:
        return False
    stored_code, expires_at = pending
    if time.time() >= expires_at:
        _pending_reset_otps.pop(email, None)
        return False
    if not hmac.compare_digest(stored_code, code):
        return False
    _pending_reset_otps.pop(email, None)  # one-time use once it succeeds
    return True


def _send_reset_email(email: str, code: str) -> None:
    """Runs after the HTTP response has already gone out (see forgot_password), so a send failure can't
    change what the caller sees — it's printed to the server console instead."""
    try:
        _deliver_email_code(
            email, code,
            subject="Reset your NetPulse password",
            message=f"Your NetPulse password reset code is {code}. It expires in 3 minutes.\n\n"
                    "If you didn't ask to reset your password, you can ignore this email.",
        )
    except HTTPException as e:
        print(f"[password reset] could not email {email}: {e.detail}")


@app.post("/api/v1/auth/forgot-password")
def forgot_password(body: ForgotPasswordBody, background: BackgroundTasks, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"forgot:{email}", max_attempts=3)  # also keeps this from being used to spam someone's inbox
    user = db.scalar(select(User).where(User.email == email))
    if not user:
        # Says so plainly, so a mistyped email is obvious right away. (register already says "Email already
        # registered", so this doesn't reveal anything new; the 3-per-minute limit above slows down anyone
        # trying to probe for accounts.)
        raise HTTPException(404, "We couldn't find an account with that email. Check the spelling, or create an account.")
    code = f"{secrets.randbelow(1_000_000):06d}"
    _pending_reset_otps[email] = (code, time.time() + OTP_TTL_SECONDS)
    if SMTP_USERNAME:
        # Sent in the background so the app isn't left waiting on the mail server; a failure is printed
        # to the console by _send_reset_email.
        background.add_task(_send_reset_email, email, code)
    else:
        # Dev-mode fallback: no email provider configured yet, so show the code here instead.
        print(f"[password reset] code for {email}: {code}")
    return {"ok": True}


def _ph_time_text() -> str:
    """The current time the way people in the Philippines read it, for security notices."""
    return datetime.now(timezone(timedelta(hours=8))).strftime("%b %d, %Y at %I:%M %p") + ", Philippine time"


def _send_notice_email(email: str, subject: str, message: str) -> None:
    """Background task: sends a plain email notice. Failures are printed to the console, never raised."""
    try:
        _deliver_email_code(email, "", subject=subject, message=message)
    except HTTPException as e:
        print(f"[notice] could not email {email}: {e.detail}")


async def _send_notice_sms(mobile: str, message: str) -> None:
    """Background task: sends a plain text-message notice. Failures are printed, never raised."""
    try:
        await _deliver_sms_code(mobile, "", message=message)
    except (HTTPException, httpx.HTTPError) as e:
        print(f"[notice] could not text {mobile}: {getattr(e, 'detail', e)}")


def _linked_mobiles(db: Session, user: User) -> list[str]:
    """Users have no phone number of their own here: numbers live on the accounts they've linked, so
    texts go to each distinct number on those."""
    rows = db.scalars(select(Account).join(Link, Link.account_id == Account.id).where(Link.user_id == user.id))
    return sorted({a.mobile for a in rows})


def _queue_notices(background: BackgroundTasks, *, label: str, email: str | None, mobiles: list[str],
                   subject: str, email_text: str, sms_text: str) -> None:
    """Emails and texts a security notice once the response has gone out, through whichever providers
    are configured, so a failed send never changes what the caller sees."""
    if SMTP_USERNAME and email:
        background.add_task(_send_notice_email, email, subject, email_text)
    if TEXTBEE_API_KEY:
        for mobile in mobiles:
            background.add_task(_send_notice_sms, mobile, sms_text)
    if not SMTP_USERNAME and not TEXTBEE_API_KEY:
        # Dev-mode fallback: no providers configured yet, so just show what would have been sent.
        print(f"[{label}] would notify {email} by email and {mobiles or 'no linked numbers'} by SMS")


def _notify_password_changed(background: BackgroundTasks, db: Session, user: User, label: str) -> None:
    """The "your password was changed" heads-up, by email and text, so a change the owner didn't make
    gets noticed. Shared by the reset flow and the Account tab's change-password."""
    _queue_notices(
        background, label=label, email=user.email, mobiles=_linked_mobiles(db, user),
        subject="Your NetPulse password was changed",
        email_text=f"The password for your NetPulse account was just changed ({_ph_time_text()}).\n\n"
                   "If this was you, no action is needed.\n"
                   "If it wasn't, open NetPulse and tap Forgot password to reset it again right away.",
        sms_text="NetPulse: your password was just changed. If this wasn't you, use Forgot password in the app now.",
    )


@app.post("/api/v1/auth/reset-password")
def reset_password(body: ResetPasswordBody, background: BackgroundTasks, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"reset:{email}")
    problem = _password_problem(body.new_password)
    if problem:
        raise HTTPException(422, problem)
    user = db.scalar(select(User).where(User.email == email))
    # An unknown email never has a pending code, so it fails exactly like a wrong or expired one.
    if not user or not _check_pending_reset_otp(email, body.code.strip()):
        raise HTTPException(401, "Incorrect or expired code")
    user.password_hash = hash_pw(body.new_password)  # also gives a Google-only account a password
    user.email_verified = True  # they just proved they can read this inbox
    db.commit()
    # No token comes back: the new hash already invalidated every login this user had (see _pw_version),
    # so they sign in again with the new password.

    _notify_password_changed(background, db, user, "password reset")  # by email and by text
    return {"ok": True}


class GoogleSignInBody(BaseModel):
    id_token: str


@app.post("/api/v1/auth/google", status_code=201)
def google_sign_in(body: GoogleSignInBody, db: Session = Depends(get_db)):
    if not GOOGLE_CLIENT_ID:
        raise HTTPException(400, "Google sign-in isn't configured on this server")

    # verify_oauth2_token checks the signature against Google's own public keys, the expiry, the
    # issuer, and (since we pass GOOGLE_CLIENT_ID as the audience) that the token was actually issued
    # for this app and not some other one. Catching broadly and surfacing the message beats guessing
    # which of the library's several exception types a given bad token will raise.
    try:
        info = google_id_token.verify_oauth2_token(
            body.id_token, google_auth_transport.Request(), GOOGLE_CLIENT_ID
        )
    except Exception as e:
        raise HTTPException(401, f"Invalid Google sign-in token: {e}")

    if not info.get("email_verified", True):
        raise HTTPException(401, "Google reports this email isn't verified")
    email = info["email"].strip().lower()
    google_sub = info["sub"]

    user = db.scalar(select(User).where(User.google_sub == google_sub))
    if not user:
        # First time this Google identity has signed in here. If the email already has a
        # password-based account, link Google to it rather than creating a duplicate; otherwise
        # create a fresh account. Either way, trust the email as verified — Google already checked it,
        # so there's no need to send our own code to an address we know is real.
        user = db.scalar(select(User).where(User.email == email))
        if user:
            user.google_sub = google_sub
            user.email_verified = True
        else:
            user = User(email=email, email_verified=True, google_sub=google_sub)
            db.add(user)
        db.commit()
    return {"token": make_token(user)}


# ---------- accounts ----------


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


async def _deliver_sms_code(mobile: str, code: str, message: str | None = None) -> None:
    """Just sends the SMS through your Android gateway phone — callers generate the code and decide
    where to remember it, so this can be reused for other things that need a texted code besides
    account linking (or, with [message], a plain notice that has no code). Goes to whichever device is
    your default / most recently active — pass a specific device's id in the payload instead if you
    ever run more than one."""
    payload = {
        "recipients": [_to_e164(mobile)],
        "message": message or f"Your NetPulse verification code is {code}. It expires in 3 minutes.",
    }
    headers = {"x-api-key": TEXTBEE_API_KEY}
    async with httpx.AsyncClient(timeout=15) as client:
        res = await client.post(TEXTBEE_SEND_URL, json=payload, headers=headers)
    if res.status_code >= 400:
        # Surface whatever textbee actually said is wrong (bad key, phone not connected, etc.) instead
        # of just the status code — that's the part that actually explains a failure like this.
        raise HTTPException(502, f"textbee rejected the request ({res.status_code}): {res.text[:300]}")


async def _textbee_send_code(account_no: str, mobile: str) -> None:
    """Generates a code, sends it through your Android gateway phone, and remembers it for the
    matching /confirm call."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    await _deliver_sms_code(mobile, code)
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


class LinkRequestBody(BaseModel):
    account_no: str


@app.post("/api/v1/accounts/link/request", status_code=201)
def request_link(body: LinkRequestBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Linking is approved by hand: this only files a request, and the account appears once it's approved."""
    rate_limit(f"link-request:{user.id}")
    account_no = body.account_no.strip()
    acct = db.scalar(select(Account).where(Account.account_no == account_no))
    if not acct:
        raise HTTPException(404, "We couldn't find that account number. Please check it and try again.")
    if db.get(Link, (user.id, acct.id)):
        raise HTTPException(409, "This account is already linked to your login.")
    # A new request replaces an earlier declined one for the same account, so a stale "declined" note goes away.
    for old in db.scalars(select(LinkRequest).where(
            LinkRequest.user_id == user.id, LinkRequest.account_id == acct.id, LinkRequest.status == "REJECTED")):
        db.delete(old)
    pending = db.scalar(select(LinkRequest).where(
        LinkRequest.user_id == user.id, LinkRequest.account_id == acct.id, LinkRequest.status == "PENDING"))
    if not pending:
        db.add(LinkRequest(user_id=user.id, account_id=acct.id))
        db.commit()
    return {"status": "PENDING"}


@app.get("/api/v1/accounts/link/requests")
def my_link_requests(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.execute(select(LinkRequest, Account).join(Account, Account.id == LinkRequest.account_id)
                      .where(LinkRequest.user_id == user.id, LinkRequest.status.in_(("PENDING", "REJECTED")))
                      .order_by(LinkRequest.id)).all()
    return [{"id": r.id, "account_no": a.account_no, "status": r.status, "created_at": r.created_at.isoformat(),
             "reason": r.reason} for r, a in rows]


@app.post("/api/v1/accounts/link/requests/{request_id}/dismiss", status_code=204)
def dismiss_link_request(request_id: int, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Clears a declined request's note once the user has seen it. Pending ones can't be dismissed."""
    req = db.get(LinkRequest, request_id)
    if req and req.user_id == user.id and req.status == "REJECTED":
        db.delete(req)
        db.commit()


# ---------- staff: the provider's side (web dashboard + its API) ----------
# Staff are separate from customers: their own table, their own login, and tokens that carry typ="staff" so a
# customer's token never works here and a staff token never works in the customer app. The dashboard itself is
# the static page in the staff_portal folder, served at /staff/.
STAFF_TOKEN_HOURS = 12
STAFF_ROLES = ("admin", "support")  # admin: everything, including managing staff; support: day-to-day requests


def _iso(dt: datetime | None) -> str | None:
    """Timestamps are stored as UTC without a zone; send them with a Z so browsers convert correctly."""
    if dt is None:
        return None
    return dt.isoformat() + ("Z" if dt.tzinfo is None else "")


def _staff_pw_version(staff: Staff) -> str:
    return hashlib.sha256(staff.password_hash.encode()).hexdigest()[:16]


def make_staff_token(staff: Staff) -> str:
    exp = datetime.now(timezone.utc) + timedelta(hours=STAFF_TOKEN_HOURS)
    return jwt.encode({"sub": str(staff.id), "typ": "staff", "exp": exp, "pv": _staff_pw_version(staff)},
                      JWT_SECRET, algorithm="HS256")


def current_staff(creds: HTTPAuthorizationCredentials = Depends(bearer), db: Session = Depends(get_db)) -> Staff:
    try:
        payload = jwt.decode(creds.credentials, JWT_SECRET, algorithms=["HS256"])
        staff_id = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    if payload.get("typ") != "staff":
        raise HTTPException(401, "Invalid or expired token")
    staff = db.get(Staff, staff_id)
    if not staff or not staff.active or payload.get("pv") != _staff_pw_version(staff):
        raise HTTPException(401, "Invalid or expired token")
    return staff


def admin_only(staff: Staff = Depends(current_staff)) -> Staff:
    if staff.role != "admin":
        raise HTTPException(403, "Only an admin can do this")
    return staff


def _staff_view(s: Staff) -> dict:
    return {"id": s.id, "email": s.email, "name": s.name, "role": s.role, "active": s.active,
            "created_at": _iso(s.created_at)}


def _staff_password_problem(pw: str) -> str | None:
    if len(pw) < 10:
        return "Staff passwords must be at least 10 characters"
    return _password_problem(pw)


class StaffLoginBody(BaseModel):
    email: str
    password: str


@app.post("/api/v1/staff/login")
def staff_login(body: StaffLoginBody, request: Request, db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    rate_limit(f"staff-login:{email}")
    rate_limit(f"staff-login-ip:{request.client.host if request.client else '?'}", max_attempts=20)
    staff = db.scalar(select(Staff).where(Staff.email == email))
    # The same answer for an unknown email, a wrong password and a deactivated person.
    if not staff or not staff.active or not check_pw(body.password, staff.password_hash):
        raise HTTPException(401, "Wrong email or password")
    return {"token": make_staff_token(staff), "staff": _staff_view(staff)}


@app.get("/api/v1/staff/me")
def staff_me(staff: Staff = Depends(current_staff)):
    return _staff_view(staff)


class StaffPasswordBody(BaseModel):
    current_password: str
    new_password: str


@app.post("/api/v1/staff/me/password")
def staff_change_password(body: StaffPasswordBody, staff: Staff = Depends(current_staff),
                          db: Session = Depends(get_db)):
    rate_limit(f"staff-pw:{staff.id}")
    if not check_pw(body.current_password, staff.password_hash):
        raise HTTPException(403, "Your current password is wrong")  # 403, never 401: the dashboard treats 401 as "signed out"
    problem = _staff_password_problem(body.new_password)
    if problem:
        raise HTTPException(422, problem)
    staff.password_hash = hash_pw(body.new_password)
    db.commit()
    return {"token": make_staff_token(staff)}  # the old token stopped working with the old password


# ----- link requests -----
def _name_tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z]+", (text or "").lower()))


def _link_request_view(req: LinkRequest, user: User, acct: Account, plan: Plan | None, db: Session) -> dict:
    holder = _name_tokens(acct.holder_name)
    first, last = _name_tokens(user.first_name or ""), _name_tokens(user.last_name or "")
    user_mobile = _normalize_mobile(user.mobile or "") if user.mobile else None
    acct_mobile = _normalize_mobile(acct.mobile or "")
    decided_by = db.get(Staff, req.decided_by) if req.decided_by else None
    return {
        "id": req.id,
        "status": req.status,
        "requested_at": _iso(req.created_at),
        "decided_at": _iso(req.decided_at),
        "decided_by": decided_by.name if decided_by else None,
        "reason": req.reason,
        "requester": {"email": user.email, "name": f"{user.first_name or ''} {user.last_name or ''}".strip(),
                      "mobile": user.mobile},
        "account": {"account_no": acct.account_no, "holder_name": acct.holder_name, "mobile": acct.mobile,
                    "service_address": acct.service_address, "status": acct.status,
                    "plan": plan.name if plan else None},
        # Quick checks to help staff decide; they are hints, not proof.
        "signals": {
            "mobile_match": bool(user_mobile and acct_mobile and user_mobile == acct_mobile),
            "name_match": bool(first and last and first & holder and last & holder),
            "already_linked_logins": len(db.scalars(select(Link).where(Link.account_id == acct.id)).all()),
            "other_pending_for_account": len(db.scalars(select(LinkRequest).where(
                LinkRequest.account_id == acct.id, LinkRequest.status == "PENDING", LinkRequest.id != req.id)).all()),
        },
    }


@app.get("/api/v1/staff/link-requests")
def staff_list_link_requests(status: str = "PENDING", staff: Staff = Depends(current_staff),
                             db: Session = Depends(get_db)):
    status = status.upper()
    if status not in ("PENDING", "APPROVED", "REJECTED"):
        raise HTTPException(422, "status must be PENDING, APPROVED or REJECTED")
    counts = {st: len(db.scalars(select(LinkRequest.id).where(LinkRequest.status == st)).all())
              for st in ("PENDING", "APPROVED", "REJECTED")}
    # The pending queue is oldest first (first come, first served); the history is newest first.
    order = LinkRequest.id if status == "PENDING" else LinkRequest.id.desc()
    rows = db.execute(select(LinkRequest, User, Account).join(User, User.id == LinkRequest.user_id)
                      .join(Account, Account.id == LinkRequest.account_id)
                      .where(LinkRequest.status == status).order_by(order).limit(200)).all()
    return {"counts": counts,
            "items": [_link_request_view(r, u, a, db.get(Plan, a.plan_id), db) for r, u, a in rows]}


class DecisionBody(BaseModel):
    reason: str | None = None


def _decide_link_request(request_id: int, approve: bool, reason: str | None, staff: Staff,
                         background: BackgroundTasks, db: Session) -> dict:
    req = db.get(LinkRequest, request_id)
    if not req:
        raise HTTPException(404, "Request not found")
    if req.status != "PENDING":
        raise HTTPException(409, f"This request was already {req.status.lower()}")
    user, acct = db.get(User, req.user_id), db.get(Account, req.account_id)
    reason = (reason or "").strip()[:200] or None
    if approve:
        _complete_link(db, user, acct)
    req.status = "APPROVED" if approve else "REJECTED"
    req.decided_by, req.decided_at = staff.id, datetime.now(timezone.utc)
    req.reason = None if approve else reason
    db.commit()
    verdict = "approved" if approve else "declined"
    text = f"Your request to link account {acct.account_no} to NetPulse was {verdict}."
    if approve:
        text += " Open the app to see it."
    else:
        text += (f" Reason: {reason}." if reason else "") + " If you think this is a mistake, please contact us."
    _queue_notices(background, label=f"link {verdict}", email=user.email, mobiles=[],
                   subject=f"Your NetPulse link request was {verdict}", email_text=text, sms_text="")
    return _link_request_view(req, user, acct, db.get(Plan, acct.plan_id), db)


@app.post("/api/v1/staff/link-requests/{request_id}/approve")
def staff_approve_link(request_id: int, background: BackgroundTasks, staff: Staff = Depends(current_staff),
                       db: Session = Depends(get_db)):
    return _decide_link_request(request_id, True, None, staff, background, db)


@app.post("/api/v1/staff/link-requests/{request_id}/reject")
def staff_reject_link(request_id: int, body: DecisionBody, background: BackgroundTasks,
                      staff: Staff = Depends(current_staff), db: Session = Depends(get_db)):
    return _decide_link_request(request_id, False, body.reason, staff, background, db)


# ----- managing staff (admins only) -----
class NewStaffBody(BaseModel):
    email: str
    name: str
    role: str = "support"
    password: str


class UpdateStaffBody(BaseModel):
    role: str | None = None
    active: bool | None = None
    new_password: str | None = None


@app.get("/api/v1/staff/staff")
def list_staff(_: Staff = Depends(admin_only), db: Session = Depends(get_db)):
    return [_staff_view(s) for s in db.scalars(select(Staff).order_by(Staff.id))]


@app.post("/api/v1/staff/staff", status_code=201)
def create_staff(body: NewStaffBody, _: Staff = Depends(admin_only), db: Session = Depends(get_db)):
    email = body.email.strip().lower()
    if "@" not in email or not body.name.strip():
        raise HTTPException(422, "Enter a name and a valid email")
    if body.role not in STAFF_ROLES:
        raise HTTPException(422, "Role must be admin or support")
    problem = _staff_password_problem(body.password)
    if problem:
        raise HTTPException(422, problem)
    if db.scalar(select(Staff).where(Staff.email == email)):
        raise HTTPException(409, "A staff member with that email already exists")
    s = Staff(email=email, name=body.name.strip(), role=body.role, password_hash=hash_pw(body.password))
    db.add(s)
    db.commit()
    return _staff_view(s)


@app.post("/api/v1/staff/staff/{staff_id}/update")
def update_staff(staff_id: int, body: UpdateStaffBody, me: Staff = Depends(admin_only),
                 db: Session = Depends(get_db)):
    s = db.get(Staff, staff_id)
    if not s:
        raise HTTPException(404, "Staff member not found")
    if body.role is not None and body.role not in STAFF_ROLES:
        raise HTTPException(422, "Role must be admin or support")
    if s.id == me.id and ((body.role and body.role != "admin") or body.active is False):
        raise HTTPException(409, "You can't demote or deactivate yourself")
    if body.new_password is not None:
        problem = _staff_password_problem(body.new_password)
        if problem:
            raise HTTPException(422, problem)
        s.password_hash = hash_pw(body.new_password)  # signs that person out everywhere
    if body.role is not None:
        s.role = body.role
    if body.active is not None:
        s.active = body.active
    db.commit()
    return _staff_view(s)


# ----- the dashboard page itself -----
STAFF_PORTAL_DIR = _BASE_DIR / "staff_portal"


@app.middleware("http")
async def staff_page_headers(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/staff"):
        # The dashboard only loads its own scripts and styles, can't be put in a frame, and isn't cached.
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
    return response


if STAFF_PORTAL_DIR.is_dir():
    from fastapi.staticfiles import StaticFiles
    app.mount("/staff", StaticFiles(directory=STAFF_PORTAL_DIR, html=True), name="staff_portal")


@app.get("/api/v1/accounts")
def list_accounts(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Account).join(Link, Link.account_id == Account.id).where(Link.user_id == user.id))
    return [account_view(a, db) for a in rows]


@app.get("/api/v1/accounts/{account_id}")
def get_account(a: Account = Depends(my_account), db: Session = Depends(get_db)):
    return account_view(a, db)


class UnlinkBody(BaseModel):
    current_password: str


@app.post("/api/v1/accounts/{account_id}/unlink", status_code=204)
def unlink(account_id: int, body: UnlinkBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Used to be a plain DELETE with no body; now it asks for the password like every other change to
    the user's own details (and there is deliberately no password-free route left)."""
    rate_limit(f"me-unlink:{user.id}")
    _require_password(user, body.current_password)
    link = db.get(Link, (user.id, account_id))
    if link:
        db.delete(link)
        db.commit()


# ---------- my profile: password, email, mobile number, delete ----------
class CodeBody(BaseModel):
    code: str


class ChangePasswordBody(BaseModel):
    current_password: str
    new_password: str


class EmailChangeBody(BaseModel):
    new_email: str
    current_password: str


class MobileChangeBody(BaseModel):
    new_mobile: str
    current_password: str


class DeleteMeBody(BaseModel):
    current_password: str


# Codes for the two "confirm the new contact detail" flows, one dict each (unrelated flows, so no shared
# namespace). Value: (code, expires_at, the new email / mobile number the code is for). In-memory, like
# the other pending codes: lost on restart.
_pending_email_changes: dict[int, tuple[str, float, str]] = {}  # user id -> ...
_pending_mobile_changes: dict[tuple[int, int], tuple[str, float, str]] = {}  # (user id, account id) -> ...


def _check_pending_change(store: dict, key, code: str) -> str | None:
    """Returns the new email / mobile number on a correct, unexpired code (consuming it), else None."""
    pending = store.get(key)
    if not pending:
        return None
    stored_code, expires_at, value = pending
    if time.time() >= expires_at:
        store.pop(key, None)
        return None
    if not hmac.compare_digest(stored_code, code):
        return None
    store.pop(key, None)
    return value


def _require_password(user: User, password: str) -> None:
    """Sensitive changes ask for the current password again. A wrong one answers 403, never 401: the app
    treats any 401 on a request that carried its login as "your session expired" and signs the user out.
    A Google-only account has no password yet, so it has to set one first (via Forgot password)."""
    if not user.password_hash:
        raise HTTPException(409, "Set a password first (use Forgot password to create one), then try again.")
    if not check_pw(password, user.password_hash):
        raise HTTPException(403, "That password is incorrect")


def _normalize_mobile(raw: str) -> str | None:
    """Drops spaces and dashes and turns +63 / 63 numbers into the local 09XXXXXXXXX form the accounts
    use. None if it doesn't look like a phone number."""
    n = "".join(ch for ch in raw if ch not in " -")
    core = n[1:] if n.startswith("+") else n
    if not core.isdigit() or not 10 <= len(core) <= 13:
        return None
    if core.startswith("63") and len(core) == 12:
        return "0" + core[2:]
    return n


@app.get("/api/v1/me")
def get_me(user: User = Depends(current_user)):
    return {"email": user.email, "has_password": bool(user.password_hash)}


@app.post("/api/v1/me/password")
def change_password(body: ChangePasswordBody, background: BackgroundTasks,
                    user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"me-password:{user.id}")
    _require_password(user, body.current_password)
    problem = _password_problem(body.new_password)
    if problem:
        raise HTTPException(422, problem)
    if body.new_password == body.current_password:
        raise HTTPException(422, "Choose a password that's different from your current one")
    user.password_hash = hash_pw(body.new_password)
    db.commit()
    _notify_password_changed(background, db, user, "password change")
    # The new hash ended every login this user had, including the one making this request, so hand back
    # a fresh token for this device. Other devices have to sign in again.
    return {"token": make_token(user)}


@app.post("/api/v1/me/email/start")
def start_email_change(body: EmailChangeBody, background: BackgroundTasks,
                       user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"me-email:{user.id}")
    _require_password(user, body.current_password)
    new_email = body.new_email.strip().lower()
    if "@" not in new_email or "." not in new_email:
        raise HTTPException(422, "Enter a valid email address")
    if new_email == user.email:
        raise HTTPException(422, "That's already your email address")
    if db.scalar(select(User).where(User.email == new_email)):
        raise HTTPException(409, "That email address is already used by another account")
    code = f"{secrets.randbelow(1_000_000):06d}"
    _pending_email_changes[user.id] = (code, time.time() + OTP_TTL_SECONDS, new_email)
    if SMTP_USERNAME:
        # Goes to the NEW address, so only someone who can read it can finish the change.
        background.add_task(_send_notice_email, new_email, "Confirm your new NetPulse email address",
                            f"Your NetPulse code is {code}. It expires in 3 minutes.\n\n"
                            "If you didn't ask to change your email address, you can ignore this email.")
    else:
        print(f"[email change] code for {new_email}: {code}")  # dev-mode fallback: no email provider yet
    return {"ok": True}


@app.post("/api/v1/me/email/confirm")
def confirm_email_change(body: CodeBody, background: BackgroundTasks,
                         user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"me-email-confirm:{user.id}")
    new_email = _check_pending_change(_pending_email_changes, user.id, body.code.strip())
    if not new_email:
        raise HTTPException(400, "Incorrect or expired code")
    if db.scalar(select(User).where(User.email == new_email)):  # someone took it while the code was out
        raise HTTPException(409, "That email address is already used by another account")
    old_email = user.email
    user.email = new_email
    user.email_verified = True  # the code just proved they can read it
    db.commit()
    _queue_notices(
        background, label="email change", email=old_email, mobiles=_linked_mobiles(db, user),
        subject="Your NetPulse email address was changed",
        email_text=f"The email address on your NetPulse account was just changed from {old_email} to "
                   f"{new_email} ({_ph_time_text()}).\n\nIf this was you, no action is needed.\n"
                   "If it wasn't, contact NetPulse support right away.",
        sms_text="NetPulse: the email address on your account was just changed. If this wasn't you, contact support now.",
    )
    return {"email": new_email}


@app.post("/api/v1/accounts/{account_id}/mobile/start")
async def start_mobile_change(body: MobileChangeBody, a: Account = Depends(my_account),
                              user: User = Depends(current_user)):
    rate_limit(f"me-mobile:{user.id}")
    _require_password(user, body.current_password)
    new_mobile = _normalize_mobile(body.new_mobile)
    if not new_mobile:
        raise HTTPException(422, "Enter a valid mobile number")
    if new_mobile == a.mobile:
        raise HTTPException(422, "That's already the mobile number on this account")
    code = f"{secrets.randbelow(1_000_000):06d}"
    if TEXTBEE_API_KEY:
        # Texted to the NEW number, so only someone holding that phone can finish the change.
        try:
            await _deliver_sms_code(new_mobile, code)
        except httpx.HTTPError as e:
            raise HTTPException(502, f"Could not reach the SMS gateway: {e}")
    else:
        print(f"[mobile change] code for {new_mobile}: {code}")  # dev-mode fallback: no SMS gateway yet
    _pending_mobile_changes[(user.id, a.id)] = (code, time.time() + OTP_TTL_SECONDS, new_mobile)
    return {"ok": True}


@app.post("/api/v1/accounts/{account_id}/mobile/confirm")
def confirm_mobile_change(body: CodeBody, background: BackgroundTasks, a: Account = Depends(my_account),
                          user: User = Depends(current_user), db: Session = Depends(get_db)):
    rate_limit(f"me-mobile-confirm:{user.id}")
    new_mobile = _check_pending_change(_pending_mobile_changes, (user.id, a.id), body.code.strip())
    if not new_mobile:
        raise HTTPException(400, "Incorrect or expired code")
    old_mobile = a.mobile
    a.mobile = new_mobile
    db.commit()
    _queue_notices(
        background, label="mobile change", email=user.email, mobiles=[old_mobile],  # the OLD number gets the text
        subject="The mobile number on your NetPulse account was changed",
        email_text=f"The mobile number registered on account {a.account_no} was just changed to {new_mobile} "
                   f"({_ph_time_text()}).\n\nIf this was you, no action is needed.\n"
                   "If it wasn't, contact NetPulse support right away.",
        sms_text=f"NetPulse: the mobile number on account {a.account_no} was just changed. "
                 "If this wasn't you, contact support now.",
    )
    return account_view(a, db)


@app.post("/api/v1/me/delete")
def delete_me(body: DeleteMeBody, background: BackgroundTasks,
              user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Deletes this NetPulse login. The internet accounts it was linked to (bills, payments) belong to the
    provider's records, not to the login, so they stay and can be linked again from a new sign-up."""
    rate_limit(f"me-delete:{user.id}")
    _require_password(user, body.current_password)
    user_id, email = user.id, user.email
    mobiles = _linked_mobiles(db, user)
    for link in db.scalars(select(Link).where(Link.user_id == user_id)).all():
        db.delete(link)
    for req in db.scalars(select(LinkRequest).where(LinkRequest.user_id == user_id)).all():
        db.delete(req)  # the privacy policy promises these go with the login
    db.delete(user)
    db.commit()
    # Forget any codes still waiting for this user.
    _pending_email_changes.pop(user_id, None)
    for key in [k for k in _pending_mobile_changes if k[0] == user_id]:
        _pending_mobile_changes.pop(key, None)
    _pending_reset_otps.pop(email, None)
    _pending_email_otps.pop(email, None)
    _queue_notices(
        background, label="account deletion", email=email, mobiles=mobiles,
        subject="Your NetPulse account was deleted",
        email_text=f"The NetPulse account for {email} was just deleted ({_ph_time_text()}). Your internet "
                   "subscription and billing records are not affected.\n\n"
                   "If this wasn't you, contact NetPulse support right away.",
        sms_text="NetPulse: your account was just deleted. If this wasn't you, contact support now.",
    )
    return {"ok": True}


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
class PaymentStartBody(BaseModel):
    amount: int  # minor units (centavos)
    channel: str  # "email" or "sms" — which verified contact to send the code to


class PaymentConfirmBody(BaseModel):
    code: str


# account_id -> (code, expires_at, amount). The amount is bound to the code at send time so a confirm
# can't complete for a different amount than what was actually verified. Separate dict from the SMS and
# email verification ones above — unrelated flows, shouldn't share a namespace (see the comment on
# _pending_otps).
_pending_payment_otps: dict[int, tuple[str, float, int]] = {}


async def _send_payment_code(a: Account, user: User, channel: str, amount: int) -> None:
    code = f"{secrets.randbelow(1_000_000):06d}"
    if channel == "email":
        if not SMTP_USERNAME:
            raise HTTPException(400, "Email verification isn't configured on this server")
        _deliver_email_code(user.email, code)
    elif channel == "sms":
        if not TEXTBEE_API_KEY:
            raise HTTPException(400, "SMS verification isn't configured on this server")
        await _deliver_sms_code(a.mobile, code)
    else:
        raise HTTPException(422, "channel must be 'email' or 'sms'")
    _pending_payment_otps[a.id] = (code, time.time() + OTP_TTL_SECONDS, amount)


def _check_pending_payment_otp(account_id: int, code: str) -> int | None:
    """Returns the verified amount on a correct, unexpired match (consuming it), else None — same
    expire/consume logic as the other two pending-code checks."""
    pending = _pending_payment_otps.get(account_id)
    if not pending:
        return None
    stored_code, expires_at, amount = pending
    if time.time() >= expires_at:
        _pending_payment_otps.pop(account_id, None)
        return None
    if not hmac.compare_digest(stored_code, code):
        return None
    _pending_payment_otps.pop(account_id, None)
    return amount


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


async def _begin_payment(db: Session, a: Account, amount: int) -> dict:
    """Creates the Payment row and, if PayMongo is configured, a real checkout session. Shared by the
    dev-mode fallback below (no verification channel configured) and the post-code-check confirm step,
    since both end up doing exactly the same thing once they're ready to actually start the payment."""
    payment = Payment(account_id=a.id, amount=amount)
    db.add(payment)
    db.commit()
    db.refresh(payment)

    if not PAYMONGO_SECRET_KEY:
        # Dev-mode fallback: no PAYMONGO_SECRET_KEY configured yet, so keep the old one-tap simulator working.
        return {"payment_id": payment.id, "status": payment.status,
                "checkout_url": f"https://gateway.example/pay/{payment.id}", "real": False}

    plan = db.get(Plan, a.plan_id)
    try:
        session_id, checkout_url = await _create_paymongo_session(payment.id, amount, f"{plan.name} plan bill")
    except httpx.HTTPError as e:
        raise HTTPException(502, f"Could not reach the payment provider: {e}")
    payment.gateway_session_id = session_id
    db.commit()
    return {"payment_id": payment.id, "status": payment.status, "checkout_url": checkout_url, "real": True}


@app.post("/api/v1/accounts/{account_id}/payments/start", status_code=201)
async def start_payment(body: PaymentStartBody, a: Account = Depends(my_account),
                         user: User = Depends(current_user), db: Session = Depends(get_db)):
    if body.amount <= 0:
        raise HTTPException(422, "Amount must be greater than zero")

    if not SMTP_USERNAME and not TEXTBEE_API_KEY:
        # Dev-mode fallback: no verification channel configured yet, so pay immediately like before.
        return {"otp_required": False, **await _begin_payment(db, a, body.amount)}

    rate_limit(f"pay-start:{a.id}")
    await _send_payment_code(a, user, body.channel, body.amount)
    return {"otp_required": True}


@app.post("/api/v1/accounts/{account_id}/payments/confirm", status_code=201)
async def confirm_payment(body: PaymentConfirmBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    rate_limit(f"pay-confirm:{a.id}")
    amount = _check_pending_payment_otp(a.id, body.code)
    if amount is None:
        raise HTTPException(400, "Incorrect or expired code")
    return await _begin_payment(db, a, amount)


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
    """Called by the dev-mode simulator below, never by PayMongo — see /webhooks/paymongo for the real one."""
    if not hmac.compare_digest(x_webhook_secret.encode(), WEBHOOK_SECRET.encode()):
        raise HTTPException(401, "Bad webhook secret")
    payment = db.get(Payment, body.payment_id)
    if not payment:
        raise HTTPException(404, "Unknown payment")
    _mark_paid(db, payment)
    return {"ok": True}


def _paymongo_signature_valid(raw_body: bytes, signature_header: str) -> bool:
    """Verifies a real incoming PayMongo webhook. Per https://developers.paymongo.com/docs/securing-webhook:
    the Paymongo-Signature header is "t=<timestamp>,te=<test sig>,li=<live sig>"; the expected signature is
    HMAC-SHA256 of "{timestamp}.{raw body}" using the webhook's own secret, checked against te for test mode
    (always te here, since this project only ever uses sk_test_ keys) or li for live mode."""
    parts = dict(p.split("=", 1) for p in signature_header.split(",") if "=" in p)
    timestamp, their_signature = parts.get("t"), parts.get("te")
    if not timestamp or not their_signature or not PAYMONGO_WEBHOOK_SECRET:
        return False
    signed_payload = f"{timestamp}.".encode() + raw_body
    expected = hmac.new(PAYMONGO_WEBHOOK_SECRET.encode(), signed_payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, their_signature)


@app.post("/api/v1/webhooks/paymongo")
async def paymongo_webhook(request: Request, db: Session = Depends(get_db)):
    """The real PayMongo webhook. Register this URL under Dashboard > Developers > Webhooks once this
    server has a public address, subscribed to checkout_session.payment.paid. The raw body has to be read
    before any JSON parsing — signature verification is computed over the exact bytes PayMongo sent, and
    re-serializing a parsed body can change whitespace and break the match even when the content is identical."""
    raw_body = await request.body()
    if not _paymongo_signature_valid(raw_body, request.headers.get("paymongo-signature", "")):
        raise HTTPException(401, "Bad webhook signature")

    event = json.loads(raw_body)["data"]
    if event.get("type") == "checkout_session.payment.paid":
        session_id = event["data"]["id"]  # cs_xxx
        payment = db.scalar(select(Payment).where(Payment.gateway_session_id == session_id))
        if payment:
            _mark_paid(db, payment)
    # 2xx for anything else too (events this project doesn't act on) — otherwise PayMongo keeps retrying.
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
    current_password: str


@app.post("/api/v1/accounts/{account_id}/upgrade")
def upgrade_plan(body: UpgradeBody, a: Account = Depends(my_account), user: User = Depends(current_user),
                 db: Session = Depends(get_db)):
    rate_limit(f"me-plan:{user.id}")
    _require_password(user, body.current_password)  # a plan switch changes the bill, so it asks like other changes
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
    current_password: str


class RemoveAddOnBody(BaseModel):
    current_password: str


@app.post("/api/v1/accounts/{account_id}/addons", status_code=201)
def subscribe_addon(body: AddOnBody, a: Account = Depends(my_account), user: User = Depends(current_user),
                    db: Session = Depends(get_db)):
    rate_limit(f"me-addon:{user.id}")
    _require_password(user, body.current_password)
    addon = db.get(AddOn, body.addon_id)
    if not addon:
        raise HTTPException(404, "Add-on not found")
    if db.get(AccountAddOn, (a.id, addon.id)):
        raise HTTPException(409, "Already subscribed to this add-on")
    db.add(AccountAddOn(account_id=a.id, addon_id=addon.id))
    a.balance += addon.monthly_fee  # simplified: added to the current bill rather than prorated to next cycle
    db.commit()
    return account_view(a, db)


@app.post("/api/v1/accounts/{account_id}/addons/{addon_id}/remove")
def unsubscribe_addon(addon_id: int, body: RemoveAddOnBody, a: Account = Depends(my_account),
                      user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Was a body-less DELETE; now a POST so it can carry the password (no password-free route is left)."""
    rate_limit(f"me-addon:{user.id}")
    _require_password(user, body.current_password)
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

    # 0.0.0.0 (not 127.0.0.1) so the API also accepts connections from other devices on the
    # same Wi-Fi, like a real phone during a real-device run — 127.0.0.1 only ever accepts
    # connections from this same PC, which is fine for the emulator (it tunnels 10.0.2.2 back
    # to the PC's own loopback) but not for anything actually out on the network.
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)