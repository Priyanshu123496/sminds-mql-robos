# XAUUSD EA Customer Release Checklist

## 1) Pre-Release Security Checks
- Confirm you will distribute only:
  - `XAUUSD_EMA20_50_200_Buy_H4.ex5`
- Do not include:
  - `.mq5`, compile logs, tester reports, internal config files
- Confirm `InpAllowTradingWithoutLicense=false` in your shared `.set` template.

## 2) Build and Validate EA Artifact
- Compile EA from:
  - `mt5/experts/XAUUSD_EMA20_50_200_Buy_H4.mq5`
- Verify compile result:
  - `0 errors, 0 warnings`
- Keep version tag and build date in your internal release log.

## 3) Provision License + OTP
Run from `licensing_server`:

1. Create license:
   - `python scripts/admin_cli.py create-license --ea-code XAUUSD_EMA20_50_200_Buy_H4 --license-id <customer_license_id> --lot-min 0.10 --lot-max 2.00 --lot-step 0.10`
2. Generate OTP:
   - `python scripts/admin_cli.py generate-otp --license-id <customer_license_id>`
3. Record securely:
   - `license_id`
   - `otp`
   - lot limits issued
   - expiry (if used)

## 4) Build Customer Package
Use packager script:
- `powershell -ExecutionPolicy Bypass -File mt5/scripts/build_customer_package.ps1 -CustomerId <customer_id> -LicenseApiBase https://license.yourdomain.com`

Generated package location:
- `mt5/releases/<customer_id>/XAUUSD_EMA20_50_200_Buy_H4_<customer_id>.zip`

Package contains:
- `XAUUSD_EMA20_50_200_Buy_H4.ex5`
- `XAUUSD_EMA20_50_200_Buy_H4.set` (template)
- `README_XAUUSD_LICENSING.md`

## 5) Delivery Instructions to Customer
- Copy `.ex5` into `MQL5/Experts`.
- Add API host to MT5 WebRequest allowlist.
- Attach EA to `XAUUSD` on `H4`.
- Fill inputs:
  - `InpLicenseId`
  - `InpOtp`
  - `InpLicenseApiBase`
  - `InpLotSize` (must be inside issued policy range)

## 6) Post-Delivery Validation
- Ask customer for first activation timestamp and account/broker details.
- Check audit:
  - `python scripts/admin_cli.py audit --limit 100`
- Confirm:
  - activation success
  - no bind mismatch
  - no repeated OTP failures

## 7) Incident / Revocation
- Revoke compromised license:
  - `python scripts/admin_cli.py revoke --license-id <customer_license_id>`
- Reissue:
  - create new license or regenerate OTP policy as required.
