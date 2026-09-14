-- Image Mode Train Service schema.
-- Applied once by pg-initdb.service on first boot of the im-train-db host.

create table if not exists stations (
    code text primary key,
    name text not null
);

create table if not exists services (
    id           serial primary key,
    service_code text not null,
    origin       text not null references stations(code),
    destination  text not null references stations(code),
    depart_time  time not null,
    arrive_time  time not null,
    price_eur    numeric(7,2) not null
);

create index if not exists services_route_idx on services (origin, destination);

-- Booking references are generated in the database so the application does not
-- need to be restarted to stay consistent across an image upgrade.
create sequence if not exists booking_ref_seq start 4100;

create table if not exists bookings (
    id             serial primary key,
    reference      text not null unique default ('IMT-' || nextval('booking_ref_seq')),
    service_id     integer not null references services(id),
    travel_date    date not null,
    passenger_name text not null,
    created_at     timestamptz not null default now()
);
