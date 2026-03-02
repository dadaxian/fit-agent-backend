# 经验教训（踩坑记录）

记录开发过程中遇到的坑及解决方案，避免重复浪费时间。

---

## 1. SQLAlchemy DetachedInstanceError：session 关闭后访问 ORM 对象

**现象**：`DetachedInstanceError: Instance <User at 0x...> is not bound to a Session; attribute refresh operation cannot proceed`

**原因**：`with get_db() as db` 结束后，session 被关闭，`user` 等 ORM 对象变为 detached。在 `with` 块**外**访问 `user.id` 等属性时，SQLAlchemy 尝试 lazy-load，但 session 已不存在。

**错误写法**：
```python
with get_db() as db:
    user = create_user(db, req.email, req.password, req.display_name)
return {"access_token": create_access_token(user.id), ...}  # ❌ user 已 detached
```

**正确写法**：在 session 仍有效时**提前取出**需要的属性：
```python
with get_db() as db:
    user = create_user(db, req.email, req.password, req.display_name)
    user_id = user.id
    user_email = user.email
        # ...
return {"access_token": create_access_token(user_id), ...}  # ✅ 用局部变量
```

**教训**：使用 `with get_db()` 时，如需在块外使用 ORM 对象，必须在块内把属性读出来再返回。

---

## 2. bcrypt 密码长度限制：72 字节

**现象**：`password cannot be longer than 72 bytes, truncate manually if necessary`

**原因**：bcrypt 算法对输入有硬性限制，最多 72 字节。超长密码会报错。

**可选方案**：
- 方案 A：注册时对密码做 `password[:72]` 截断（不推荐，会改变用户意图）
- 方案 B：先对密码做 SHA256 哈希再传给 bcrypt（常见做法）
- 方案 C：临时用明文存储（仅开发/内部环境，生产禁用）

**教训**：若用 bcrypt，需在 hash 前处理超长密码；或改用其他无此限制的库。

---

## 3. JWT_SECRET 未设置

**现象**：auth 不生效或 token 验证失败。

**原因**：`auth.py` 和 `auth_service` 依赖 `JWT_SECRET` 生成/验证 token。未设置时使用默认值，存在安全风险。

**解决**：在 `.env` 中设置随机密钥：
```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
# 将输出写入 .env 的 JWT_SECRET=
```

**教训**：涉及 auth 的配置要尽早检查，避免调试时才发现未配置。
