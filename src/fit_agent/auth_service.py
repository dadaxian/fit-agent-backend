"""Auth service: register, login, JWT. 密码明文存储（简化版，生产环境请改用哈希）。"""

import os
from uuid import uuid4

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from fit_agent.db import User
from fit_agent.database import get_db

JWT_SECRET = os.environ.get("JWT_SECRET", "change-me-in-production")
JWT_ALGORITHM = "HS256"
JWT_EXPIRATION_HOURS = 24 * 7  # 7 days


def create_user(db: Session, email: str, password: str, display_name: str | None = None) -> User:
    """注册新用户。密码明文存储。"""
    if db.scalar(select(User).where(User.email == email)):
        raise ValueError("邮箱已被注册")
    user = User(
        id=str(uuid4()),
        email=email,
        password_hash=password,  # 明文存储
        display_name=display_name,
    )
    db.add(user)
    db.flush()  # 获取 id 等，由调用方 commit
    return user


def authenticate_user(db: Session, email: str, password: str) -> User | None:
    """验证邮箱密码，返回用户或 None。明文比对。"""
    user = db.scalar(select(User).where(User.email == email))
    if not user or user.password_hash != password:
        return None
    return user


def create_access_token(user_id: str) -> str:
    """生成 JWT access token。"""
    import datetime

    exp = datetime.datetime.now(datetime.UTC) + datetime.timedelta(hours=JWT_EXPIRATION_HOURS)
    return jwt.encode(
        {"sub": user_id, "exp": exp},
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )


def decode_token(token: str) -> str | None:
    """解码 JWT，返回 user_id 或 None。"""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload.get("sub")
    except jwt.PyJWTError:
        return None


def get_user_by_id(db: Session, user_id: str) -> User | None:
    """按 id 查询用户。"""
    return db.scalar(select(User).where(User.id == user_id))
