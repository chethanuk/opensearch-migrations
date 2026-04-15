import { DEFAULT_STATUS_CHECK_RETRY_LIMIT, USER_RFS_OPTIONS } from "../src";

describe("USER_RFS_OPTIONS statusCheckRetryLimit", () => {
    test("defaults to a bounded long-running retry window", () => {
        const parsed = USER_RFS_OPTIONS.parse({});

        expect(parsed.statusCheckRetryLimit).toBe(DEFAULT_STATUS_CHECK_RETRY_LIMIT);
    });

    test("preserves explicit overrides", () => {
        const parsed = USER_RFS_OPTIONS.parse({ statusCheckRetryLimit: 1200 });

        expect(parsed.statusCheckRetryLimit).toBe(1200);
    });
});
