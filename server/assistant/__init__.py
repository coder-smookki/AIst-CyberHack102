"""Помощник инженера: ответы на вопросы об оборудовании и истории осмотров со ссылками для приложения."""

from server.assistant.intents import Reply, answer, deeplink
from server.assistant.router import router

__all__ = ["Reply", "answer", "deeplink", "router"]
