"""
Custom middleware for the proj_mes_voice project.
"""


class AllowNgrokMiddleware:
    """Pass-through middleware kept for MIDDLEWARE-list compatibility.

    The previous implementation appended the request host to
    `settings.ALLOWED_HOSTS` and `settings.CSRF_TRUSTED_ORIGINS` at runtime
    whenever the host ended with `.ngrok.app`/`.ngrok.io`/etc. Two problems
    with that:

    1. **Mutation of global settings under concurrency is unsafe.** With
       gunicorn's multi-worker model, two requests on different workers can
       race the `if x not in lst: lst.append(x)` check-then-modify pair —
       not a security issue (the values written are already known-safe ngrok
       host strings), but the list grows unbounded across the lifetime of
       a worker, and the mutation can be observed by other in-flight
       handlers in surprising ways.

    2. **It didn't actually do anything useful.** Django disables
       `ALLOWED_HOSTS` validation when `DEBUG=True` (`HttpRequest.get_host`
       short-circuits to skip the check), so the append-on-each-request
       loop runs but never gates anything. On `DEBUG=False` the guard
       (`if settings.DEBUG:`) skipped the whole block, so no mutation
       happened either. Net effect: dead code that grew a list nobody read.

    Kept as a no-op so existing `MIDDLEWARE` entries in `settings.py` still
    resolve. Safe to drop entirely once that entry is removed.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        return self.get_response(request)
