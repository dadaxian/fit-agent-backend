#!/usr/bin/env -S uv run python
"""
为现有用户初始化 active_thread_id：对 active_thread_id 为空的用户创建 thread 并写入。
需先启动 Aegra（aegra dev），确保 AEGRA_BASE_URL 可访问。
用法：uv run python scripts/init_user_threads.py
"""
import os
import sys

# 确保 src 在 path 中
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import httpx
from fit_agent.database import get_db
from fit_agent.db import User

AEGRA_BASE = os.environ.get("AEGRA_BASE_URL", "http://127.0.0.1:8000").rstrip("/")


def main():
    with get_db() as db:
        users = db.query(User).filter(User.active_thread_id.is_(None)).all()
        if not users:
            print("没有需要初始化的用户（active_thread_id 均已设置）")
            return

        print(f"为 {len(users)} 个用户初始化 active_thread_id...")
        with httpx.Client(timeout=10.0) as client:
            for user in users:
                try:
                    # 先登录获取 token（当前密码明文存储）
                    login_r = client.post(
                        f"{AEGRA_BASE}/auth/login",
                        json={"email": user.email, "password": user.password_hash},
                        headers={"Content-Type": "application/json"},
                    )
                    if login_r.status_code != 200:
                        print(f"  用户 {user.email}: 登录失败 {login_r.status_code}，跳过")
                        continue
                    token = login_r.json().get("access_token")
                    if not token:
                        print(f"  用户 {user.email}: 登录返回无 token，跳过")
                        continue

                    r = client.post(
                        f"{AEGRA_BASE}/threads",
                        json={},
                        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
                    )
                    if r.status_code not in (200, 201):
                        print(f"  用户 {user.email}: 创建 thread 失败 {r.status_code} {r.text[:100]}")
                        continue
                    data = r.json()
                    thread_id = data.get("thread_id")
                    if not thread_id:
                        print(f"  用户 {user.email}: 返回格式异常")
                        continue
                    user.active_thread_id = thread_id
                    print(f"  用户 {user.email}: thread_id={thread_id[:8]}...")
                except Exception as e:
                    print(f"  用户 {user.email}: {e}")
        print("完成")


if __name__ == "__main__":
    main()
