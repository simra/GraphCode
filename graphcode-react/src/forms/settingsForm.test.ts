import { describe, expect, it } from "vitest";
import {
  graphcodeSettingsSchema,
  MAX_RESOLVED_SESSION_GRACE_MINUTES,
  rebaseSettingsDraft,
  settingsDefaults,
  validateSettingsDraft,
} from "./settingsForm";

describe("settings form contract", () => {
  it("matches GraphcodeSettingsStore defaults and migrations", () => {
    expect(graphcodeSettingsSchema.parse({})).toEqual(settingsDefaults);
    expect(
      graphcodeSettingsSchema.parse({ artifactoryEnabled: false })
        .mailroomEnabled,
    ).toBe(false);
    expect(
      graphcodeSettingsSchema.parse({
        endsResolvedSessionsAfterMinutes: -4,
      }).endsResolvedSessionsAfterMinutes,
    ).toBe(0);
  });

  it("rejects invalid known values without dropping unknown fields", () => {
    expect(() =>
      graphcodeSettingsSchema.parse({ defaultModelTier: "largest" }),
    ).toThrow();
    const parsed = graphcodeSettingsSchema.parse({
      daemonHeartbeatEnabled: true,
      futureSetting: { enabled: true },
    });
    expect(Object.entries(parsed)).toContainEqual([
      "futureSetting",
      { enabled: true },
    ]);
  });

  it("validates the resolved-session grace period", () => {
    expect(
      validateSettingsDraft({
        ...settingsDefaults,
        endsResolvedSessionsAfterMinutes: -1,
      }),
    ).toEqual({
      endsResolvedSessionsAfterMinutes: `Use zero to keep sessions, or a whole number up to ${MAX_RESOLVED_SESSION_GRACE_MINUTES.toLocaleString("en-US")} minutes.`,
    });
    expect(
      validateSettingsDraft({
        ...settingsDefaults,
        endsResolvedSessionsAfterMinutes: Number.MAX_SAFE_INTEGER + 1,
      }),
    ).toHaveProperty("endsResolvedSessionsAfterMinutes");
    expect(
      validateSettingsDraft({
        ...settingsDefaults,
        endsResolvedSessionsAfterMinutes:
          MAX_RESOLVED_SESSION_GRACE_MINUTES + 1,
      }),
    ).toHaveProperty("endsResolvedSessionsAfterMinutes");
    expect(
      validateSettingsDraft({
        ...settingsDefaults,
        endsResolvedSessionsAfterMinutes: MAX_RESOLVED_SESSION_GRACE_MINUTES,
      }),
    ).toEqual({});
  });

  it("rebases only locally edited fields onto a newer snapshot", () => {
    const original = {
      ...settingsDefaults,
      daemonHeartbeatEnabled: false,
      mailroomEnabled: true,
      futureSetting: "old",
    };
    const draft = {
      ...original,
      daemonHeartbeatEnabled: true,
    };
    const incoming = {
      ...original,
      mailroomEnabled: false,
      futureSetting: "new",
    };

    expect(rebaseSettingsDraft(original, draft, incoming)).toMatchObject({
      daemonHeartbeatEnabled: true,
      mailroomEnabled: false,
      futureSetting: "new",
    });
  });
});
