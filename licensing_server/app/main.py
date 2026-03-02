import json
import uuid
from datetime import UTC, datetime, timedelta

from fastapi import Depends, FastAPI, HTTPException, Request, status
from sqlalchemy import desc, select
from sqlalchemy.orm import Session

from .config import settings
from .database import Base, engine, get_db
from .models import Activation, AuditLog, License, OtpCode
from .rate_limit import require_rate_limit
from .schemas import (
    ActivateRequest,
    ActivateResponse,
    AuditLogItem,
    CreateLicenseRequest,
    CreateLicenseResponse,
    GenerateOtpRequest,
    GenerateOtpResponse,
    ParamPolicy,
    RevokeLicenseResponse,
    ValidateRequest,
    ValidateResponse,
)
from .security import generate_activation_token, generate_otp, hash_value, require_admin_auth, utc_now

app = FastAPI(title=settings.app_name)
Base.metadata.create_all(bind=engine)


def unix_ts(dt: datetime) -> int:
    return int(to_utc(dt).timestamp())


def to_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def policy_from_license(license_obj: License) -> ParamPolicy:
    return ParamPolicy(
        lot_min=float(license_obj.lot_min),
        lot_max=float(license_obj.lot_max),
        lot_step=float(license_obj.lot_step),
        symbol="XAUUSD",
        timeframe="H4",
    )


def write_audit(db: Session, event_type: str, payload: dict) -> None:
    row = AuditLog(
        id=str(uuid.uuid4()),
        event_type=event_type,
        payload_json=json.dumps(payload, separators=(",", ":"), sort_keys=True),
        created_at=utc_now(),
    )
    db.add(row)


def deny_activation(db: Session, reason: str, request_data: ActivateRequest) -> ActivateResponse:
    write_audit(
        db,
        "activate_denied",
        {
            "license_id": request_data.license_id,
            "account_login": request_data.account_login,
            "broker_server": request_data.broker_server,
            "reason": reason,
        },
    )
    db.commit()
    return ActivateResponse(status="denied", reason=reason)


def deny_validate(db: Session, reason: str, request_data: ValidateRequest) -> ValidateResponse:
    write_audit(
        db,
        "validate_denied",
        {
            "account_login": request_data.account_login,
            "broker_server": request_data.broker_server,
            "ea_code": request_data.ea_code,
            "reason": reason,
        },
    )
    db.commit()
    return ValidateResponse(status="denied", reason=reason)


