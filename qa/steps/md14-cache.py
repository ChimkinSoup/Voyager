"""MD-14: each profile's cached weather (read-only): fetched_at, temp, forecast fetchedAt, device_id."""
import sqlite3, os, json
for p in ('qa', 'qb'):
    c = sqlite3.connect('file:' + os.environ['APPDATA'] + r'\Voyager\voyager-profile-' + p + r'\voyager.sqlite?mode=ro', uri=True)
    r = c.execute('select device_id, weather_fetched_at, weather_temp_c, weather_forecast_json, weather_location_label from settings_table').fetchone()
    fc = json.loads(r[3])['fetchedAt'] if r[3] else None
    print(p, r[0][:8], 'current', r[1], r[2], 'forecast', fc, r[4])
