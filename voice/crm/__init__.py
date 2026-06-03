"""
CRM abstraction layer.

Usage:
    from voice.crm import get_crm_provider
    crm = get_crm_provider()
    client = crm.search_client_by_domain('acme.com')
"""

import logging

from decouple import config

from .base import CRMProvider
from .pipedrive import PipedriveProvider

logger = logging.getLogger(__name__)

CRM_PROVIDERS = {
    "pipedrive": PipedriveProvider,
}

_cached_provider = None


def get_crm_provider() -> CRMProvider:
    """
    Return the configured CRM provider instance.

    Reads CRM_PROVIDER from settings (.env), defaults to 'pipedrive'.
    Instance is cached for the process lifetime.
    """
    global _cached_provider
    if _cached_provider is not None:
        return _cached_provider

    provider_name = config("CRM_PROVIDER", default="pipedrive").lower()
    provider_cls = CRM_PROVIDERS.get(provider_name)
    if provider_cls is None:
        raise ValueError(
            f"Unknown CRM provider '{provider_name}'. Available: {', '.join(CRM_PROVIDERS.keys())}"
        )
    _cached_provider = provider_cls()
    logger.info(f"CRM provider initialized: {provider_name}")
    return _cached_provider
