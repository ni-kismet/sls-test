# sls-test

Test bed for running NI SystemLink Server in containers on GitHub Actions:

- **build-images** (manual) builds a SystemLink Server base image and seeded configuration images, and publishes them
  to private `ghcr.io/rajsite/sls-server`.
- **e2e-demo** / **e2e-migration** pull one image each, start it and run a Playwright suite against it.

Status and design: [docs/workflow-test-plan.md](docs/workflow-test-plan.md).

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `probe` | manual | Prints runner resources (CPU, RAM, disk, KVM, Docker) after host preparation. |
