"""Database session for fit-agent. Uses sync engine (Alembic/migrations use sync)."""

import os
from contextlib import contextmanager
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from fit_agent.db import Base

_USER = os.environ.get("POSTGRES_USER", "postgres")
_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
_HOST = os.environ.get("POSTGRES_HOST", "localhost")
_PORT = os.environ.get("POSTGRES_PORT", "5432")
_DB = os.environ.get("POSTGRES_DB", "fit_agent")


def get_database_url() -> str:
    """Build database URL from environment."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    return f"postgresql+psycopg://{_USER}:{_PASSWORD}@{_HOST}:{_PORT}/{_DB}"


engine = create_engine(
    get_database_url(),
    pool_pre_ping=True,
    echo=os.environ.get("DB_ECHO_LOG", "").lower() == "true",
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


@contextmanager
def get_db() -> Generator[Session, None, None]:
    """Context manager for database session."""
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
