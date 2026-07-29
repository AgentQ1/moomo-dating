/**
 * Runtime-option ceilings — a guardrail against silent regression.
 *
 * Production-readiness audit finding P0-1: the callables shipped with no runtime
 * options, so there was no upper bound on Cloud Run instances (cost/abuse have
 * no ceiling, no kill switch). `src/options.ts` adds an explicit `maxInstances`
 * to every function. This test asserts those ceilings are actually attached to
 * the compiled function endpoints, so nobody can drop them back to unbounded
 * without a red test.
 *
 * Finding P0-2 rides on the same helper: `callable()` sets
 * `enforceAppCheck: true`, so every callable refuses unattested clients. The
 * assertions here are static (helper output + source scan) because App Check
 * verification itself is the platform's code, exercised before any handler —
 * what CAN regress in this repo is a function bypassing the helper or
 * overriding the flag, and that is exactly what is asserted against.
 *
 * It inspects the `__endpoint` metadata firebase-functions attaches at define
 * time — no emulator interaction — but still runs under `npm test` alongside the
 * integration suite.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT ?? 'moomo-functions-test-options';

const functions = await import('../lib/index.js');
const { callable, trigger, scheduled, REGION } = await import('../lib/options.js');

/** Every function paired with the ceiling options.ts assigns it. */
// Ceilings are additionally capped at 20 by the project's Cloud Run regional
// CPU quota (us-central1: 20 vCPU; each instance reserves 1 vCPU — deploys
// with maxInstances > 20 are refused). Raise the hot-path ceilings only
// after a quota increase is granted; the load test needs that first.
const EXPECTED_MAX_INSTANCES = {
  joinMatchmakingQueue: 20,
  leaveMatchmakingQueue: 20,
  acceptCallInvite: 20,
  declineCallInvite: 20,
  getDiscoveryFeed: 20,
  submitCallDecision: 20,
  endCallSession: 20,
  getCallMediaToken: 20,
  blockUser: 10,
  unmatchUser: 10,
  reportUser: 10,
  activateBoost: 10,
  deleteAccount: 5,
  sendSystemNotification: 5,
  resolveReport: 5,
  onMessageCreated: 20,
  sweepMatchmakingQueue: 1,
};

/** The v2 defaults options.ts pins so a platform change can't move them. */
const PINNED = { memoryMb: 256, timeoutSeconds: 60, concurrency: 80 };

describe('runtime option ceilings (P0-1 guardrail)', () => {
  for (const [name, maxInstances] of Object.entries(EXPECTED_MAX_INSTANCES)) {
    test(`${name} has a bounded maxInstances and pinned region`, () => {
      const fn = functions[name];
      assert.ok(fn, `${name} is not exported from index.ts`);

      const endpoint = fn.__endpoint;
      assert.ok(endpoint, `${name} has no __endpoint metadata`);

      // The cost/abuse brake: a real, finite ceiling — never unset.
      assert.equal(
        endpoint.maxInstances,
        maxInstances,
        `${name} maxInstances should be ${maxInstances}`
      );
      assert.ok(
        typeof endpoint.maxInstances === 'number' && endpoint.maxInstances > 0,
        `${name} maxInstances must be a positive number`
      );

      // Region is pinned, not left to the platform default.
      assert.deepEqual(
        endpoint.region,
        [REGION],
        `${name} region should be pinned to ${REGION}`
      );

      // Memory/timeout pinned to the v2 defaults (behaviour unchanged).
      assert.equal(endpoint.availableMemoryMb, PINNED.memoryMb, `${name} memory should be 256MiB`);
      assert.equal(endpoint.timeoutSeconds, PINNED.timeoutSeconds, `${name} timeout should be 60s`);

      // Callables also pin per-instance concurrency; the scheduled sweep and
      // the Firestore trigger use the platform's own trigger concurrency.
      if (endpoint.callableTrigger) {
        assert.equal(
          endpoint.concurrency,
          PINNED.concurrency,
          `${name} concurrency should be pinned to 80`
        );
      }
    });
  }

  test('every function exported from index.ts is covered by a ceiling', () => {
    // Guards against a new function being added without a ceiling: if it is
    // exported and looks like a v2 function, it must be in the expected map.
    for (const [name, value] of Object.entries(functions)) {
      const looksLikeFunction =
        value && typeof value === 'function' && value.__endpoint;
      if (looksLikeFunction) {
        assert.ok(
          name in EXPECTED_MAX_INSTANCES,
          `${name} is a deployed function with no maxInstances assertion — add it to options.ts and this test`
        );
      }
    }
  });
});

describe('App Check enforcement (P0-2 guardrail)', () => {
  test('the shared callable() helper enforces App Check', () => {
    assert.equal(callable(7).enforceAppCheck, true);
  });

  test('per-function extras cannot silently drop enforcement', () => {
    // The only sanctioned extra today is `secrets` (getCallMediaToken);
    // merging it must leave enforcement on.
    assert.equal(callable(7, { secrets: [] }).enforceAppCheck, true);
    // And a hostile/careless extra must not be able to opt out — the
    // mandatory keys are applied after the spread.
    assert.equal(callable(7, { enforceAppCheck: false }).enforceAppCheck, true);
    assert.equal(callable(7, { maxInstances: 10_000 }).maxInstances, 7);
  });

  test('helper pins region, concurrency, memory and timeout explicitly', () => {
    const options = callable(7);
    assert.equal(options.region, REGION);
    assert.equal(options.maxInstances, 7);
    assert.equal(options.concurrency, PINNED.concurrency);
    assert.equal(options.memory, '256MiB');
    assert.equal(options.timeoutSeconds, PINNED.timeoutSeconds);

    const triggerOptions = trigger(7);
    assert.equal(triggerOptions.region, REGION);
    assert.equal(triggerOptions.maxInstances, 7);

    const scheduledOptions = scheduled(1);
    assert.equal(scheduledOptions.region, REGION);
    assert.equal(scheduledOptions.maxInstances, 1);
  });

  test('every onCall in src/ goes through callable() and nothing opts out', () => {
    // Source-level backstop: enforcement lives in the helper, so the two
    // regressions that matter are (a) a callable built without the helper,
    // (b) an option overriding enforceAppCheck to false. Scan for both,
    // recursively, and match the generic form `onCall<Req, Res>(...)` too —
    // a form the scan must FLAG, not silently skip.
    const srcDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');
    const walk = (dir) =>
      readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
        entry.isDirectory() ? walk(join(dir, entry.name)) : [join(dir, entry.name)]
      );
    // options.ts defines the policy (and mentions bare `onCall(...)` in
    // prose); every other source file is scanned.
    const scanned = walk(srcDir).filter(
      (f) => f.endsWith('.ts') && !f.endsWith('/options.ts')
    );
    assert.ok(scanned.length >= 10, 'the scan is actually looking at the sources');
    for (const file of scanned) {
      const source = readFileSync(file, 'utf8');
      for (const match of source.matchAll(
        /onCall(?:<[^>]*>)?\(\s*([A-Za-z_$][A-Za-z0-9_$]*)?/g
      )) {
        assert.equal(
          match[1],
          'callable',
          `${file}: onCall must take options from the shared callable() helper`
        );
      }
      assert.ok(
        !/enforceAppCheck\s*:\s*(?!true\b)/.test(source),
        `${file}: a callable must never opt out of App Check`
      );
    }
  });
});
