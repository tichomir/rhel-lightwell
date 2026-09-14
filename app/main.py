"""Image Mode Train Service - FastAPI application.

Serves a small booking UI plus the Status page that carries the before/after
proof for the whole demo.

NOTE: fastapi.templating.Jinja2Templates is deliberately NOT used. Starlette's
templating module imports jinja2.pass_context, which does not exist before
Jinja2 3.0, so importing it would break the pinned dependency this demo is
built around. Static assets are served with StaticFiles; Jinja2 appears only in
receipts.py, where it is the subject rather than the plumbing.
"""
from datetime import date
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import config, db, receipts, sysinfo

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="Image Mode Train Service", docs_url="/api/docs", redoc_url=None)


# --------------------------------------------------------------------------- #
# Models
# --------------------------------------------------------------------------- #

class SearchRequest(BaseModel):
    origin: str = Field(min_length=2, max_length=8)
    destination: str = Field(min_length=2, max_length=8)
    travel_date: date


class BookingRequest(BaseModel):
    service_id: int
    travel_date: date
    passenger_name: str = Field(min_length=1, max_length=120)


class ReceiptRequest(BaseModel):
    booking_id: int
    template: str | None = None


class AttributeRequest(BaseModel):
    attributes: dict[str, str]


# --------------------------------------------------------------------------- #
# Status - the screen this demo is filmed around
# --------------------------------------------------------------------------- #

@app.get("/api/status")
def status():
    payload = sysinfo.collect(config.TIER)
    payload["database"] = db.health()
    payload["probe"] = receipts.attribute_probe()
    return payload


@app.get("/api/healthz")
def healthz():
    return {"status": "ok"}


# --------------------------------------------------------------------------- #
# Booking
# --------------------------------------------------------------------------- #

@app.get("/api/stations")
def list_stations():
    try:
        return db.stations()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Database unavailable: {exc}")


@app.post("/api/search")
def search(req: SearchRequest):
    if req.origin == req.destination:
        raise HTTPException(status_code=400, detail="Origin and destination match")
    try:
        return db.services(req.origin, req.destination, req.travel_date)
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Database unavailable: {exc}")


@app.post("/api/bookings")
def create_booking(req: BookingRequest):
    try:
        return db.create_booking(req.service_id, req.travel_date, req.passenger_name)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Database unavailable: {exc}")


@app.get("/api/bookings")
def list_bookings():
    try:
        return db.bookings()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Database unavailable: {exc}")


# --------------------------------------------------------------------------- #
# Receipts - the vulnerable surface
# --------------------------------------------------------------------------- #

@app.post("/api/receipt/preview")
def receipt_preview(req: ReceiptRequest):
    try:
        record = db.booking(req.booking_id)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"Database unavailable: {exc}")

    if record is None:
        raise HTTPException(status_code=404, detail="No such booking")

    try:
        body = receipts.render_receipt(req.template, record)
    except Exception as exc:  # noqa: BLE001 - operator templates can be wrong
        raise HTTPException(status_code=400, detail=f"Template error: {exc}")

    return {"booking_id": req.booking_id, "receipt": body}


@app.post("/api/attributes")
def render_attributes(req: AttributeRequest):
    """Render a mapping through the xmlattr filter.

    Exposed so the CVE observable is visible from the UI, not only from pytest.
    """
    try:
        return {"rendered": receipts.render_attributes(req.attributes)}
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(
            status_code=400,
            content={"rejected_with": type(exc).__name__, "detail": str(exc)},
        )


@app.get("/api/probe")
def probe():
    return receipts.attribute_probe()


# --------------------------------------------------------------------------- #
# UI
# --------------------------------------------------------------------------- #

@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def run():
    import uvicorn

    uvicorn.run(app, host=config.HOST, port=config.PORT, log_level="info")


if __name__ == "__main__":
    run()
