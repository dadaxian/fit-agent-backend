"""add memory_summaries and message_memory tables

Revision ID: 20260306_memory_tables
Revises: 20260303_active_thread
Create Date: 2026-03-06

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "20260306_memory_tables"
down_revision: Union[str, Sequence[str], None] = "20260303_active_thread"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "memory_summaries",
        sa.Column("user_id", UUID(as_uuid=False), primary_key=True),
        sa.Column("summary_text", sa.Text(), nullable=True),
        sa.Column("key_facts", JSONB, nullable=True),
        sa.Column("last_message_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )

    op.create_table(
        "message_memory",
        sa.Column("id", UUID(as_uuid=False), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=False), nullable=False, index=True),
        sa.Column("message_hash", sa.String(length=64), nullable=False, index=True),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("content", sa.Text(), nullable=True),
        sa.Column("importance_score", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("memory_state", sa.String(length=16), nullable=False, server_default="active"),
        sa.Column("embedding", JSONB, nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )

    op.create_unique_constraint(
        "uq_message_memory_user_hash", "message_memory", ["user_id", "message_hash"]
    )


def downgrade() -> None:
    op.drop_constraint("uq_message_memory_user_hash", "message_memory", type_="unique")
    op.drop_table("message_memory")
    op.drop_table("memory_summaries")
