import time
from collections import defaultdict

from fastapi import HTTPException, Request, status

from .config import settings

_REQUEST_BUCKETS: dict[str, list[float]] = defaultdict(list)


def require_rate_limit(request: Request) -> None:
    client = request.client.host if request.client else "unknown"
    now = time.time()
    window_start = now - settings.rate_limit_window_seconds
    bucket = _REQUEST_BUCKETS[client]
    bucket[:] = [ts for ts in bucket if ts >= window_start]
    if len(bucket) >= settings.rate_limit_max_requests:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded",
        )
    bucket.append(now)
