# Future Sections (Reserved)

This directory is a placeholder for upcoming training sections. Do not add lab guides here until they are registered in [LAB_REGISTRY.yaml](../../LAB_REGISTRY.yaml).

## Planned sections

| ID | Title | Status |
|----|-------|--------|
| 05 | Monitoring & Observability | Planned |
| 06 | Backup & Restore | Planned |
| 07 | Strong Consistency | Planned |

## Adding a new section

1. Create `sections/NN-section-name/README.md` from [`_templates/section-readme.md`](../../_templates/section-readme.md)
2. Add section and labs to `LAB_REGISTRY.yaml`
3. Copy [`_templates/lab-walkthrough.md`](../../_templates/lab-walkthrough.md) for each new lab
4. Run walkthrough validation; update `validation_status`

Existing lab IDs and files are never renumbered.