def is_license_usable(license_obj: License) -> tuple[bool, str | None]:
    now = utc_now()
    if license_obj.status != "active":
        return False, f"license status is {license_obj.status}"
    if license_obj.expires_at and to_utc(license_obj.expires_at) <= now:
        return False, "license expired"
    return True, None


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/api/v1/activate", response_model=ActivateResponse)
def activate(request_data: ActivateRequest, db: Session = Depends(get_db)) -> ActivateResponse:
    license_obj = db.get(License, request_data.license_id)
    if not license_obj:
        return deny_activation(db, "license not found", request_data)
    if license_obj.ea_code != request_data.ea_code:
        return deny_activation(db, "license does not match ea_code", request_data)

    usable, unusable_reason = is_license_usable(license_obj)
    if not usable:
        return deny_activation(db, unusable_reason or "license unavailable", request_data)

    otp_row = db.execute(
        select(OtpCode)
        .where(OtpCode.license_id == request_data.license_id)
        .order_by(desc(OtpCode.created_at))
    ).scalars().first()
    if not otp_row:
        return deny_activation(db, "otp not found", request_data)

    now = utc_now()
    if otp_row.used_at is not None:
        return deny_activation(db, "otp already used", request_data)
    if to_utc(otp_row.expires_at) <= now:
        return deny_activation(db, "otp expired", request_data)
    if otp_row.attempts >= settings.otp_max_attempts:
        return deny_activation(db, "otp attempt limit exceeded", request_data)
    if otp_row.otp_hash != hash_value(request_data.otp):
        otp_row.attempts += 1
        write_audit(
            db,
            "otp_invalid_attempt",
            {
                "license_id": request_data.license_id,
                "attempts": otp_row.attempts,
                "account_login": request_data.account_login,
                "broker_server": request_data.broker_server,
            },
        )
        db.commit()
        return ActivateResponse(status="denied", reason="invalid otp")

    existing_activation = db.execute(
        select(Activation)
        .where(Activation.license_id == request_data.license_id)
        .where(Activation.revoked_at.is_(None))
    ).scalars().first()

    plain_token: str
    if existing_activation:
        if (
            existing_activation.account_login != request_data.account_login
            or existing_activation.broker_server != request_data.broker_server
        ):
            return deny_activation(db, "license already bound to another account/server", request_data)
        plain_token = generate_activation_token()
        existing_activation.activation_token_hash = hash_value(plain_token)
        existing_activation.last_seen_at = now
        activation_row = existing_activation
    else:
        plain_token = generate_activation_token()
        activation_row = Activation(
            id=str(uuid.uuid4()),
            license_id=request_data.license_id,
            activation_token_hash=hash_value(plain_token),
            account_login=request_data.account_login,
            broker_server=request_data.broker_server,
            created_at=now,
            last_seen_at=now,
            revoked_at=None,
        )
        db.add(activation_row)

    otp_row.used_at = now
    otp_row.used_by_account = request_data.account_login
    otp_row.used_by_server = request_data.broker_server

    next_check = now + timedelta(hours=settings.recheck_hours)
    write_audit(
        db,
        "activate_success",
        {
            "license_id": request_data.license_id,
            "activation_id": activation_row.id,
            "account_login": request_data.account_login,
            "broker_server": request_data.broker_server,
            "ea_code": request_data.ea_code,
        },
    )
    db.commit()

    return ActivateResponse(
        status="active",
        activation_token=plain_token,
        next_check_at_utc=unix_ts(next_check),
        offline_grace_hours=settings.offline_grace_hours,
        param_policy=policy_from_license(license_obj),
    )


@app.post("/api/v1/validate", response_model=ValidateResponse)
def validate(request_data: ValidateRequest, db: Session = Depends(get_db)) -> ValidateResponse:
    activation = db.execute(
        select(Activation).where(Activation.activation_token_hash == hash_value(request_data.activation_token))
    ).scalars().first()
    if not activation:
        return deny_validate(db, "activation token not found", request_data)
    if activation.revoked_at is not None:
        return deny_validate(db, "activation revoked", request_data)
    if activation.account_login != request_data.account_login:
        return deny_validate(db, "account mismatch", request_data)
    if activation.broker_server != request_data.broker_server:
        return deny_validate(db, "broker mismatch", request_data)

    license_obj = db.get(License, activation.license_id)
    if not license_obj:
        return deny_validate(db, "license not found", request_data)
    if license_obj.ea_code != request_data.ea_code:
        return deny_validate(db, "license does not match ea_code", request_data)

    usable, unusable_reason = is_license_usable(license_obj)
    if not usable:
        return deny_validate(db, unusable_reason or "license unavailable", request_data)

    now = utc_now()
    activation.last_seen_at = now
    next_check = now + timedelta(hours=settings.recheck_hours)
    write_audit(
        db,
        "validate_success",
        {
            "license_id": license_obj.id,
            "activation_id": activation.id,
            "account_login": request_data.account_login,
            "broker_server": request_data.broker_server,
        },
    )
    db.commit()

    return ValidateResponse(
        status="active",
        next_check_at_utc=unix_ts(next_check),
        offline_grace_hours=settings.offline_grace_hours,
        param_policy=policy_from_license(license_obj),
    )


