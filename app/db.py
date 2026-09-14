"""Database access, with a degraded mode.

If Postgres is unreachable the app still starts and the Status page still
renders, with db.available False. That matters for a recorded demo: a database
hiccup should cost you one panel, not the whole take.
"""
import threading

import psycopg
from psycopg.rows import dict_row

from . import config

_lock = threading.Lock()
_last_error = None


def _connect():
    if not config.DB_URL:
        raise RuntimeError("IM_TRAIN_DB_URL is not set")
    return psycopg.connect(config.DB_URL, row_factory=dict_row, connect_timeout=5)


def health():
    """Report reachability without raising."""
    global _last_error
    try:
        with _connect() as conn, conn.cursor() as cur:
            cur.execute("select version() as v")
            row = cur.fetchone()
        _last_error = None
        return {"available": True, "server": row["v"].split(" on ")[0], "error": None}
    except Exception as exc:  # noqa: BLE001 - degraded mode is deliberate
        _last_error = str(exc)
        return {"available": False, "server": None, "error": _last_error}


def stations():
    with _connect() as conn, conn.cursor() as cur:
        cur.execute("select code, name from stations order by name")
        return cur.fetchall()


def services(origin, destination, travel_date):
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            select s.id, s.service_code, s.depart_time, s.arrive_time,
                   s.price_eur, o.name as origin_name, d.name as destination_name
              from services s
              join stations o on o.code = s.origin
              join stations d on d.code = s.destination
             where s.origin = %s and s.destination = %s
             order by s.depart_time
            """,
            (origin, destination),
        )
        rows = cur.fetchall()
    for row in rows:
        row["travel_date"] = str(travel_date)
        row["depart_time"] = str(row["depart_time"])
        row["arrive_time"] = str(row["arrive_time"])
        row["price_eur"] = float(row["price_eur"])
    return rows


def create_booking(service_id, travel_date, passenger_name):
    with _lock, _connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            insert into bookings (service_id, travel_date, passenger_name)
            values (%s, %s, %s)
            returning id, reference, service_id, travel_date, passenger_name, created_at
            """,
            (service_id, travel_date, passenger_name),
        )
        row = cur.fetchone()
        conn.commit()
    row["travel_date"] = str(row["travel_date"])
    row["created_at"] = row["created_at"].isoformat()
    return row


def bookings():
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            select b.id, b.reference, b.passenger_name, b.travel_date,
                   s.service_code, o.name as origin_name, d.name as destination_name,
                   s.depart_time, s.price_eur
              from bookings b
              join services s on s.id = b.service_id
              join stations o on o.code = s.origin
              join stations d on d.code = s.destination
             order by b.id desc
            """
        )
        rows = cur.fetchall()
    for row in rows:
        row["travel_date"] = str(row["travel_date"])
        row["depart_time"] = str(row["depart_time"])
        row["price_eur"] = float(row["price_eur"])
    return rows


def booking(booking_id):
    rows = [b for b in bookings() if b["id"] == booking_id]
    return rows[0] if rows else None
