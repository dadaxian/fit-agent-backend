"""GLM 模型调用测试。运行: uv run python test_glm.py"""

import asyncio

from langchain_core.messages import HumanMessage

from fit_agent.utils import load_chat_model

import dotenv
dotenv.load_dotenv()
async def main() -> None:
    model = load_chat_model("zhipuai/glm-4.7-flash")
    response = await model.ainvoke([HumanMessage(content="你好，请用一句话介绍你自己。")])
    print("回复:", response.content)


if __name__ == "__main__":
    asyncio.run(main())
