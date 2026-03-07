"""Database models and session for fit-agent."""

from datetime import datetime
from uuid import uuid4

from sqlalchemy import DateTime, Integer, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base class for all models."""

    pass


class User(Base):
    """用户表。id 作为外键被其他表引用（如 thread_user、workout 等）。"""

    __tablename__ = "users"

    id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        primary_key=True,
        default=lambda: str(uuid4()),
    )
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
    active_thread_id: Mapped[str | None] = mapped_column(String(255), nullable=True)


class MemorySummary(Base):
    """每个用户的长期摘要与关键事实。"""

    __tablename__ = "memory_summaries"

    user_id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True)
    summary_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    key_facts: Mapped[dict | list | None] = mapped_column(JSONB, nullable=True)
    scenarios: Mapped[dict | list | None] = mapped_column(JSONB, nullable=True)
    global_background: Mapped[str | None] = mapped_column(Text, nullable=True)
    meta_data: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class MessageMemory(Base):
    """消息打分与遗忘状态（旁路表）。"""

    __tablename__ = "message_memory"

    id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        primary_key=True,
        default=lambda: str(uuid4()),
    )
    user_id: Mapped[str] = mapped_column(UUID(as_uuid=False), nullable=False, index=True)
    message_id: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    content: Mapped[str | None] = mapped_column(Text, nullable=True)
    importance_score: Mapped[int] = mapped_column(Integer, default=3, nullable=False)
    memory_state: Mapped[str] = mapped_column(String(16), default="active", nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
