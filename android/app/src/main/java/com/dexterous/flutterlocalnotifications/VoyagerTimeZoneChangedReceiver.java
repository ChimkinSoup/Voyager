package com.dexterous.flutterlocalnotifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import androidx.annotation.Keep;
import java.time.ZoneId;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Voyager's, not the plugin's: keeps scheduled reminders on their wall-clock
 * time when the device changes timezone while the app isn't running.
 *
 * <p>Reminders are scheduled as a wall-clock time in a named zone, which the
 * plugin caches beside each alarm. On a timezone change this renames that zone
 * to the new one and has the plugin set every alarm again, so a 9 AM reminder
 * still fires at 9 AM — what the app itself computes the next time it runs.
 *
 * <p>In the plugin's package only because {@code rescheduleNotifications} (what
 * its boot receiver calls) is package-private. The cache it edits is the
 * plugin's own: the {@code scheduled_notifications} preference, a JSON list of
 * its {@code NotificationDetails}.
 */
@Keep
public class VoyagerTimeZoneChangedReceiver extends BroadcastReceiver {
  private static final String SCHEDULED_NOTIFICATIONS = "scheduled_notifications";

  @Override
  public void onReceive(Context context, Intent intent) {
    if (!Intent.ACTION_TIMEZONE_CHANGED.equals(intent.getAction())) return;
    SharedPreferences preferences =
        context.getSharedPreferences(SCHEDULED_NOTIFICATIONS, Context.MODE_PRIVATE);
    String json = preferences.getString(SCHEDULED_NOTIFICATIONS, null);
    if (json == null) return;
    String zone = ZoneId.systemDefault().getId();
    try {
      JSONArray notifications = new JSONArray(json);
      for (int i = 0; i < notifications.length(); i++) {
        JSONObject notification = notifications.getJSONObject(i);
        // Alerts the app could only schedule as a UTC instant stay put.
        String scheduledZone = notification.optString("timeZoneName", "");
        if (scheduledZone.isEmpty() || scheduledZone.equals("UTC")) continue;
        notification.put("timeZoneName", zone);
      }
      preferences.edit().putString(SCHEDULED_NOTIFICATIONS, notifications.toString()).commit();
    } catch (JSONException e) {
      return;
    }
    FlutterLocalNotificationsPlugin.rescheduleNotifications(context);
  }
}
