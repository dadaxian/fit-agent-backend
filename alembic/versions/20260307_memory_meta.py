"""remove last_message_count and add meta_data to memory_summaries

Revision ID: 20260307_memory_meta
Revises: 20260307_add_scenarios
Create Date: 2026-03-07

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "20260307_memory_meta"
down_revision: Union[str, Sequence[str], None] = "20260307_add_scenarios"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("memory_summaries", sa.Column("meta_data", JSONB, nullable=True))
    op.drop_column("memory_summaries", "last_message_count")


def downgrade() -> None:
    op.add_column("memory_summaries", sa.Column("last_message_count", sa.Integer(), server_default="0", nullable=False))
    op.drop_column("memory_summaries", "meta_data")
