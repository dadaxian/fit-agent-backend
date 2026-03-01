"""Utility functions for fit-agent."""

from langchain.chat_models import init_chat_model
from langchain_core.language_models import BaseChatModel

from fit_agent._zhipu import load_zhipu_model


def load_chat_model(fully_specified_name: str) -> BaseChatModel:
    """Load a chat model from a fully specified name.

    Args:
        fully_specified_name: String in the format 'provider/model'
            e.g. 'openai/gpt-4o-mini', 'anthropic/claude-sonnet-4-20250514',
            'zhipuai/glm-4-flash' (智谱 GLM).

    Returns:
        A BaseChatModel instance.

    Raises:
        ValueError: If fully_specified_name is not in 'provider/model' format.
    """
    if not fully_specified_name or not fully_specified_name.strip():
        raise ValueError("fully_specified_name must be in 'provider/model' format, got empty string")
    if fully_specified_name.count("/") != 1:
        raise ValueError(
            f"fully_specified_name must be in 'provider/model' format, got '{fully_specified_name}'"
        )
    provider, model = fully_specified_name.split("/", maxsplit=1)
    if not provider.strip() or not model.strip():
        raise ValueError(
            f"fully_specified_name must be in 'provider/model' format, got '{fully_specified_name}'"
        )
    if provider.strip().lower() == "zhipuai":
        return load_zhipu_model(model.strip())
    return init_chat_model(model, model_provider=provider)
