"""migrate message_hash to message_id and remove embedding

Revision ID: 20260307_message_id
Revises: 20260307_memory_meta
Create Date: 2026-03-07

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "20260307_message_id"
down_revision: Union[str, Sequence[str], None] = "20260307_memory_meta"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. 修改 message_memory 表
    op.add_column("message_memory", sa.Column("message_id", sa.String(length=255), nullable=True))
    # 将现有的哈希值暂时迁移到新列（虽然 ID 不同，但为了不破坏现有结构）
    # 实际上由于我们要改用 ID 关联，旧的哈希数据可能不再匹配，但这里先做结构变更
    op.execute("UPDATE message_memory SET message_id = message_hash")
    op.alter_column("message_memory", "message_id", nullable=False)
    
    # 2. 移除旧列
    op.drop_constraint("uq_message_memory_user_hash", "message_memory", type_="unique")
    op.drop_index("ix_message_memory_message_hash", table_name="message_memory")
    op.drop_column("message_memory", "message_hash")
    op.drop_column("message_memory", "embedding")
    
    # 3. 创建新索引和约束
    op.create_index(op.f("ix_message_memory_message_id"), "message_memory", ["message_id"], unique=False)
    op.create_unique_constraint("uq_message_memory_user_id", "message_memory", ["user_id", "message_id"])


def downgrade() -> None:
    op.add_column("message_memory", sa.Column("embedding", postgresql.JSONB(astext_type=sa.Text()), autoincrement=False, nullable=True))
    op.add_column("message_memory", sa.Column("message_hash", sa.String(length=64), autoincrement=False, nullable=False))
    op.drop_constraint("uq_message_memory_user_id", "message_memory", type_="unique")
    op.drop_index(op.f("ix_message_memory_message_id"), table_name="message_memory")
    op.create_index("ix_message_memory_message_hash", "message_memory", ["message_hash"], unique=False)
    op.create_unique_constraint("uq_message_memory_user_hash", "message_memory", ["user_id", "message_hash"])
    op.drop_column("message_memory", "message_id")
