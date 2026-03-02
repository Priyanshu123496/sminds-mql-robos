import argparse
import json
import os
from datetime import datetime, timezone

import requests


def iso_to_dt(value: str) -> str:
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def headers(admin_api_key: str) -> dict:
    return {"x-admin-api-key": admin_api_key, "Content-Type": "application/json"}


def request_json(method: str, url: str, admin_api_key: str, payload: dict | None = None) -> dict:
    response = requests.request(
        method=method,
        url=url,
        headers=headers(admin_api_key),
        json=payload,
        timeout=20,
    )
    response.raise_for_status()
    return response.json()


def cmd_create_license(args: argparse.Namespace) -> None:
    payload = {
        "license_id": args.license_id,
        "ea_code": args.ea_code,
        "lot_min": args.lot_min,
        "lot_max": args.lot_max,
        "lot_step": args.lot_step,
        "bind_mode": "account_server",
        "status": "active",
    }
    if args.expires_at:
        payload["expires_at"] = iso_to_dt(args.expires_at)
    data = request_json("POST", f"{args.base_url}/api/v1/admin/licenses", args.admin_api_key, payload)
    print(json.dumps(data, indent=2))


def cmd_generate_otp(args: argparse.Namespace) -> None:
    payload = {"license_id": args.license_id}
    if args.ttl_seconds:
        payload["ttl_seconds"] = args.ttl_seconds
    data = request_json("POST", f"{args.base_url}/api/v1/admin/otp/generate", args.admin_api_key, payload)
    print(json.dumps(data, indent=2))


def cmd_revoke(args: argparse.Namespace) -> None:
    data = request_json("POST", f"{args.base_url}/api/v1/admin/licenses/{args.license_id}/revoke", args.admin_api_key)
    print(json.dumps(data, indent=2))


def cmd_audit(args: argparse.Namespace) -> None:
    response = requests.get(
        f"{args.base_url}/api/v1/admin/audit",
        headers=headers(args.admin_api_key),
        params={"limit": args.limit},
        timeout=20,
    )
    response.raise_for_status()
    print(json.dumps(response.json(), indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="SMINDS licensing admin CLI")
    parser.add_argument("--base-url", default=os.getenv("LICENSE_API_BASE", "http://127.0.0.1:8000"))
    parser.add_argument("--admin-api-key", default=os.getenv("LICENSE_ADMIN_API_KEY", "change-me"))

    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create-license", help="Create a new license")
    create_parser.add_argument("--license-id", default=None)
    create_parser.add_argument("--ea-code", required=True)
    create_parser.add_argument("--lot-min", type=float, default=0.01)
    create_parser.add_argument("--lot-max", type=float, default=100.0)
    create_parser.add_argument("--lot-step", type=float, default=0.01)
    create_parser.add_argument("--expires-at", default=None, help="ISO datetime e.g. 2026-12-31T23:59:59+00:00")
    create_parser.set_defaults(func=cmd_create_license)

    otp_parser = subparsers.add_parser("generate-otp", help="Generate one-time OTP")
    otp_parser.add_argument("--license-id", required=True)
    otp_parser.add_argument("--ttl-seconds", type=int, default=None)
    otp_parser.set_defaults(func=cmd_generate_otp)

    revoke_parser = subparsers.add_parser("revoke", help="Revoke a license")
    revoke_parser.add_argument("--license-id", required=True)
    revoke_parser.set_defaults(func=cmd_revoke)

    audit_parser = subparsers.add_parser("audit", help="List recent audit entries")
    audit_parser.add_argument("--limit", type=int, default=50)
    audit_parser.set_defaults(func=cmd_audit)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
