"""智谱 GLM 模型加载（Zhipu AI / ChatZhipuAI）。"""

from langchain_community.chat_models.zhipuai import ChatZhipuAI
from langchain_core.language_models import BaseChatModel


def load_zhipu_model(model: str) -> BaseChatModel:
    """加载智谱 GLM 聊天模型。

    Args:
        model: 模型名称，如 glm-4、glm-4-flash、glm-4-plus 等。
           参见 https://open.bigmodel.cn/dev/api

    Returns:
        ChatZhipuAI 实例。需设置环境变量 ZHIPUAI_API_KEY。
    """
    return ChatZhipuAI(model=model)
