"""智谱 GLM 模型加载（Zhipu AI / ChatZhipuAI）。"""

from typing import Any, Dict

from langchain_community.chat_models.zhipuai import ChatZhipuAI
from langchain_core.language_models import BaseChatModel


class FitZhipuAI(ChatZhipuAI):
    """智谱模型，默认关闭 thinking 以加快响应。"""

    @property
    def _default_params(self) -> Dict[str, Any]:
        params = super()._default_params
        # 关闭 thinking 模式，加快 tool calling 等场景的响应
        params["thinking"] = {"type": "disabled"}
        return params


def load_zhipu_model(model: str) -> BaseChatModel:
    """加载智谱 GLM 聊天模型。

    Args:
        model: 模型名称，如 glm-4、glm-4-flash、glm-4.7-flash 等。
           参见 https://open.bigmodel.cn/dev/api

    Returns:
        FitZhipuAI 实例（默认关闭 thinking）。需设置环境变量 ZHIPUAI_API_KEY。
    """
    return FitZhipuAI(model=model)
