# XAUUSD EMA EA Licensing Guide

## What to Distribute
- Share only the compiled file:
  - `XAUUSD_EMA20_50_200_Buy_H4.ex5`
- Do not share `.mq5` source.

## Required MT5 Setup
In MT5 terminal:
1. `Tools` -> `Options` -> `Expert Advisors`
2. Enable `Allow WebRequest for listed URL`
3. Add your license API host, for example:
   - `https://license.yourdomain.com`

## User Inputs
The EA now expects:
- `InpLotSize`
- `InpLicenseId`
- `InpOtp` (for first activation)
- `InpLicenseApiBase`
- `InpAllowTradingWithoutLicense` (keep `false` in production)

## Activation Flow
1. User attaches EA to `XAUUSD` on `H4`.
2. User enters `InpLicenseId`, `InpOtp`, and API base URL.
3. EA calls `/api/v1/activate`.
4. On success, EA stores activation state in terminal common files:
   - `sminds_license_xauusd.json`
5. EA validates every 24 hours with `/api/v1/validate`.
6. If API is down, EA uses cached validity up to 72 hours.

## License Enforcement
- Binding: `AccountLogin + BrokerServer`
- Policy lock:
  - symbol = `XAUUSD`
  - timeframe = `H4`
  - lot constraints from server (`lot_min`, `lot_max`, `lot_step`)
- If policy check fails, EA blocks trading.

## Customer Packaging
Use:
- `powershell -ExecutionPolicy Bypass -File mt5/scripts/build_customer_package.ps1 -CustomerId <customer_id> -LicenseApiBase https://license.yourdomain.com`

For full release process, see:
- `mt5/CUSTOMER_RELEASE_CHECKLIST.md`
