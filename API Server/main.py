"""Starter billing API for an internet-subscription app (FastAPI + SQLite).

Run:  uvicorn main:app --reload      Docs / playground:  http://127.0.0.1:8000/docs

Money is stored as whole minor units (centavos), so there are no floating-point errors.
Balance > 0 means the customer owes money; balance < 0 means they have credit.
"""
import hashlib
import hmac
import os
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from sqlalchemy import ForeignKey, String, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

JWT_SECRET = os.getenv("JWT_SECRET", "dev-only-secret-change-before-going-live")
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "dev-webhook-secret")
CURRENCY = "₱"

engine = create_engine("sqlite:///./app.db", connect_args={"check_same_thread": False})
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
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))
    paid_at: Mapped[datetime | None] = mapped_column(default=None)


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("accounts.id"))
    title: Mapped[str]
    body: Mapped[str]
    created_at: Mapped[datetime] = mapped_column(default=lambda: datetime.now(timezone.utc))


def seed() -> None:
    """Create tables and two fake demo accounts (no real customer data)."""
    Base.metadata.create_all(engine)
    with SessionLocal() as db:
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
            ("DEMO-000001", "DEMO, JUAN D.", "5550100001", boost, 99900),  # owes one month
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
    exp = datetime.now(timezone.utc) + timedelta(hours=12)
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
    user = db.scalar(select(User).where(User.email == body.email.strip().lower()))
    if not user or not check_pw(body.password, user.password_hash):
        raise HTTPException(401, "Wrong email or password")
    return {"token": make_token(user.id)}


# ---------- accounts ----------
class LinkBody(BaseModel):
    account_no: str
    mobile: str  # must match the number on file (replace with an SMS one-time code in production)


@app.post("/api/v1/accounts/link", status_code=201)
def link_account(body: LinkBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    acct = db.scalar(select(Account).where(Account.account_no == body.account_no))
    if not acct or acct.mobile != body.mobile:
        raise HTTPException(404, "No matching account")
    if not db.get(Link, (user.id, acct.id)):
        db.add(Link(user_id=user.id, account_id=acct.id))
        db.commit()
    return account_view(acct, db)


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


@app.post("/api/v1/accounts/{account_id}/payments", status_code=201)
def start_payment(body: PayBody, a: Account = Depends(my_account), db: Session = Depends(get_db)):
    if body.amount <= 0:
        raise HTTPException(422, "Amount must be greater than zero")
    payment = Payment(account_id=a.id, amount=body.amount)
    db.add(payment)
    db.commit()
    # TODO: create a checkout session with your payment gateway here and return its real URL.
    return {"payment_id": payment.id, "status": payment.status, "checkout_url": f"https://gateway.example/pay/{payment.id}"}


class WebhookBody(BaseModel):
    payment_id: int


@app.post("/api/v1/webhooks/payments")
def payment_webhook(body: WebhookBody, x_webhook_secret: str = Header(""), db: Session = Depends(get_db)):
    """Called by the payment gateway, never by the app. Real gateways sign the body; verify that instead."""
    if not hmac.compare_digest(x_webhook_secret.encode(), WEBHOOK_SECRET.encode()):
        raise HTTPException(401, "Bad webhook secret")
    payment = db.get(Payment, body.payment_id)
    if not payment:
        raise HTTPException(404, "Unknown payment")
    if payment.status != "PAID":  # idempotent: a repeated webhook changes nothing
        payment.status, payment.paid_at = "PAID", datetime.now(timezone.utc)
        acct = db.get(Account, payment.account_id)
        acct.balance -= payment.amount
        db.add(Notification(account_id=acct.id, title="Payment received",
                            body=f"We received {CURRENCY}{payment.amount / 100:,.2f}. Thank you!"))
        db.commit()
    return {"ok": True}


DEV_MODE = os.getenv("DEV_MODE", "1") == "1"  # set DEV_MODE=0 before going live

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
