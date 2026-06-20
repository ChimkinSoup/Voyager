import { initializeApp } from "firebase-admin/app";
import {
  archiveLocationMatches,
  clearForecastArchive,
  mergeForecastArchive,
  readForecastArchive,
  writeForecastArchive,
} from "./forecast_archive";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { onCall, HttpsError } from "firebase-functions/v2/https";

initializeApp();

const openWeatherKey = defineSecret("OPENWEATHER_API_KEY");

function iconForCondition(id: number): string {
  if (id === 800 || id === 801) return "sunny";
  if (id >= 802 && id <= 804) return "cloudy";
  if (id >= 200 && id <= 531) return "rain";
  if (id >= 600 && id <= 622) return "snow";
  if (id >= 701 && id <= 781) return "cloudy";
  return "cloudy";
}

async function openWeatherFetch(url: string): Promise<Response> {
  const response = await fetch(url);
  if (response.ok) return response;

  let detail = "";
  try {
    const body = (await response.json()) as { message?: string };
    detail = body.message?.trim() ?? "";
  } catch {
    // Ignore non-JSON error bodies.
  }

  if (response.status === 401) {
    throw new HttpsError(
      "failed-precondition",
      detail || "OpenWeather API key is invalid or not activated yet.",
    );
  }
  if (response.status === 404) {
    throw new HttpsError("not-found", detail || "Location not found.");
  }

  throw new HttpsError(
    "internal",
    detail || `OpenWeather request failed (${response.status}).`,
  );
}

export const geocodeLocation = onCall(
  { secrets: [openWeatherKey] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const query = request.data?.query as string | undefined;
    if (!query?.trim()) {
      throw new HttpsError("invalid-argument", "query is required.");
    }

    const url =
      "https://api.openweathermap.org/geo/1.0/direct?q=" +
      encodeURIComponent(query.trim()) +
      "&limit=1&appid=" +
      openWeatherKey.value();

    const response = await openWeatherFetch(url);
    const data = (await response.json()) as Array<{
      name: string;
      state?: string;
      country: string;
      lat: number;
      lon: number;
    }>;

    if (!data.length) {
      throw new HttpsError("not-found", "Location not found.");
    }

    const place = data[0];
    return {
      lat: place.lat,
      lon: place.lon,
      label: [place.name, place.state, place.country].filter(Boolean).join(", "),
    };
  },
);

export const refreshWeather = onCall(
  { secrets: [openWeatherKey] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const lat = request.data?.lat;
    const lon = request.data?.lon;
    if (typeof lat !== "number" || typeof lon !== "number") {
      throw new HttpsError("invalid-argument", "lat and lon are required.");
    }

    const deviceId = (request.data?.deviceId as string | undefined) ?? null;
    const locationLabel =
      (request.data?.locationLabel as string | undefined) ?? null;

    const url =
      "https://api.openweathermap.org/data/2.5/weather?lat=" +
      lat +
      "&lon=" +
      lon +
      "&units=metric&appid=" +
      openWeatherKey.value();

    const response = await openWeatherFetch(url);
    const data = (await response.json()) as {
      weather: Array<{ id: number }>;
      main: { temp: number };
    };

    const conditionCode = data.weather[0]?.id ?? 800;
    const snapshot = {
      icon: iconForCondition(conditionCode),
      conditionCode,
      tempC: data.main.temp,
      fetchedAt: new Date().toISOString(),
      updatedByDeviceId: deviceId,
      lat,
      lon,
      locationLabel,
    };

    const uid = request.auth.uid;
    await getFirestore()
      .doc(`users/${uid}/weather/current`)
      .set(
        {
          icon: snapshot.icon,
          conditionCode: snapshot.conditionCode,
          tempC: snapshot.tempC,
          fetchedAt: FieldValue.serverTimestamp(),
          updatedByDeviceId: deviceId,
          lat,
          lon,
          locationLabel,
        },
        { merge: true },
      );

    return snapshot;
  },
);

export const refreshWeatherForecast = onCall(
  { secrets: [openWeatherKey] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const lat = request.data?.lat;
    const lon = request.data?.lon;
    if (typeof lat !== "number" || typeof lon !== "number") {
      throw new HttpsError("invalid-argument", "lat and lon are required.");
    }

    const locationLabel =
      (request.data?.locationLabel as string | undefined) ?? null;
    const resetArchive = request.data?.resetArchive === true;
    const offsetMinutes = request.data?.timeZoneOffsetMinutes;
    if (typeof offsetMinutes !== "number") {
      throw new HttpsError(
        "invalid-argument",
        "timeZoneOffsetMinutes is required.",
      );
    }

    const uid = request.auth.uid;
    if (resetArchive) {
      await clearForecastArchive(uid);
    }

    const archive = resetArchive ? null : await readForecastArchive(uid);
    const locationChanged =
      archive != null && !archiveLocationMatches(archive, lat, lon);
    if (locationChanged) {
      await clearForecastArchive(uid);
    }

    const existingPeriods =
      locationChanged || resetArchive || !archive?.periods
        ? {}
        : archive.periods;

    const url =
      "https://api.openweathermap.org/data/2.5/forecast?lat=" +
      lat +
      "&lon=" +
      lon +
      "&units=metric&appid=" +
      openWeatherKey.value();

    const response = await openWeatherFetch(url);
    const data = (await response.json()) as {
      list: Array<{
        dt: number;
        main: { temp: number };
        weather: Array<{ id: number; description: string }>;
        pop: number;
      }>;
    };

    const apiPeriods = (data.list ?? []).map((item) => {
      const conditionCode = item.weather[0]?.id ?? 800;
      return {
        time: new Date(item.dt * 1000).toISOString(),
        tempC: item.main.temp,
        pop: item.pop ?? 0,
        icon: iconForCondition(conditionCode),
        conditionCode,
        description: item.weather[0]?.description ?? "",
      };
    });

    const mergedPeriods = mergeForecastArchive({
      existingPeriods,
      apiPeriods,
      offsetMinutes,
      resetArchive: resetArchive || locationChanged,
    });

    await writeForecastArchive(uid, {
      lat,
      lon,
      locationLabel,
      offsetMinutes,
      periods: mergedPeriods,
    });

    return {
      fetchedAt: new Date().toISOString(),
      locationLabel,
      periods: mergedPeriods,
    };
  },
);
