from ..i18n import register
from .base import Buy, Context, Decision, MarketView, Param, Position, Sell, Strategy
from .dip import DipStrategy
from .others import DcaStrategy, PriceZoneStrategy, ReboundTrailingStrategy

STRATEGIES: dict[str, Strategy] = {
    s.key: s for s in (DipStrategy(), ReboundTrailingStrategy(), PriceZoneStrategy(), DcaStrategy())
}

# strategy names can be used as message arguments, e.g. m("event.bot_created", strategy=m("strategy.dip"))
for _strategy in STRATEGIES.values():
    register(f"strategy.{_strategy.key}", _strategy.name)

__all__ = [
    "STRATEGIES",
    "Buy",
    "Context",
    "Decision",
    "MarketView",
    "Param",
    "Position",
    "Sell",
    "Strategy",
]
