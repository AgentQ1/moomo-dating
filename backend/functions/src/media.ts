/**
 * Call media tokens — the bridge between a Firestore `callSessions` document
 * and the LiveKit room that carries its audio/video.
 *
 * The client never holds LiveKit credentials. It asks this callable for a
 * short-lived room token; we verify the caller is a participant of a live
 * session and mint a JWT scoped to exactly that room, expiring with the
 * call clock (plus reconnect grace). The room name IS the session id, so a
 * token cannot be replayed into any other call.
 *
 * Configuration (see backend/README.md):
 *  - LIVEKIT_URL        — string param, e.g. wss://your-project.livekit.cloud
 *  - LIVEKIT_API_KEY    — secret (Cloud Secret Manager)
 *  - LIVEKIT_API_SECRET — secret (Cloud Secret Manager)
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";
import { AccessToken } from "livekit-server-sdk";
import {
  db,
  requireAuth,
  requireString,
  assertParticipant,
  millis,
  SPEED_CALL_SECONDS,
} from "./shared";

const livekitUrl = defineString("LIVEKIT_URL", { default: "" });
const livekitApiKey = defineSecret("LIVEKIT_API_KEY");
const livekitApiSecret = defineSecret("LIVEKIT_API_SECRET");

/** Reconnect/setup slack added to the call's remaining time. */
const TOKEN_GRACE_SECONDS = 90;

export const getCallMediaToken = onCall(
  { secrets: [livekitApiKey, livekitApiSecret] },
  async (request) => {
    const uid = requireAuth(request);
    const sessionId = requireString(request.data?.sessionId, "sessionId");

    const session = await db().collection("callSessions").doc(sessionId).get();
    assertParticipant(session, uid);

    if (session.get("status") !== "active") {
      // `reason` lets the client tell "the call is over" apart from "media
      // is misconfigured" — both are failed-precondition on the wire.
      throw new HttpsError("failed-precondition", "This call has ended.", {
        reason: "call-ended",
      });
    }

    // The token dies with the call clock. A tampered client that keeps the
    // socket open past the clock is evicted when the token expires.
    const startedAtMillis = millis(session.get("startedAt")) ?? Date.now();
    const maxDurationSeconds =
      (session.get("maxDurationSeconds") as number) ?? SPEED_CALL_SECONDS;
    const remainingSeconds =
      maxDurationSeconds - (Date.now() - startedAtMillis) / 1000;
    if (remainingSeconds <= 0) {
      throw new HttpsError("failed-precondition", "This call has ended.", {
        reason: "call-ended",
      });
    }

    const url = livekitUrl.value();
    const apiKey = livekitApiKey.value();
    const apiSecret = livekitApiSecret.value();
    if (!url || !apiKey || !apiSecret) {
      // Configuration truth, not a fake dial tone: without LiveKit credentials
      // there is no media, and the client shows the call as failed.
      throw new HttpsError(
        "failed-precondition",
        "Call media is not configured on the server."
      );
    }

    const participants = session.get("participants") ?? {};
    const displayName =
      typeof participants[uid]?.displayName === "string"
        ? (participants[uid].displayName as string)
        : "Someone";

    const ttlSeconds = Math.ceil(remainingSeconds) + TOKEN_GRACE_SECONDS;
    const token = new AccessToken(apiKey, apiSecret, {
      identity: uid,
      name: displayName,
      ttl: ttlSeconds,
    });
    token.addGrant({
      room: sessionId,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      // Chat lives in Firestore where rules and moderation apply — the media
      // channel must not become an unmoderated side channel.
      canPublishData: false,
    });

    return {
      url,
      token: await token.toJwt(),
      roomName: sessionId,
      expiresInSeconds: ttlSeconds,
    };
  }
);
