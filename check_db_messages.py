import os
import json
from sqlalchemy import create_engine, text
from fit_agent.database import get_database_url

def check_messages():
    engine = create_engine(get_database_url())
    
    with engine.connect() as conn:
        print("\n--- 数据库中的表 ---")
        tables = conn.execute(text("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema';"))
        for t in tables:
            print(f"Table: {t[0]}")
            # 查看表结构
            cols = conn.execute(text(f"SELECT column_name FROM information_schema.columns WHERE table_name = '{t[0]}';"))
            print(f"  Columns: {[c[0] for c in cols]}")

        print("\n--- 尝试查询 checkpoints ---")
        try:
            # LangGraph PostgresSaver 默认列名可能不同，或者没有 created_at
            # 我们先尝试列出最近的 thread_id
            query = text("SELECT thread_id, checkpoint_id FROM checkpoints LIMIT 5;")
            result = conn.execute(query)
            for row in result:
                print(f"Thread ID: {row[0]}, Checkpoint ID: {row[1]}")
        except Exception as e:
            print(f"查询 checkpoints 失败: {e}")

if __name__ == "__main__":
    check_messages()