@app.post("/api/v1/admin/licenses", response_model=CreateLicenseResponse, dependencies=[Depends(require_admin_auth)])
def create_license(request_data: CreateLicenseRequest, db: Session = Depends(get_db)) -> CreateLicenseResponse:
    license_id = request_data.license_id or uuid.uuid4().hex[:16]
    if db.get(License, license_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="license_id already exists")
    if request_data.lot_min <= 0 or request_data.lot_max <= 0 or request_data.lot_step <= 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="lot values must be positive")
    if request_data.lot_min > request_data.lot_max:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="lot_min cannot exceed lot_max")

    row = License(
        id=license_id,
        ea_code=request_data.ea_code,
        status=request_data.status,
        expires_at=request_data.expires_at,
        bind_mode=request_data.bind_mode,
        lot_min=request_data.lot_min,
        lot_max=request_data.lot_max,
        lot_step=request_data.lot_step,
        created_at=utc_now(),
    )
    db.add(row)
    write_audit(
        db,
        "admin_create_license",
        {
            "license_id": license_id,
            "ea_code": request_data.ea_code,
            "status": request_data.status,
            "expires_at": request_data.expires_at.isoformat() if request_data.expires_at else None,
        },
    )
    db.commit()
    return CreateLicenseResponse(license_id=license_id, status=row.status)


@app.post(
    "/api/v1/admin/otp/generate",
    response_model=GenerateOtpResponse,
    dependencies=[Depends(require_admin_auth)],
)
def generate_license_otp(request_data: GenerateOtpRequest, db: Session = Depends(get_db)) -> GenerateOtpResponse:
    license_obj = db.get(License, request_data.license_id)
    if not license_obj:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="license not found")

    ttl_seconds = request_data.ttl_seconds or settings.otp_ttl_seconds
    if ttl_seconds <= 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="ttl_seconds must be positive")

    now = utc_now()
    otp_plain = generate_otp(6)
    expires_at = now + timedelta(seconds=ttl_seconds)
    row = OtpCode(
        id=str(uuid.uuid4()),
        license_id=request_data.license_id,
        otp_hash=hash_value(otp_plain),
        expires_at=expires_at,
        created_at=now,
        attempts=0,
        used_at=None,
        used_by_account=None,
        used_by_server=None,
    )
    db.add(row)
    write_audit(
        db,
        "admin_generate_otp",
        {
            "license_id": request_data.license_id,
            "otp_id": row.id,
            "ttl_seconds": ttl_seconds,
        },
    )
    db.commit()
    return GenerateOtpResponse(
        license_id=request_data.license_id,
        otp=otp_plain,
        expires_at_utc=unix_ts(expires_at),
    )


@app.post(
    "/api/v1/admin/licenses/{license_id}/revoke",
    response_model=RevokeLicenseResponse,
    dependencies=[Depends(require_admin_auth)],
)
def revoke_license(license_id: str, db: Session = Depends(get_db)) -> RevokeLicenseResponse:
    license_obj = db.get(License, license_id)
    if not license_obj:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="license not found")

    now = utc_now()
    license_obj.status = "revoked"
    activations = db.execute(select(Activation).where(Activation.license_id == license_id)).scalars().all()
    for activation in activations:
        if activation.revoked_at is None:
            activation.revoked_at = now

    write_audit(
        db,
        "admin_revoke_license",
        {
            "license_id": license_id,
            "revoked_activation_count": len(activations),
        },
    )
    db.commit()
    return RevokeLicenseResponse(license_id=license_id, status="revoked")


@app.get(
    "/api/v1/admin/audit",
    response_model=list[AuditLogItem],
    dependencies=[Depends(require_admin_auth)],
)
def list_audit(limit: int = 100, db: Session = Depends(get_db)) -> list[AuditLogItem]:
    limited = max(1, min(limit, 1000))
    rows = db.execute(select(AuditLog).order_by(desc(AuditLog.created_at)).limit(limited)).scalars().all()
    return [
        AuditLogItem(
            event_type=row.event_type,
            payload_json=row.payload_json,
            created_at_utc=unix_ts(row.created_at),
        )
        for row in rows
    ]


@app.middleware("http")
async def global_rate_limit(request: Request, call_next):
    if request.url.path.startswith("/api/v1/activate") or request.url.path.startswith("/api/v1/validate"):
        require_rate_limit(request)
    return await call_next(request)
