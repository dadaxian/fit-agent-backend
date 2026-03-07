"""add scenarios and global_background to memory_summaries

Revision ID: 20260307_add_scenarios
Revises: 20260306_memory_tables
Create Date: 2026-03-07

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "20260307_add_scenarios"
down_revision: Union[str, Sequence[str], None] = "20260306_memory_tables"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("memory_summaries", sa.Column("scenarios", JSONB, nullable=True))
    op.add_column("memory_summaries", sa.Column("global_background", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("memory_summaries", "global_background")
    op.drop_column("memory_summaries", "scenarios")
