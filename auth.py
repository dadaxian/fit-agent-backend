"""
Aegra 认证：JWT 验证，返回 identity=user_id 供 LangGraph 使用。
配置：aegra.json 中 "auth": {"path": "./auth.py:auth"}
"""
import os

from langgraph_sdk import Auth

auth = Auth()

JWT_SECRET = os.environ.get("JWT_SECRET", "change-me-in-production")
if not JWT_SECRET or JWT_SECRET == "change-me-in-production":
    import warnings
    warnings.warn("JWT_SECRET 未设置，请设置环境变量 JWT_SECRET")


def decode_jwt_user_id(token: str) -> str | None:
    """解析 JWT，返回 user_id（sub）。供 custom_routes 等复用。"""
    import jwt
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
        return payload.get("sub")
    except Exception:
        return None


def _decode_jwt(token: str) -> str | None:
    return decode_jwt_user_id(token)


@auth.authenticate
async def authenticate(headers: dict) -> dict:
    """验证 JWT，返回 identity=user_id。"""
    auth_header = headers.get("Authorization") or headers.get("authorization") or ""
    token = auth_header.replace("Bearer ", "").strip()
    if not token:
        raise Exception("缺少 Authorization 头，请先登录（POST /auth/login）")

    user_id = _decode_jwt(token)
    if not user_id:
        raise Exception("Token 无效或已过期，请重新登录")

    return {
        "identity": user_id,
        "display_name": None,
        "permissions": [],
        "is_authenticated": True,
    }
