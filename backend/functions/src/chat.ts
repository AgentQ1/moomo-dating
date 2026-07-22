/**
 * Chat denormalisation. Messages are written directly by clients (the rules
 * validate shape, sender and membership); this trigger keeps the conversation
 * document's preview and unread counters honest so the list screen never has
 * to read the threads.
 */
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { trigger } from "./options";
import { db } from "./shared";

export const onMessageCreated = onDocumentCreated(
  {
    document: "conversations/{conversationId}/messages/{messageId}",
    ...trigger(20),
  },
  async (event) => {
    const message = event.data?.data();
    if (!message) return;

    const conversationRef = db()
      .collection("conversations")
      .doc(event.params.conversationId);
    const conversation = await conversationRef.get();
    if (!conversation.exists) {
      // Deleted (block cascade) between send and trigger. Nothing to update.
      return;
    }

    const senderId = message.senderId as string;
    const participantIds = (conversation.get("participantIds") ?? []) as string[];

    const update: Record<string, unknown> = {
      lastMessage: {
        senderId,
        // Preview only — the full text lives on the message.
        text: String(message.text ?? "").slice(0, 200),
        sentAt: message.sentAt,
      },
      lastMessageAt: message.sentAt,
    };
    for (const uid of participantIds) {
      if (uid !== senderId) {
        update[`unreadCounts.${uid}`] = FieldValue.increment(1);
      }
    }
    await conversationRef.update(update);
  }
);
