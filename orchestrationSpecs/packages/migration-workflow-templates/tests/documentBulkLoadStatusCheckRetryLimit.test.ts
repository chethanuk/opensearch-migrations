import { renderWorkflowTemplate } from "@opensearch-migrations/argo-workflow-builders";

import { DocumentBulkLoad } from "../src/workflowTemplates/documentBulkLoad";

describe("document bulk load wait-for-completion retry limit", () => {
    const rendered = renderWorkflowTemplate(DocumentBulkLoad);
    const templates = rendered.spec?.templates ?? [];

    test("uses a configurable retry limit with a long-running default", () => {
        const waitTemplate = templates.find((template: any) => template.name === "waitforcompletioninternal");

        expect(waitTemplate?.retryStrategy?.limit).toBe("{{inputs.parameters.statusCheckRetryLimit}}");
        expect(waitTemplate?.inputs?.parameters).toEqual(
            expect.arrayContaining([
                expect.objectContaining({ name: "statusCheckRetryLimit", value: "900" })
            ])
        );
    });

    test("threads documentBackfillConfig overrides into the wait step", () => {
        const runBulkLoadTemplate = templates.find((template: any) => template.name === "runbulkload");
        const runStatusChecksStep = runBulkLoadTemplate?.steps?.[2]?.[0];

        expect(runStatusChecksStep?.arguments?.parameters).toEqual(
            expect.arrayContaining([
                expect.objectContaining({
                    name: "statusCheckRetryLimit",
                    value: "{{=sprig.dig('statusCheckRetryLimit', 900, fromJSON(inputs.parameters.documentBackfillConfig))}}"
                })
            ])
        );
    });
});
