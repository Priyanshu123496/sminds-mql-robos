from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, Numeric, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


class License(Base):
    __tablename__ = "licenses"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    ea_code: Mapped[str] = mapped_column(String(128), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False, default="active")
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    bind_mode: Mapped[str] = mapped_column(String(32), nullable=False, default="account_server")
    lot_min: Mapped[float] = mapped_column(Numeric(18, 8), nullable=False, default=0.01)
    lot_max: Mapped[float] = mapped_column(Numeric(18, 8), nullable=False, default=100.0)
    lot_step: Mapped[float] = mapped_column(Numeric(18, 8), nullable=False, default=0.01)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

    otp_codes: Mapped[list["OtpCode"]] = relationship(back_populates="license")
    activations: Mapped[list["Activation"]] = relationship(back_populates="license")


class OtpCode(Base):
    __tablename__ = "otp_codes"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    license_id: Mapped[str] = mapped_column(ForeignKey("licenses.id"), nullable=False)
    otp_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    used_by_account: Mapped[int | None] = mapped_column(Integer, nullable=True)
    used_by_server: Mapped[str | None] = mapped_column(String(128), nullable=True)

    license: Mapped["License"] = relationship(back_populates="otp_codes")


class Activation(Base):
    __tablename__ = "activations"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    license_id: Mapped[str] = mapped_column(ForeignKey("licenses.id"), nullable=False)
    activation_token_hash: Mapped[str] = mapped_column(String(128), nullable=False, unique=True)
    account_login: Mapped[int] = mapped_column(Integer, nullable=False)
    broker_server: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    license: Mapped["License"] = relationship(back_populates="activations")


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    event_type: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_json: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
