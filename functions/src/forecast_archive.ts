import { FieldValue, getFirestore } from "firebase-admin/firestore";

type ForecastPeriod = {
  time: string;
  tempC: number;
  pop: number;
  icon: string;
  conditionCode: number;
  description: string;
};

type ArchiveDoc = {
  lat?: number;
  lon?: number;
  locationLabel?: string | null;
  fetchedAt?: string;
  periods?: Record<string, ForecastPeriod>;
};

function chartBucketHour(localHour: number): number {
  return Math.floor(localHour / 3) * 3;
}

function localPartsFromUtc(isoTime: string, offsetMinutes: number) {
  const ms = Date.parse(isoTime) + offsetMinutes * 60 * 1000;
  const d = new Date(ms);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
  };
}

function localTodayKey(offsetMinutes: number, now = new Date()): string {
  const parts = localPartsFromUtc(now.toISOString(), offsetMinutes);
  return formatDateKey(parts.year, parts.month, parts.day);
}

function formatDateKey(year: number, month: number, day: number): string {
  return (
    String(year).padStart(4, "0") +
    "_" +
    String(month).padStart(2, "0") +
    "_" +
    String(day).padStart(2, "0")
  );
}

export function forecastBucketKey(
  isoTime: string,
  offsetMinutes: number,
): string {
  const parts = localPartsFromUtc(isoTime, offsetMinutes);
  const bucketHour = chartBucketHour(parts.hour);
  return (
    formatDateKey(parts.year, parts.month, parts.day) +
    "_" +
    String(bucketHour).padStart(2, "0")
  );
}

function parseBucketDateKey(bucketKey: string): string | null {
  const segments = bucketKey.split("_");
  if (segments.length !== 4) return null;
  return segments.slice(0, 3).join("_");
}

export function mergeForecastArchive(params: {
  existingPeriods: Record<string, ForecastPeriod>;
  apiPeriods: ForecastPeriod[];
  offsetMinutes: number;
  resetArchive?: boolean;
  now?: Date;
}): ForecastPeriod[] {
  const todayKey = localTodayKey(params.offsetMinutes, params.now);
  const merged: Record<string, ForecastPeriod> = {};

  if (!params.resetArchive) {
    for (const [key, period] of Object.entries(params.existingPeriods)) {
      const dateKey = parseBucketDateKey(key);
      if (!dateKey || dateKey < todayKey) continue;
      merged[key] = period;
    }
  }

  for (const period of params.apiPeriods) {
    const key = forecastBucketKey(period.time, params.offsetMinutes);
    merged[key] = period;
  }

  return Object.values(merged).sort(
    (a, b) => Date.parse(a.time) - Date.parse(b.time),
  );
}

export async function readForecastArchive(
  uid: string,
): Promise<ArchiveDoc | null> {
  const snap = await getFirestore().doc(`users/${uid}/weather/forecast`).get();
  if (!snap.exists || !snap.data()) return null;
  return snap.data() as ArchiveDoc;
}

export async function writeForecastArchive(
  uid: string,
  params: {
    lat: number;
    lon: number;
    locationLabel: string | null;
    offsetMinutes: number;
    periods: ForecastPeriod[];
  },
): Promise<void> {
  const bucketMap: Record<string, ForecastPeriod> = {};
  for (const period of params.periods) {
    bucketMap[forecastBucketKey(period.time, params.offsetMinutes)] = period;
  }

  await getFirestore()
    .doc(`users/${uid}/weather/forecast`)
    .set(
      {
        lat: params.lat,
        lon: params.lon,
        locationLabel: params.locationLabel,
        fetchedAt: FieldValue.serverTimestamp(),
        periods: bucketMap,
      },
      { merge: true },
    );
}

export async function clearForecastArchive(uid: string): Promise<void> {
  await getFirestore().doc(`users/${uid}/weather/forecast`).delete();
}

export function archiveLocationMatches(
  archive: ArchiveDoc | null,
  lat: number,
  lon: number,
): boolean {
  if (!archive) return false;
  return archive.lat === lat && archive.lon === lon;
}
