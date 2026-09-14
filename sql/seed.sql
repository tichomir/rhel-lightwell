-- Deterministic seed data. Re-runnable: scripts/reset.sh calls this between
-- recording takes, so it must leave the database in an identical state every
-- time. No random values and no now()-derived rows.

begin;

truncate table bookings restart identity cascade;
delete from services;
delete from stations;
alter sequence booking_ref_seq restart with 4100;

insert into stations (code, name) values
    ('OSR', 'Ostrava Hlavni'),
    ('PRG', 'Praha Hlavni'),
    ('BRN', 'Brno Hlavni'),
    ('VIE', 'Wien Hauptbahnhof'),
    ('KAT', 'Katowice'),
    ('BTS', 'Bratislava Hlavna');

insert into services (service_code, origin, destination, depart_time, arrive_time, price_eur) values
    ('EC 220',  'OSR', 'PRG', '06:12', '09:24', 28.50),
    ('IC 1008', 'OSR', 'PRG', '10:12', '13:31', 24.00),
    ('EC 224',  'OSR', 'PRG', '16:12', '19:26', 28.50),
    ('RJ 1020', 'OSR', 'VIE', '07:05', '10:38', 39.90),
    ('RJ 1024', 'OSR', 'VIE', '15:05', '18:41', 39.90),
    ('R 810',   'OSR', 'BRN', '08:40', '11:02', 16.00),
    ('R 814',   'OSR', 'BRN', '14:40', '17:05', 16.00),
    ('EN 442',  'OSR', 'KAT', '09:18', '11:44', 12.50),
    ('EC 221',  'PRG', 'OSR', '07:20', '10:33', 28.50),
    ('IC 1009', 'PRG', 'OSR', '13:20', '16:39', 24.00),
    ('RJ 1021', 'VIE', 'OSR', '08:12', '11:47', 39.90),
    ('R 811',   'BRN', 'OSR', '09:15', '11:38', 16.00),
    ('EC 330',  'PRG', 'BRN', '06:35', '09:15', 22.00),
    ('RJ 74',   'PRG', 'VIE', '11:10', '15:12', 44.00),
    ('EX 1',    'BTS', 'VIE', '07:40', '08:45',  9.90);

-- One pre-existing booking, so "My tickets" is never empty on camera and the
-- /var persistence claim in Act 4 has something to demonstrate.
insert into bookings (service_id, travel_date, passenger_name)
select id, date '2026-10-01', 'D. Chugtai' from services where service_code = 'EC 220';

commit;
