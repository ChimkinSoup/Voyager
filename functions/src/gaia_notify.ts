import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

/**
 * Gaia's push notifications (GAIA_HLD.md §14): a beacon writes one
 * `gaia_notify` document when a run a phone started finishes, asks a
 * question or raises a card. This sends it to every paired, unrevoked
 * device with an FCM token (or the one named in `toDevice`), then deletes
 * the document: one invocation per notification, never per message write.
 */
export const gaiaNotify = onDocumentCreated(
  "users/{uid}/gaia_notify/{id}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;
    const data = snapshot.data() as {
      chatId?: string;
      kind?: string;
      title?: string;
      text?: string;
      toDevice?: string | null;
    };
    const devices = await getFirestore()
      .collection(`users/${event.params.uid}/gaia_devices`)
      .get();
    const tokens = devices.docs
      .filter((doc) => !doc.get("revokedAt"))
      .filter((doc) => !data.toDevice || doc.id === data.toDevice)
      .map((doc) => doc.get("fcmToken") as string | undefined)
      .filter((token): token is string => !!token);
    if (tokens.length > 0) {
      const result = await getMessaging().sendEachForMulticast({
        tokens,
        notification: {
          title: (data.title ?? "Gaia").slice(0, 120),
          body: (data.text ?? "").slice(0, 240),
        },
        data: { chatId: data.chatId ?? "", kind: data.kind ?? "done" },
        android: {
          priority: "high",
          notification: { tag: data.chatId ?? undefined },
        },
      });
      // A token the phone no longer has is dropped, so it isn't tried again.
      await Promise.all(
        result.responses.map(async (response, i) => {
          const code = response.error?.code;
          if (
            code === "messaging/registration-token-not-registered" ||
            code === "messaging/invalid-registration-token"
          ) {
            const stale = devices.docs.find(
              (doc) => doc.get("fcmToken") === tokens[i],
            );
            await stale?.ref.update({ fcmToken: null });
          }
        }),
      );
    }
    await snapshot.ref.delete();
  },
);
