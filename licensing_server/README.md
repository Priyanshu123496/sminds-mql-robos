# SMINDS Licensing Server

FastAPI + SQLite licensing backend for `XAUUSD_EMA20_50_200_Buy_H4`.

## Features
- OTP activation (`/api/v1/activate`)
- Token validation (`/api/v1/validate`)
- Admin APIs for create license / generate OTP / revoke / audit
- Account + broker binding
- Configurable `24h` recheck and `72h` offline grace (defaults)
- Basic per-IP rate limiting

## Quick Start
1. Create environment and install dependencies:
   - `python -m venv .venv`
   - `.venv\Scripts\activate`
   - `pip install -r requirements.txt`
2. Copy `.env.example` to `.env` and set strong secrets:
   - `ADMIN_API_KEY`
   - `JWT_SECRET`
3. Start the API:
   - `uvicorn app.main:app --host 0.0.0.0 --port 8000`
4. Confirm health:
   - `GET http://127.0.0.1:8000/health`

## Docker Deployment
1. Copy `.env.example` to `.env` and set secure values.
2. Build and run:
   - `docker compose up -d --build`
3. Check logs:
   - `docker compose logs -f license-api`
4. Data persistence:
   - SQLite is stored in `./data/license.db` (mounted volume).

For first production setup:
- Use HTTPS at your reverse proxy (Nginx/Caddy/Cloudflare Tunnel).
- Restrict admin API access by IP where possible.
- Keep `ADMIN_API_KEY` and `JWT_SECRET` long and random.

## Admin CLI
Use `scripts/admin_cli.py`:

- Create license:
  - `python scripts/admin_cli.py create-license --ea-code XAUUSD_EMA20_50_200_Buy_H4`
- Generate OTP:
  - `python scripts/admin_cli.py generate-otp --license-id <license_id>`
- Revoke:
  - `python scripts/admin_cli.py revoke --license-id <license_id>`
- Audit:
  - `python scripts/admin_cli.py audit --limit 100`

With custom API base:
- `python scripts/admin_cli.py --base-url https://license.yourdomain.com create-license --ea-code XAUUSD_EMA20_50_200_Buy_H4`

Set env vars for convenience:
- `LICENSE_API_BASE`
- `LICENSE_ADMIN_API_KEY`

## Public API Contract
### POST `/api/v1/activate`
Request keys:
- `license_id`
- `otp`
- `account_login`
- `broker_server`
- `ea_code`
- `ea_version`
- `terminal_build`

Response keys:
- `status` (`active` or `denied`)
- `activation_token` (if active)
- `next_check_at_utc` (unix seconds)
- `offline_grace_hours`
- `param_policy`
- `reason` (if denied)

### POST `/api/v1/validate`
Request keys:
- `activation_token`
- `account_login`
- `broker_server`
- `ea_code`
- `ea_version`

Response keys:
- `status` (`active` or `denied`)
- `next_check_at_utc`
- `offline_grace_hours`
- `param_policy`
- `reason` (if denied)

## Security Notes
- Serve behind HTTPS in production.
- Rotate `ADMIN_API_KEY` and `JWT_SECRET`.
- Restrict admin endpoints by network policy where possible.
- This is commercial licensing control, not unbreakable DRM.
- Never distribute `.mq5` to customers. Distribute only `.ex5`.
