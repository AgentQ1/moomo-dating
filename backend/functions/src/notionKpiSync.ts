import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

/**
 * Baybe HQ KPI sync
 *
 * Architecture:
 * Firestore aggregate document -> scheduled Cloud Function -> Notion KPI database.
 *
 * This intentionally sends aggregate company metrics only. Never send raw user
 * profiles, messages, phone numbers, auth tokens, reports, or safety evidence.
 *
 * Required Firebase secrets:
 *   firebase functions:secrets:set NOTION_TOKEN
 *   firebase functions:secrets:set NOTION_KPI_DATA_SOURCE_ID
 *
 * Expected aggregate document:
 *   companyMetrics/current
 * Example fields:
 *   { dau: 120, mau: 900, activationRate: 0.61, matchRate: 0.34, ... }
 *
 * A separate analytics aggregation job should populate that document from the
 * source of truth (Firestore and/or GA4/BigQuery). This function does not invent
 * metrics and will only sync values that actually exist.
 */

const notionToken = defineSecret("NOTION_TOKEN");
const notionKpiDataSourceId = defineSecret("NOTION_KPI_DATA_SOURCE_ID");

const NOTION_VERSION = "2025-09-03";

type MetricSpec = {
  notionName: string;
  field: string;
};

const METRICS: MetricSpec[] = [
  { notionName: "DAU", field: "dau" },
  { notionName: "MAU", field: "mau" },
  { notionName: "Activation rate", field: "activationRate" },
  { notionName: "Match rate", field: "matchRate" },
  { notionName: "Match-to-message rate", field: "matchToMessageRate" },
  { notionName: "Video-call conversion", field: "videoCallConversion" },
  { notionName: "D1 Retention", field: "d1Retention" },
  { notionName: "D7 Retention", field: "d7Retention" },
  { notionName: "D30 Retention", field: "d30Retention" },
  { notionName: "Paid subscribers", field: "paidSubscribers" },
  { notionName: "MRR", field: "mrr" },
  { notionName: "ARR", field: "arr" },
  { notionName: "Report / block rate", field: "reportBlockRate" },
  { notionName: "Fake-account rate", field: "fakeAccountRate" },
  { notionName: "Time to first match", field: "timeToFirstMatch" },
  { notionName: "Time to first conversation", field: "timeToFirstConversation" },
];

async function notionRequest(path: string, init: RequestInit = {}) {
  const response = await fetch(`https://api.notion.com/v1${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${notionToken.value()}`,
      "Notion-Version": NOTION_VERSION,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });

  if (!response.ok) {
    throw new Error(`Notion ${response.status}: ${await response.text()}`);
  }
  return response.json() as Promise<any>;
}

async function findMetricPage(metricName: string): Promise<any | null> {
  const dataSourceId = notionKpiDataSourceId.value();
  const body = {
    filter: {
      property: "Metric",
      title: { equals: metricName },
    },
    page_size: 1,
  };

  const result = await notionRequest(
    `/data_sources/${dataSourceId}/query`,
    { method: "POST", body: JSON.stringify(body) },
  );
  return result.results?.[0] ?? null;
}

async function updateMetric(metricName: string, value: number) {
  const page = await findMetricPage(metricName);
  if (!page) {
    logger.warn("KPI record not found in Notion; skipping", { metricName });
    return;
  }

  const oldValue = page.properties?.["Current Value"]?.number ?? null;
  const properties: Record<string, unknown> = {
    "Current Value": { number: value },
    "Previous Value": { number: oldValue },
    "Freshness": { select: { name: "Fresh" } },
    "Instrumentation Status": { select: { name: "Live" } },
  };

  await notionRequest(`/pages/${page.id}`, {
    method: "PATCH",
    body: JSON.stringify({ properties }),
  });
}

export const syncBaybeKpisToNotion = onSchedule(
  {
    schedule: "every day 06:00",
    timeZone: "America/Chicago",
    secrets: [notionToken, notionKpiDataSourceId],
    retryCount: 3,
  },
  async () => {
    const db = getFirestore();
    const snapshot = await db.doc("companyMetrics/current").get();

    if (!snapshot.exists) {
      logger.warn("companyMetrics/current does not exist; nothing synced.");
      return;
    }

    const data = snapshot.data() ?? {};
    let synced = 0;

    for (const metric of METRICS) {
      const raw = data[metric.field];
      if (typeof raw !== "number" || !Number.isFinite(raw)) continue;
      await updateMetric(metric.notionName, raw);
      synced += 1;
    }

    await db.doc("companyMetrics/notionSync").set(
      {
        lastSuccessAt: Timestamp.now(),
        metricsSynced: synced,
      },
      { merge: true },
    );

    logger.info("Baybe HQ KPI sync complete", { metricsSynced: synced });
  },
);
