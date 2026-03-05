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

---

## 4. iOS 原生流式输出性能与显示优化

**现象**：
1. 发送消息后，CPU 飙升至 99%，App 严重发烫卡顿。
2. 流式输出不顺滑，文字“一坨一坨”蹦出，或者在 Tool 调用时出现旧消息“回闪”。
3. 即使后端已回复，UI 仍显示“思考中”或无响应。

**原因**：
1. **逐字节处理瓶颈**：在 `URLSession.bytes` 循环中直接进行 `String` 拼接（O(n^2) 操作），每收到一个字节就触发一次全量字符串转换和 UI 刷新。
2. **主线程解析阻塞**：JSON 反序列化和复杂的字符串清洗（如剔除 `</think>` 思考过程）在主线程执行，阻塞了渲染管线。
3. **SSE 协议理解偏差**：未利用 SSE 的换行符 `\n` 作为数据包边界，导致解析了大量不完整的 JSON 片段。
4. **全量快照干扰**：Aegra/LangGraph 的 `values` 事件返回全量历史记录，若不加过滤直接取“最后一条”，会导致 Tool 调用期间显示旧消息。

**解决方案**：
1. **字节缓冲区 (Data Buffer)**：使用 `Data` 收集原始字节，仅在探测到 `\n`（ASCII 10）时才进行字符串转换，降低 95% 以上的转换频率。
2. **异步解析 (Background Task)**：使用 `Task.detached` 将解析逻辑移出读取循环，在后台线程完成 JSON 解析和 `</think>` 过滤。
3. **差异化刷新**：在切回 `MainActor` 前对比内容是否有实质变化，避免无效的 SwiftUI 重绘。
4. **消息过滤**：针对 `values` 事件，显式过滤 `type: "ai"` 且只提取当前活跃的消息内容。

**教训**：
处理流式数据时，**“接货”与“理货”必须分离**。读取循环只负责最快速的字节收集，复杂的逻辑必须异步化，且必须以数据包（行）为单位进行处理，严禁逐字节操作字符串。
