"""Create the first staff admin for the NetPulse dashboard.

Run from the API Server folder (next to main.py):    python create_admin.py
Run it again any time to add another admin or to reset a forgotten admin password.
"""
import getpass
import sys

import main


def ask(label):
    value = input(label).strip()
    if not value:
        sys.exit("Cancelled: that can't be empty.")
    return value


def main_cli():
    main.seed()  # makes sure the tables exist
    email = ask("Staff email: ").lower()
    with main.SessionLocal() as db:
        existing = db.query(main.Staff).filter(main.Staff.email == email).first()
        name = existing.name if existing else ask("Full name: ")
        password = getpass.getpass("Password (10+ chars, a capital letter and a number): ")
        problem = main._staff_password_problem(password)
        if problem:
            sys.exit(f"Not saved: {problem}")
        if password != getpass.getpass("Confirm password: "):
            sys.exit("Not saved: the passwords didn't match.")
        if existing:
            existing.password_hash = main.hash_pw(password)
            existing.role, existing.active = "admin", True
            action = "updated (admin, active, new password)"
        else:
            db.add(main.Staff(email=email, name=name, password_hash=main.hash_pw(password), role="admin", active=True))
            action = "created"
        db.commit()
    print(f"Staff admin {email} {action}. Sign in at /staff/ on your server.")


if __name__ == "__main__":
    main_cli()
