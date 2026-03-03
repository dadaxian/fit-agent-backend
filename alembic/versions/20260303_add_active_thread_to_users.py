"""add active_thread_id to users, migrate from user_threads, drop user_threads

Revision ID: 20260303_active_thread
Revises: 20260303_user_threads
Create Date: 2026-03-03

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260303_active_thread"
down_revision: Union[str, Sequence[str], None] = "20260303_user_threads"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("active_thread_id", sa.String(length=255), nullable=True))

    # 从 user_threads 迁移已有数据到 users
    op.execute("""
        UPDATE users u
        SET active_thread_id = ut.thread_id
        FROM user_threads ut
        WHERE u.id = ut.user_id
    """)

    op.drop_table("user_threads")


def downgrade() -> None:
    op.create_table(
        "user_threads",
        sa.Column("user_id", sa.UUID(as_uuid=False), nullable=False),
        sa.Column("thread_id", sa.String(length=255), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("user_id"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.execute("""
        INSERT INTO user_threads (user_id, thread_id)
        SELECT id, active_thread_id FROM users WHERE active_thread_id IS NOT NULL
    """)
    op.drop_column("users", "active_thread_id")
